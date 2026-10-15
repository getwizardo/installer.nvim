/** Media-channel behaviour of the receiver core: queue, session checks, tracks, rates, auto-advance. */
import { test } from "node:test";
import assert from "node:assert/strict";
import { NS_MEDIA, NS_RECEIVER, PAYLOAD_STRING } from "../src/protocol/castMessage.ts";
import { ReceiverCore, type HandleResult, type PlayerBridge } from "../src/receiver/core.ts";

function makeCore(bridge: PlayerBridge = {}) {
  const core = new ReceiverCore({ config: { name: "Karu", deviceId: "0123456789ab", port: 8009 }, bridge });
  const send = (body: Record<string, unknown>, namespace = NS_MEDIA): HandleResult =>
    core.handle("sender-1", "web-1", namespace, PAYLOAD_STRING, JSON.stringify(body));
  return { core, send };
}

const song = (name: string) => ({ contentId: `https://example.com/${name}.mp3`, contentType: "audio/mpeg" });
const parse = (result: HandleResult, index = 0) => JSON.parse(result.text[index]!.payload);
const statusOf = (result: HandleResult) => parse(result).status[0];

test("queue: QUEUE_LOAD plays the start item and reports the next one", () => {
  const loads: string[] = [];
  const { send } = makeCore({ onLoad: (media) => (loads.push(media.contentId), true) });
  const result = send({ type: "QUEUE_LOAD", requestId: 1, startIndex: 0, items: [{ media: song("a") }, { media: song("b") }] });
  assert.deepEqual(loads, [song("a").contentId]);
  const status = statusOf(result);
  assert.equal(status.currentItemId, 1);
  assert.equal(status.nextItemId, 2);
  assert.equal(status.playerState, "BUFFERING");
  assert.equal(status.mediaSessionId, 1);
});

test("queue: a finished item starts the next one, then the queue ends", () => {
  const loads: string[] = [];
  const { core, send } = makeCore({ onLoad: (media) => (loads.push(media.contentId), true) });
  send({ type: "QUEUE_LOAD", requestId: 1, items: [{ media: song("a") }, { media: song("b") }] });
  const advanced = core.updateFromPlayer({ playerState: "IDLE", idleReason: "FINISHED" });
  assert.equal(loads.at(-1), song("b").contentId, "the second item is loaded by itself");
  const status = JSON.parse(advanced[0]!.payload).status[0];
  assert.equal(status.currentItemId, 2);
  assert.equal(status.mediaSessionId, 2, "each item is a new media session");
  assert.equal(status.nextItemId, undefined, "nothing after the last item");

  const ended = core.updateFromPlayer({ playerState: "IDLE", idleReason: "FINISHED" });
  const endStatus = JSON.parse(ended[0]!.payload).status[0];
  assert.equal(endStatus.playerState, "IDLE");
  assert.equal(endStatus.idleReason, "FINISHED");
  assert.equal(loads.length, 2, "REPEAT_OFF does not loop");
});

test("queue: REPEAT_ALL loops back to the first item when the last one finishes", () => {
  const loads: string[] = [];
  const { core, send } = makeCore({ onLoad: (media) => (loads.push(media.contentId), true) });
  send({ type: "QUEUE_LOAD", requestId: 1, repeatMode: "REPEAT_ALL", items: [{ media: song("a") }, { media: song("b") }] });
  core.updateFromPlayer({ playerState: "IDLE", idleReason: "FINISHED" });
  core.updateFromPlayer({ playerState: "IDLE", idleReason: "FINISHED" });
  assert.deepEqual(loads, [song("a").contentId, song("b").contentId, song("a").contentId]);
});

test("queue: a refused queue item reports LOAD_FAILED with its item id", () => {
  const { send } = makeCore({ onLoad: (media) => media.contentId !== song("bad").contentId });
  const result = send({ type: "QUEUE_LOAD", requestId: 5, items: [{ media: song("bad") }] });
  assert.equal(result.binary.length, 1);
  const failed = JSON.parse(new TextDecoder().decode(result.binary[0]!.payload));
  assert.equal(failed.type, "LOAD_FAILED");
  assert.equal(failed.itemId, 1);
  assert.equal(failed.requestId, 5);
});

test("queue: a LOAD replaces the whole queue", () => {
  const { send } = makeCore();
  send({ type: "QUEUE_LOAD", requestId: 1, items: [{ media: song("a") }, { media: song("b") }] });
  send({ type: "LOAD", requestId: 2, media: song("solo") });
  const ids = JSON.parse(send({ type: "QUEUE_GET_ITEM_IDS", requestId: 3 }).text[0]!.payload);
  assert.equal(ids.type, "QUEUE_ITEM_IDS");
  assert.equal(ids.itemIds.length, 1);
});

test("queue: insert, remove and reorder change the list the sender sees", () => {
  const { send } = makeCore();
  send({ type: "QUEUE_LOAD", requestId: 1, items: [{ media: song("a") }, { media: song("c") }] });
  send({ type: "QUEUE_INSERT", requestId: 2, items: [{ media: song("b") }], insertBefore: 2 });
  const names = () => {
    const items = JSON.parse(send({ type: "QUEUE_GET_ITEMS", requestId: 3 }).text[0]!.payload).items;
    return items.map((item: { media: { contentId: string } }) => item.media.contentId.split("/").at(-1));
  };
  assert.deepEqual(names(), ["a.mp3", "b.mp3", "c.mp3"]);
  // ids: a=1, c=2, b=3 (b was inserted third). Move c (2) before a (1).
  send({ type: "QUEUE_REORDER", requestId: 4, itemIds: [2], insertBefore: 1 });
  assert.deepEqual(names(), ["c.mp3", "a.mp3", "b.mp3"]);
  send({ type: "QUEUE_REMOVE", requestId: 5, itemIds: [1] });
  assert.deepEqual(names(), ["c.mp3", "b.mp3"]);
});

test("queue: QUEUE_NEXT and QUEUE_PREV move and load the item", () => {
  const loads: string[] = [];
  const { send } = makeCore({ onLoad: (media) => (loads.push(media.contentId), true) });
  send({ type: "QUEUE_LOAD", requestId: 1, items: [{ media: song("a") }, { media: song("b") }] });
  send({ type: "QUEUE_NEXT", requestId: 2 });
  assert.equal(loads.at(-1), song("b").contentId);
  send({ type: "QUEUE_PREV", requestId: 3 });
  assert.equal(loads.at(-1), song("a").contentId);
});

test("queue: malformed queue requests are INVALID_REQUEST, not silent", () => {
  const { send } = makeCore();
  assert.equal(parse(send({ type: "QUEUE_LOAD", requestId: 1, items: [] })).reason, "INVALID_PARAMS");
  assert.equal(parse(send({ type: "QUEUE_LOAD", requestId: 2, items: [{ media: {} }] })).reason, "INVALID_PARAMS");
  assert.equal(parse(send({ type: "QUEUE_LOAD", requestId: 3, items: [{ media: song("a") }], repeatMode: "SHUFFLE_FOREVER" })).reason, "INVALID_PARAMS");
});

test("session: a command for another media session is rejected", () => {
  const { send } = makeCore();
  send({ type: "LOAD", requestId: 1, media: song("a") });
  const wrong = parse(send({ type: "PAUSE", requestId: 2, mediaSessionId: 99 }));
  assert.equal(wrong.type, "INVALID_REQUEST");
  assert.equal(wrong.reason, "INVALID_MEDIA_SESSION_ID");
  assert.equal(wrong.requestId, 2);
  const right = statusOf(send({ type: "PAUSE", requestId: 3, mediaSessionId: 1 }));
  assert.equal(right.playerState, "PAUSED");
});

test("session: transport commands with nothing loaded are rejected", () => {
  const { send } = makeCore();
  assert.equal(parse(send({ type: "PLAY", requestId: 1 })).reason, "INVALID_MEDIA_SESSION_ID");
});

test("session: an unknown media command is INVALID_COMMAND", () => {
  const { send } = makeCore();
  const reply = parse(send({ type: "NOT_A_COMMAND", requestId: 7 }));
  assert.equal(reply.type, "INVALID_REQUEST");
  assert.equal(reply.reason, "INVALID_COMMAND");
  assert.equal(reply.requestId, 7);
});

test("transport: playback rate is validated and passed to the bridge", () => {
  const rates: number[] = [];
  const { send } = makeCore({ onLoad: () => true, onRate: (rate) => rates.push(rate) });
  send({ type: "LOAD", requestId: 1, media: song("a") });
  assert.equal(statusOf(send({ type: "SET_PLAYBACK_RATE", requestId: 2, playbackRate: 1.5 })).playbackRate, 1.5);
  assert.equal(parse(send({ type: "SET_PLAYBACK_RATE", requestId: 3, playbackRate: 99 })).reason, "INVALID_PARAMS");
  assert.deepEqual(rates, [1.5]);
});

test("transport: EDIT_TRACKS_INFO sets the active tracks", () => {
  const tracks: number[][] = [];
  const { send } = makeCore({ onLoad: () => true, onTracks: (ids) => tracks.push(ids) });
  send({ type: "LOAD", requestId: 1, media: song("a") });
  const status = statusOf(send({ type: "EDIT_TRACKS_INFO", requestId: 2, activeTrackIds: [1, 3] }));
  assert.deepEqual(status.activeTrackIds, [1, 3]);
  assert.deepEqual(tracks, [[1, 3]]);
});

test("transport: SEEK with resumeState PAUSE leaves playback paused", () => {
  const { send } = makeCore({ onLoad: () => true });
  send({ type: "LOAD", requestId: 1, media: song("a") });
  send({ type: "PLAY", requestId: 2 });
  const status = statusOf(send({ type: "SEEK", requestId: 3, currentTime: 42, resumeState: "PAUSE" }));
  assert.equal(status.playerState, "PAUSED");
  assert.equal(status.currentTime, 42);
});

test("receiver: a volume change reaches every sender, the requester keeps its reply first", () => {
  const { core } = makeCore();
  const result = core.handle("sender-1", "receiver-0", NS_RECEIVER, PAYLOAD_STRING, JSON.stringify({ type: "SET_VOLUME", volume: { level: 0.3 }, requestId: 9 }));
  assert.equal(result.text[0]!.destinationId, "sender-1");
  assert.ok(result.text.some((message) => message.destinationId === "*" && message.namespace === NS_RECEIVER));
});
