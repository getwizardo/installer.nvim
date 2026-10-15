/**
 * End-to-end: our own receiver and our own sender, over real TLS sockets on
 * 127.0.0.1, the exact code path that talks to a Chromecast, minus the LAN.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CastReceiverServer } from "../src/receiver/server.ts";
import { CastClient } from "../src/sender/client.ts";
import { looksLikeAddress, probeAddress, selectDevice, parseAddress, type DiscoveredDevice } from "../src/sender/discovery.ts";
import type { MediaInformation } from "../src/protocol/messages.ts";

interface LoadedMedia {
  media: MediaInformation;
  autoplay: boolean;
}

async function withPairing(fn: (ctx: { server: CastReceiverServer; port: number; loads: LoadedMedia[]; events: string[] }) => Promise<void>): Promise<void> {
  const certDir = mkdtempSync(join(tmpdir(), "karu-integration-"));
  const loads: LoadedMedia[] = [];
  const events: string[] = [];
  const server = new CastReceiverServer({
    name: "Karu Test",
    port: 0,
    address: "127.0.0.1",
    advertise: false,
    certDir,
    bridge: {
      onLoad: (media, options) => {
        loads.push({ media, autoplay: options.autoplay });
        return true;
      },
      onPlay: () => events.push("play"),
      onPause: () => events.push("pause"),
      onStop: () => events.push("stop"),
      onSeek: (seconds) => events.push(`seek:${seconds}`),
      onVolume: (level, muted) => events.push(`volume:${level}:${muted}`),
    },
  });
  const info = await server.start();
  try {
    await fn({ server, port: info.port, loads, events });
  } finally {
    await server.stop();
    rmSync(certDir, { recursive: true, force: true });
  }
}

test("integration: sender drives receiver, status, launch, load, transport", async () => {
  await withPairing(async ({ server, port, loads, events }) => {
    const client = new CastClient({ host: "127.0.0.1", port, name: "Karu Test", timeoutMs: 4000 });
    await client.connect();

    const status = await client.getStatus();
    assert.deepEqual(status.applications, [], "nothing running yet");
    assert.equal(status.volume?.level, 0.5);

    const app = await client.launch();
    assert.equal(app?.appId, "CC1AD845");
    assert.equal(app?.transportId, "web-1");
    assert.equal(typeof app?.sessionId, "string");

    const media = await client.loadMedia({ url: "https://example.com/song.mp3", title: "Song", contentType: "audio/mpeg" });
    assert.equal(media?.playerState, "BUFFERING");
    assert.equal(media?.media?.contentId, "https://example.com/song.mp3");
    assert.equal(media?.media?.metadata?.title, "Song");
    assert.equal(loads.length, 1, "the bridge received the LOAD");
    assert.equal(loads[0]!.media.contentId, "https://example.com/song.mp3");
    assert.equal(loads[0]!.autoplay, true);

    await client.play();
    await client.pause();
    await client.seek(42);
    await client.setVolume({ level: 0.25 });
    assert.deepEqual(events, ["play", "pause", "seek:42", "volume:0.25:false"]);

    // The player pushes state back to the sender (this is what a real device does).
    server.updateFromPlayer({ playerState: "PLAYING", currentTime: 7 });
    await new Promise((resolve) => setTimeout(resolve, 50));
    const refreshed = await client.refreshMediaStatus();
    assert.equal(refreshed?.playerState, "PLAYING");
    assert.equal(refreshed?.currentTime, 7);

    const volume = await client.setVolume({ muted: true });
    assert.equal(volume?.volume?.muted, true);

    await client.quitApp();
    client.close();
  });
});

test("integration: a second sender sees the shared session state", async () => {
  await withPairing(async ({ server, port }) => {
    const first = new CastClient({ host: "127.0.0.1", port, timeoutMs: 4000 });
    const second = new CastClient({ host: "127.0.0.1", port, timeoutMs: 4000 });
    await first.connect();
    await second.connect();
    await first.launch();
    await first.loadMedia({ url: "https://example.com/a.mp3", contentType: "audio/mpeg" });
    await first.play();
    await new Promise((resolve) => setTimeout(resolve, 50));

    // The receiver remembers the session, so a second sender sees it running.
    const status = await second.getStatus();
    assert.equal(status.applications?.[0]?.appId, "CC1AD845");
    const media = await second.refreshMediaStatus();
    assert.equal(media?.media?.contentId, "https://example.com/a.mp3");
    first.close();
    second.close();
  });
});

test("integration: probeAddress and selectDevice work against a live receiver", async () => {
  await withPairing(async ({ server, port }) => {
    const probed = await probeAddress("127.0.0.1", port, 4000);
    assert.equal(probed.reachable, true);
    assert.equal(probed.status?.volume, 0.5);
    assert.equal(probed.status?.app, undefined, "no app before launch");
    assert.equal(probed.source, "manual");

    const devices: DiscoveredDevice[] = [probed];
    assert.equal(selectDevice(devices, undefined)?.port, port);
    assert.equal(selectDevice(devices, "127.0.0.1")?.address, "127.0.0.1");
    assert.equal(selectDevice(devices, "nope"), null);
    assert.deepEqual(parseAddress("192.168.1.5:8009"), { host: "192.168.1.5", port: 8009 });
    assert.deepEqual(parseAddress("192.168.1.5"), { host: "192.168.1.5", port: 8009 });
    assert.equal(server.info?.port, port);
  });
});

test("integration: a literal host:port is recognised as a device selector", async () => {
  assert.equal(looksLikeAddress("192.168.1.24"), true);
  assert.equal(looksLikeAddress("192.168.1.24:8009"), true);
  assert.equal(looksLikeAddress("[fe80::1]:8009"), true);
  assert.equal(looksLikeAddress("tv.local:8009"), true);
  assert.equal(looksLikeAddress("Living room TV"), false);
  assert.equal(looksLikeAddress("d8f550664730"), false);

  await withPairing(async ({ port }) => {
    // the selector the CLI accepts: probing an address with no discovery at all
    const probed = await probeAddress("127.0.0.1", port, 3000);
    assert.equal(probed.reachable, true);
    assert.equal(probed.port, port);
    const { host, port: parsed } = parseAddress(`127.0.0.1:${port}`);
    assert.equal(host, "127.0.0.1");
    assert.equal(parsed, port);
    assert.equal(selectDevice([probed], "127.0.0.1"), probed);
    assert.equal(selectDevice([probed], "1"), probed);
  });
});
