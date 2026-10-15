import { test } from "node:test";
import assert from "node:assert/strict";
import { PlayerBridgeImpl, normalizeContentId } from "../src/receiver/bridge.ts";

test("bridge: content ids are normalised the way Kikru expects", () => {
  assert.deepEqual(normalizeContentId("dQw4w9WgXcQ"), { kind: "youtube-id", value: "dQw4w9WgXcQ" });
  assert.deepEqual(normalizeContentId("https://music.youtube.com/watch?v=abc"), { kind: "url", value: "https://music.youtube.com/watch?v=abc" });
  assert.deepEqual(normalizeContentId("/home/me/song.flac"), { kind: "url", value: "file:///home/me/song.flac" });
  assert.deepEqual(normalizeContentId("  lofi beats  "), { kind: "search", value: "lofi beats" });
  assert.deepEqual(normalizeContentId("rtsp://camera/stream"), { kind: "url", value: "rtsp://camera/stream" });
});

test("bridge: LOAD/PLAY/PAUSE/SEEK/VOLUME become Kikru HTTP calls", async () => {
  const calls: string[] = [];
  const stubFetch: typeof fetch = async (input) => {
    calls.push(String(input));
    return new Response("{}", { status: 200 });
  };
  const bridge = new PlayerBridgeImpl({ baseUrl: "http://127.0.0.1:8722", token: "s3cret", fetchImpl: stubFetch });
  const events: string[] = [];
  bridge.onEvent = (event) => events.push(event.kind);

  bridge.onLoad({ contentId: "https://example.com/song.mp3", contentType: "audio/mpeg", metadata: { title: "Song" } }, { autoplay: true, currentTime: 0 });
  bridge.onLoad({ contentId: "lofi beats", contentType: "audio/mpeg" }, { autoplay: true, currentTime: 0 });
  bridge.onLoad({ contentId: "dQw4w9WgXcQ", contentType: "audio/mpeg" }, { autoplay: true, currentTime: 0 });
  bridge.onPause();
  bridge.onSeek(95.4);
  bridge.onVolume(0.7, false);
  bridge.onVolume(0.7, true);
  bridge.onStop();
  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(calls[0], "http://127.0.0.1:8722/cast?url=https%3A%2F%2Fexample.com%2Fsong.mp3&token=s3cret");
  assert.equal(calls[1], "http://127.0.0.1:8722/ytm?q=lofi%20beats&token=s3cret");
  assert.equal(calls[2], "http://127.0.0.1:8722/cast?url=dQw4w9WgXcQ&token=s3cret");
  assert.equal(calls[3], "http://127.0.0.1:8722/pause?token=s3cret");
  assert.equal(calls[4], "http://127.0.0.1:8722/seek?value=95&token=s3cret");
  assert.equal(calls[5], "http://127.0.0.1:8722/volume?value=70&token=s3cret");
  assert.equal(calls[6], "http://127.0.0.1:8722/volume?value=0&token=s3cret", "muted means 0");
  assert.equal(calls[7], "http://127.0.0.1:8722/stop?token=s3cret");
  assert.deepEqual(events, ["cast", "cast", "cast", "pause", "seek", "volume", "volume", "stop"]);
});

test("bridge: health check reports whether the Kikru cast server answers", async () => {
  const ok = new PlayerBridgeImpl({ fetchImpl: async () => new Response("{\"ok\":true}", { status: 200 }) });
  assert.equal(await ok.health(), true);
  const down = new PlayerBridgeImpl({ fetchImpl: async () => new Response("nope", { status: 500 }) });
  assert.equal(await down.health(), false);
  const broken = new PlayerBridgeImpl({
    fetchImpl: async () => {
      throw new Error("ECONNREFUSED");
    },
  });
  assert.equal(await broken.health(), false);
});

test("bridge: without a fallback player a dropped cast is logged, not spawned", async () => {
  const logs: string[] = [];
  const bridge = new PlayerBridgeImpl({
    fallbackPlayer: "none",
    log: (message) => logs.push(message),
    fetchImpl: async () => {
      throw new Error("ECONNREFUSED");
    },
  });
  bridge.onLoad({ contentId: "https://example.com/x.mp3", contentType: "audio/mpeg" }, { autoplay: true, currentTime: 0 });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.ok(logs.some((line) => line.includes("cast dropped")), logs.join("\n"));
  bridge.close();
});
