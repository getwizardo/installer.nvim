/**
 * End-to-end queue: the real queue runner drives our own receiver over TLS.
 * The receiver's player is simulated: a PLAYING state after each LOAD, and an
 * IDLE/FINISHED state when the queue sleeps between polls.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CastReceiverServer } from "../src/receiver/server.ts";
import { CastClient } from "../src/sender/client.ts";
import { runQueue, type QueueEvent } from "../src/sender/queue.ts";

test("queue e2e: two items play in order on the real receiver", async () => {
  const certDir = mkdtempSync(join(tmpdir(), "karu-queue-"));
  const loads: string[] = [];
  const server = new CastReceiverServer({
    name: "Karu Queue Test",
    port: 0,
    address: "127.0.0.1",
    advertise: false,
    certDir,
    bridge: {
      onLoad: (media) => {
        loads.push(media.contentId);
        return true;
      },
      onPlay: () => {},
      onPause: () => {},
      onStop: () => {},
      onSeek: () => {},
      onVolume: () => {},
    },
  });
  const info = await server.start();
  const client = new CastClient({ host: "127.0.0.1", port: info.port, name: "Karu Queue Test", log: () => {} });
  const events: QueueEvent[] = [];
  try {
    await client.connect();
    await client.launch();
    const result = await runQueue(
      [{ source: "https://example.com/one.mp3" }, { source: "https://example.com/two.mp3" }],
      {
        async load(item) {
          const entry = await client.loadMedia({ url: item.source, autoplay: true });
          server.updateFromPlayer({ playerState: "PLAYING" });
          return entry;
        },
        status: () => client.refreshMediaStatus(),
        // Between polls the simulated player finishes the track.
        sleep: async () => {
          server.updateFromPlayer({ playerState: "IDLE", idleReason: "FINISHED" });
        },
        now: () => Date.now(),
        onEvent: (event) => events.push(event),
      },
      { pollMs: 1, startTimeoutMs: 10_000 }
    );
    assert.deepEqual(result, { played: 2, failed: 0, stopped: false });
    assert.deepEqual(loads, ["https://example.com/one.mp3", "https://example.com/two.mp3"]);
    assert.deepEqual(events.at(-1), { event: "queue_done", played: 2, failed: 0, stopped: false });
  } finally {
    client.close();
    await server.stop();
    rmSync(certDir, { recursive: true, force: true });
  }
});
