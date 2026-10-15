#!/usr/bin/env node
/**
 * Karu CLI — the surface Neovim talks to.
 *
 * Every command prints either human text or, with `--json`, exactly one JSON
 * object per line (`{"event":"ready",…}` for long-running mode), so
 * `lua/kaeru/karu.lua` can parse it with the built-in JSON decoder.
 */
import { spawn } from "node:child_process";
import process from "node:process";
import { NS_CONNECTION, NS_DEVICE_AUTH, NS_HEARTBEAT, NS_MEDIA, NS_RECEIVER } from "./protocol/castMessage.ts";
import { CAST_PORT, CastReceiverServer, defaultCertDir } from "./receiver/server.ts";
import { deviceIdFrom, hostName, primaryAddress } from "./net/mdns.ts";
import { PlayerBridgeImpl } from "./receiver/bridge.ts";
import { CastClient } from "./sender/client.ts";
import { discover, looksLikeAddress, parseAddress, probeAddress, selectDevice, type DiscoveredDevice } from "./sender/discovery.ts";
import { APP_ID } from "./protocol/messages.ts";
import { convert, detect } from "./lyrics/index.ts";
import { readFileSync, writeFileSync } from "node:fs";

export const VERSION = "1.0.0";

interface Args {
  command: string;
  positionals: string[];
  flags: Map<string, string | boolean>;
}

/** Flags that never take a value: `karu --json info` must not eat "info". */
const BOOLEAN_FLAGS = new Set(["json", "help", "version", "youtube", "mdns", "autoplay", "verbose", "quiet", "ui", "watch", "debug"]);

export function parseArgs(argv: string[]): Args {
  const positionals: string[] = [];
  const flags = new Map<string, string | boolean>();
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]!;
    if (token.startsWith("--")) {
      const [rawName, inline] = token.slice(2).split("=", 2) as [string, string | undefined];
      const name = rawName.replace(/^no-/, "");
      const negated = rawName.startsWith("no-");
      if (inline !== undefined) flags.set(name, inline);
      else if (negated) flags.set(name, false);
      else if (BOOLEAN_FLAGS.has(name)) {
        // `--autoplay false` is still accepted, anything else is just the flag.
        const next = argv[i + 1];
        if (next !== undefined && /^(true|false|yes|no|0|1)$/i.test(next)) flags.set(name, next);
        else flags.set(name, true);
        if (flags.get(name) !== true) i++;
      } else if (i + 1 < argv.length && !argv[i + 1]!.startsWith("--")) flags.set(name, argv[++i]!);
      else flags.set(name, true);
      continue;
    }
    if (token.startsWith("-") && token.length > 1) {
      flags.set(token.slice(1), true);
      continue;
    }
    positionals.push(token);
  }
  return { command: positionals.shift() ?? "help", positionals, flags };
}

function flagString(args: Args, name: string): string | undefined {
  const value = args.flags.get(name);
  return typeof value === "string" ? value : undefined;
}

function flagBool(args: Args, name: string, fallback = false): boolean {
  const value = args.flags.get(name);
  if (value === undefined) return fallback;
  if (typeof value === "boolean") return value;
  return value !== "false" && value !== "0" && value !== "no";
}

function flagNumber(args: Args, name: string): number | undefined {
  const value = flagString(args, name);
  if (value === undefined) return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

interface Emitter {
  json: boolean;
  out: (payload: Record<string, unknown>) => void;
  line: (text: string) => void;
  error: (message: string, code?: number) => void;
}

function emitter(json: boolean): Emitter {
  return {
    json,
    out(payload) {
      if (json) console.log(JSON.stringify(payload));
      else {
        const { event, ok, ...rest } = payload;
        const parts = Object.entries(rest)
          .filter(([, value]) => value !== undefined && value !== null)
          .map(([key, value]) => `${key}=${typeof value === "object" ? JSON.stringify(value) : String(value)}`);
        console.log([ok === undefined ? undefined : ok ? "ok" : "error", event ? String(event) : undefined, ...parts].filter(Boolean).join(" "));
      }
    },
    line(text) {
      console.log(text);
    },
    error(message, code = 1) {
      if (json) console.log(JSON.stringify({ ok: false, error: message }));
      else console.error(`karu: ${message}`);
      process.exitCode = code;
    },
  };
}

const HELP = `karu ${VERSION} — Google Cast for Neovim (Kikru)

  karu receive [--name NAME] [--port 8009] [--no-mdns] [--bridge URL]
               [--token T] [--fallback mpv|ffplay|none] [--cert-dir DIR]
               [--address IP] [--youtube] [--json]
      Appear on the network as a Cast device; every LOAD is bridged to Kikru.

  karu discover [--timeout MS] [--address HOST[:PORT]] [--json]
      Find Cast devices over mDNS (plus the addresses you pass).

  karu probe HOST[:PORT] [--json]
      Reachability test: TLS + GET_STATUS.

  karu cast <url|query> [DEVICE] [--device NAME|ID|ADDRESS|INDEX] [--autoplay false]
              [--title T] [--json]
      Launch the Default Media Receiver and LOAD the media.

  karu control play|pause|stop|toggle|quit [DEVICE] [--device ...] [--json]
  karu seek <seconds> [DEVICE]                absolute position
  karu volume <0-100|+N|-N|mute|unmute> [DEVICE]
  karu status [DEVICE] [--json]
  karu info [--json]                          protocol + environment report

  karu lyrics FILE|- [--format lrc|ttml|srt|vtt|json|plain|summary] [--lang CODE]
                     [--offset MS] [--out FILE] [--json]
      Parse Apple Music / AMLL (QQ, NetEase) / YouTube TTML and convert it.
      Default output is enhanced LRC — the format Kikru's karaoke renderer
      understands — so \`karu lyrics song.ttml > song.lrc\` is a whole pipeline.

Flags: --json machine-readable output (one object per line).`;

/** Read all of stdin (a pipe may be non-blocking, so `readFileSync(0)` is not enough). */
async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

async function resolveMediaTarget(target: string, log: (message: string) => void): Promise<{ url: string; title?: string }> {
  if (/^(https?|rtsp|rtmp|file):\/\//i.test(target)) return { url: target };
  if (target.startsWith("/")) return { url: `file://${target}` };
  // Not a URL: hand it to yt-dlp (the same resolver Kikru uses) to get a stream.
  const ytdlp = await resolveWithYtDlp(target, log);
  if (ytdlp) return { url: ytdlp };
  throw new Error("not a URL and yt-dlp is unavailable — pass a direct media URL");
}

function resolveWithYtDlp(query: string, log: (message: string) => void): Promise<string | null> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value: string | null) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    let child;
    try {
      child = spawn("yt-dlp", ["-g", "-f", "bestaudio/best", "--no-playlist", query], { stdio: ["ignore", "pipe", "ignore"] });
    } catch {
      return finish(null);
    }
    let out = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      out += chunk.toString();
    });
    child.on("error", () => finish(null));
    child.on("close", (code) => {
      const first = out.split("\n").find((line) => line.trim() !== "");
      if (code === 0 && first) {
        log(`resolved ${query} → yt-dlp stream`);
        return finish(first.trim());
      }
      finish(null);
    });
    setTimeout(() => {
      child.kill("SIGKILL");
      finish(null);
    }, 45_000).unref?.();
  });
}

async function withDevice<T>(
  args: Args,
  /** Second positional of the command, used as the device selector when given. */
  deviceArg: string | undefined,
  fn: (client: CastClient, device: DiscoveredDevice) => Promise<T>
): Promise<{ client: CastClient; device: DiscoveredDevice; result: T }> {
  const devices = await discover({
    timeoutMs: flagNumber(args, "timeout") ?? 2500,
    addresses: collectAddresses(args),
    log: () => {},
  });
  const wanted = flagString(args, "device") ?? deviceArg;
  let device = selectDevice(devices, wanted);
  if (!device && wanted && looksLikeAddress(wanted)) {
    // A literal `host[:port]` is probed directly, so a receiver we just started
    // (and mDNS-less setups) can be used without waiting for a browse.
    const { host, port } = parseAddress(wanted);
    const probed = await probeAddress(host, port);
    if (probed.reachable) device = probed;
    else throw new Error(`${wanted} is not reachable${probed.error ? ` (${probed.error})` : ""}`);
  }
  if (!device) {
    throw new Error(
      devices.length === 0
        ? "no Cast devices found — pass --address HOST[:PORT] or check the network"
        : `no device matches “${wanted}” (found: ${devices.map((entry) => entry.name).join(", ")})`
    );
  }
  const client = new CastClient({ host: device.address, port: device.port, name: device.name, log: () => {} });
  await client.connect();
  try {
    const result = await fn(client, device);
    return { client, device, result };
  } finally {
    client.close();
  }
}

function collectAddresses(args: Args): string[] {
  const values: string[] = [];
  for (const [name, value] of args.flags) {
    if (name === "address" && typeof value === "string") values.push(value);
    if (name === "addresses" && typeof value === "string") values.push(...value.split(","));
  }
  if (process.env["KARU_DEVICES"]) values.push(...process.env["KARU_DEVICES"].split(","));
  return values.filter((entry) => entry.trim() !== "");
}

function deviceSummary(device: DiscoveredDevice): Record<string, unknown> {
  return {
    name: device.name,
    id: device.id,
    address: device.address,
    port: device.port,
    model: device.model,
    source: device.source,
    reachable: device.reachable,
  };
}

function mediaSummary(entry: { playerState?: string; currentTime?: number; media?: { contentId?: string; metadata?: { title?: string } } } | null): Record<string, unknown> | null {
  if (!entry) return null;
  return {
    state: entry.playerState,
    currentTime: entry.currentTime,
    title: entry.media?.metadata?.title ?? entry.media?.contentId,
    contentId: entry.media?.contentId,
  };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const json = flagBool(args, "json");
  const out = emitter(json);

  switch (args.command) {
    case "help":
    case "--help":
    case "-h":
      out.line(HELP);
      return;

    case "version":
    case "--version":
      out.out({ ok: true, version: VERSION, node: process.version });
      return;

    case "info": {
      out.out({
        ok: true,
        version: VERSION,
        node: process.version,
        host: hostName(),
        address: primaryAddress(),
        deviceId: deviceIdFrom(hostName()),
        port: CAST_PORT,
        appId: APP_ID,
        certDir: defaultCertDir(),
        namespaces: [NS_CONNECTION, NS_HEARTBEAT, NS_RECEIVER, NS_DEVICE_AUTH, NS_MEDIA],
        kikru: process.env["KIKRU_CAST_URL"] ?? "http://127.0.0.1:8722",
      });
      if (!json) {
        out.line(`  mDNS    _googlecast._tcp.local`);
        out.line(`  TLS     port ${CAST_PORT} (self-signed, generated on first run)`);
        out.line(`  Kikru   ${process.env["KIKRU_CAST_URL"] ?? "http://127.0.0.1:8722"}`);
      }
      return;
    }

    case "receive":
    case "receiver": {
      const bridge = new PlayerBridgeImpl({
        baseUrl: flagString(args, "bridge") ?? process.env["KIKRU_CAST_URL"] ?? "http://127.0.0.1:8722",
        ...(flagString(args, "token") ? { token: flagString(args, "token")! } : {}),
        fallbackPlayer: (flagString(args, "fallback") as "mpv" | "ffplay" | "none" | undefined) ?? "none",
        log: (message) => out.line(`# ${message}`),
      });
      const txt: Record<string, string> = {};
      if (flagBool(args, "youtube")) txt["ca"] = "5";
      const server = new CastReceiverServer({
        name: flagString(args, "name") ?? "Karu · Neovim",
        port: flagNumber(args, "port") ?? CAST_PORT,
        ...(flagString(args, "address") ? { address: flagString(args, "address")! } : {}),
        advertise: flagBool(args, "mdns", true),
        ...(flagString(args, "cert-dir") ? { certDir: flagString(args, "cert-dir")! } : { certDir: defaultCertDir() }),
        bridge,
        txt,
        log: (message) => out.line(`# ${message}`),
      });
      bridge.onEvent = (event) =>
        out.out({ ok: true, event: event.kind, ...(event.kind === "cast" ? { url: event.detail } : { detail: event.detail || undefined }) });
      const info = await server.start();
      out.out({ ok: true, event: "ready", ...info, kikru: flagString(args, "bridge") ?? "http://127.0.0.1:8722" });
      const shutdown = () => {
        void server.stop().then(() => {
          bridge.close();
          out.out({ ok: true, event: "stopped" });
          process.exit(0);
        });
      };
      process.on("SIGINT", shutdown);
      process.on("SIGTERM", shutdown);
      // Keep the process alive; sockets + the responder hold the event loop.
      return;
    }

    case "lyrics":
    case "ttml": {
      const path = args.positionals[0] ?? "-";
      let text: string;
      try {
        text = path === "-" ? await readStdin() : readFileSync(path, "utf8");
      } catch (error) {
        out.error(`cannot read ${path === "-" ? "stdin" : path}: ${error instanceof Error ? error.message : String(error)}`);
        return;
      }
      const format = flagString(args, "format") ?? (json ? "json" : "lrc");
      const offsetMs = flagNumber(args, "offset") ?? 0;
      const translations = flagBool(args, "translations", false);
      const lang = flagString(args, "lang");
      try {
        const conversion = convert(text, { offsetMs, translations, ...(lang ? { lang } : {}) });
        const payload = { ...conversion.json, input: path === "-" ? "stdin" : path, format };
        const rendered =
          format === "json"
            ? JSON.stringify(payload)
            : format === "ttml"
              ? conversion.ttml
              : format === "srt"
                ? conversion.srt
                : format === "vtt"
                  ? conversion.vtt
                  : format === "plain"
                    ? conversion.plain
                    : format === "summary"
                      ? conversion.summary
                      : format === "lrc"
                        ? conversion.lrc
                        : undefined;
        if (rendered === undefined) {
          out.error(`unknown --format ${format} (use lrc, ttml, srt, vtt, json, plain or summary)`);
          return;
        }
        const destination = flagString(args, "out");
        if (destination) writeFileSync(destination, rendered.endsWith("\n") ? rendered : `${rendered}\n`);
        else if (format === "json" || !json) out.line(rendered);
        else out.out(payload);
        if (!json && destination) out.line(`ok ${detect(text)} → ${format} · ${conversion.summary}`);
      } catch (error) {
        out.error(error instanceof Error ? error.message : String(error));
      }
      return;
    }

    case "discover":
    case "devices":
    case "ls": {
      const devices = await discover({
        timeoutMs: flagNumber(args, "timeout") ?? 3000,
        addresses: collectAddresses(args),
        log: (message) => out.line(`# ${message}`),
      });
      if (json) {
        out.out({ ok: true, count: devices.length, devices: devices.map((device) => ({ ...deviceSummary(device), status: device.status ?? null })) });
      } else if (devices.length === 0) {
        out.line("no Cast devices found");
      } else {
        devices.forEach((device, index) => {
          const volume = device.status ? ` · ${Math.round((device.status.volume ?? 0) * 100)}%` : "";
          out.line(`${index + 1}. ${device.name} — ${device.address}:${device.port} (${device.model}${volume})`);
        });
      }
      return;
    }

    case "probe": {
      const target = args.positionals[0];
      if (!target) return out.error("probe needs HOST[:PORT]");
      const match = target.match(/^([^:]+)(?::(\d+))?$/);
      const device = await probeAddress(match?.[1] ?? target, match?.[2] ? Number(match[2]) : CAST_PORT);
      out.out({ ok: device.reachable, device: deviceSummary(device), status: device.status ?? null, error: device.error });
      return;
    }

    case "cast": {
      const target = args.positionals[0];
      if (!target) return out.error("cast needs a URL or a search query");
      const resolved = await resolveMediaTarget(target, (message) => out.line(`# ${message}`));
      if (json && resolved.url.startsWith("file://")) out.out({ ok: true, note: "local file", url: resolved.url });
      const { device, result } = await withDevice(args, args.positionals[1], async (client) => {
        await client.launch();
        return client.loadMedia({
          url: resolved.url,
          ...(flagString(args, "title") ? { title: flagString(args, "title")! } : {}),
          ...(flagString(args, "content-type") ? { contentType: flagString(args, "content-type")! } : {}),
          autoplay: flagBool(args, "autoplay", true),
        });
      });
      out.out({ ok: true, device: deviceSummary(device), url: resolved.url, media: mediaSummary(result) });
      return;
    }

    case "control": {
      const action = (args.positionals[0] ?? "status").toLowerCase();
      const { device, result } = await withDevice(args, args.positionals[1], async (client) => {
        await client.getStatus();
        if (action === "status") return null;
        await client.launch();
        switch (action) {
          case "play":
            await client.play();
            return client.media;
          case "pause":
            await client.pause();
            return client.media;
          case "toggle": {
            const current = await client.refreshMediaStatus();
            if (current?.playerState === "PLAYING") await client.pause();
            else await client.play();
            return client.media;
          }
          case "stop":
            await client.stopMedia();
            return client.media;
          case "quit":
            await client.quitApp();
            return null;
          default:
            throw new Error(`unknown control action “${action}”`);
        }
      });
      out.out({ ok: true, action, device: deviceSummary(device), media: mediaSummary(result) });
      return;
    }

    case "seek": {
      const seconds = Number(args.positionals[0]);
      if (!Number.isFinite(seconds)) return out.error("seek needs a number of seconds");
      const { device, result } = await withDevice(args, args.positionals[1], async (client) => {
        await client.launch();
        return client.seek(seconds);
      });
      out.out({ ok: true, device: deviceSummary(device), media: mediaSummary(result) });
      return;
    }

    case "volume": {
      const value = (args.positionals[0] ?? "").toLowerCase();
      const { device, result } = await withDevice(args, args.positionals[1], async (client) => {
        const status = await client.getStatus();
        const current = status.volume?.level ?? 0.5;
        const muted = status.volume?.muted ?? false;
        if (value === "mute" || value === "unmute") return client.setVolume({ muted: value === "mute" });
        if (value === "toggle" || value === "") return client.setVolume({ level: muted ? current : 0.5, muted: false });
        if (value.startsWith("+") || value.startsWith("-")) {
          const delta = Number(value) / 100;
          return client.setVolume({ level: Math.min(1, Math.max(0, current + delta)) });
        }
        const percent = Number(value);
        if (!Number.isFinite(percent)) throw new Error(`volume needs 0-100, +N, -N, mute, unmute (got “${value}”)`);
        return client.setVolume({ level: Math.min(1, Math.max(0, percent / 100)) });
      });
      out.out({ ok: true, device: deviceSummary(device), volume: result?.volume ?? null });
      return;
    }

    case "status": {
      // `karu status [DEVICE]` — the device is the *first* positional here.
      const { device, result } = await withDevice(args, args.positionals[0], async (client) => {
        const status = await client.getStatus();
        await client.launch();
        const media = await client.refreshMediaStatus();
        return { status, media };
      });
      out.out({
        ok: true,
        device: deviceSummary(device),
        volume: result.status.volume ?? null,
        app: result.status.applications?.[0]?.displayName ?? null,
        media: mediaSummary(result.media),
      });
      return;
    }

    default:
      out.error(`unknown command “${args.command}” — try: karu help`);
  }
}

const isMain = process.argv[1] !== undefined && /cli\.(ts|js)$/.test(process.argv[1]);
if (isMain) {
  main().catch((error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    if (parseArgs(process.argv.slice(2)).flags.has("json")) console.log(JSON.stringify({ ok: false, error: message }));
    else console.error(`karu: ${message}`);
    process.exitCode = 1;
  });
}
