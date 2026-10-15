/**
 * CLI tests: the launcher, argument parsing, and one full flow with real child
 * processes — `karu receive` (a Cast device) + `karu cast`/`control` (a sender)
 * + a stub Kikru cast server that records what the receiver bridged.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createServer, type Server } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "../src/cli.ts";

const here = dirname(fileURLToPath(import.meta.url));
const cli = join(here, "..", "src", "cli.ts");

function runCli(args: string[], timeoutMs = 20_000): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cli, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`karu ${args.join(" ")} timed out\n${stdout}\n${stderr}`));
    }, timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

function spawnCli(args: string[]): ChildProcess {
  return spawn(process.execPath, [cli, ...args], { stdio: ["ignore", "pipe", "pipe"] });
}

/** Wait for a stdout line that satisfies `match`, buffering the rest. */
function waitForLine(child: ChildProcess, match: (line: string) => boolean, timeoutMs = 20_000): Promise<string> {
  return new Promise((resolve, reject) => {
    let buffer = "";
    const timer = setTimeout(() => {
      child.stdout?.removeListener("data", onData);
      reject(new Error(`timed out waiting for a line\n${buffer}`));
    }, timeoutMs);
    const onData = (chunk: Buffer) => {
      buffer += chunk.toString();
      let index = buffer.indexOf("\n");
      while (index !== -1) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (match(line)) {
          clearTimeout(timer);
          child.stdout?.removeListener("data", onData);
          resolve(line);
          return;
        }
        index = buffer.indexOf("\n");
      }
    };
    child.stdout?.on("data", onData);
    child.on("error", reject);
  });
}

function startStubKikru(): Promise<{ server: Server; port: number; requests: string[] }> {
  const requests: string[] = [];
  const server = createServer((req, res) => {
    requests.push(req.url ?? "");
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolve({ server, port, requests });
    });
  });
}

test("cli: argument parsing", () => {
  const basic = parseArgs(["cast", "https://x/y.mp3", "--device", "Living Room", "--json"]);
  assert.equal(basic.command, "cast");
  assert.deepEqual(basic.positionals, ["https://x/y.mp3"]);
  assert.equal(basic.flags.get("device"), "Living Room");
  assert.equal(basic.flags.get("json"), true);

  const negated = parseArgs(["receive", "--no-mdns", "--port=9000", "--fallback", "mpv"]);
  assert.equal(negated.flags.get("mdns"), false);
  assert.equal(negated.flags.get("port"), "9000");
  assert.equal(negated.flags.get("fallback"), "mpv");

  const repeated = parseArgs(["discover", "--address", "a", "--address", "b"]);
  assert.equal(repeated.flags.get("address"), "b", "the last value wins for scalar flags");
  assert.deepEqual(parseArgs([]).command, "help");
});

test("cli: info and help run without a device", async () => {
  const info = await runCli(["info", "--json"]);
  assert.equal(info.code, 0);
  const payload = JSON.parse(info.stdout.trim());
  assert.equal(payload.ok, true);
  assert.equal(payload.port, 8009);
  assert.ok(payload.namespaces.includes("urn:x-cast:com.google.cast.media"));
  assert.match(payload.deviceId, /^[0-9a-f]{12}$/);
  assert.match(payload.address, /^\d+\.\d+\.\d+\.\d+$/);

  const help = await runCli(["help"]);
  assert.match(help.stdout, /karu receive/);
  assert.match(help.stdout, /karu cast/);

  const probe = await runCli(["probe", "127.0.0.1:1", "--json"]);
  const probed = JSON.parse(probe.stdout.trim());
  assert.equal(probed.ok, false);
  assert.ok(probed.error, "an unreachable device reports why");
});

test("cli: receive + cast + control against a stub Kikru server", { timeout: 60_000 }, async () => {
  const kikru = await startStubKikru();
  const certDir = mkdtempSync(join(tmpdir(), "karu-cli-"));
  const receiver = spawnCli([
    "receive",
    "--port",
    "0",
    "--no-mdns",
    "--json",
    "--name",
    "Karu CLI Test",
    "--bridge",
    `http://127.0.0.1:${kikru.port}`,
    "--cert-dir",
    certDir,
  ]);
  try {
    const readyLine = await waitForLine(receiver, (line) => line.includes('"event":"ready"'));
    const ready = JSON.parse(readyLine);
    assert.equal(ready.ok, true);
    assert.equal(ready.name, "Karu CLI Test");
    assert.ok(ready.port > 0, "an ephemeral port was bound");
    const address = `127.0.0.1:${ready.port}`;

    const cast = await runCli(["cast", "https://example.com/song.mp3", "--address", address, "--title", "Song", "--json"]);
    assert.equal(cast.code, 0, cast.stdout + cast.stderr);
    const casted = JSON.parse(cast.stdout.trim());
    assert.equal(casted.ok, true, cast.stdout);
    assert.equal(casted.media.title, "Song");
    assert.equal(casted.media.state, "BUFFERING");
    assert.equal(casted.device.port, ready.port);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.ok(
      kikru.requests.some((url) => url.startsWith("/cast?url=https%3A%2F%2Fexample.com%2Fsong.mp3")),
      `Kikru should have received the cast, got: ${kikru.requests.join(", ")}`
    );

    const pause = await runCli(["control", "pause", "--address", address, "--json"]);
    assert.equal(JSON.parse(pause.stdout.trim()).ok, true);
    const volume = await runCli(["volume", "30", "--address", address, "--json"]);
    assert.equal(JSON.parse(volume.stdout.trim()).ok, true);
    const status = await runCli(["status", "--address", address, "--json"]);
    const statusPayload = JSON.parse(status.stdout.trim());
    assert.equal(statusPayload.ok, true);
    assert.equal(statusPayload.app, "Default Media Receiver");
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.ok(kikru.requests.includes("/pause"), kikru.requests.join(", "));
    assert.ok(kikru.requests.includes("/volume?value=30"), kikru.requests.join(", "));

    const stopped = waitForLine(receiver, (line) => line.includes('"event":"stopped"'));
    receiver.kill("SIGTERM");
    const stoppedLine = await stopped;
    assert.equal(JSON.parse(stoppedLine).ok, true);
  } finally {
    receiver.kill("SIGKILL");
    await new Promise<void>((resolve) => kikru.server.close(() => resolve()));
    rmSync(certDir, { recursive: true, force: true });
  }
});
