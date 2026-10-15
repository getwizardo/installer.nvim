import { test } from "node:test";
import assert from "node:assert/strict";
import { MediaQueue, isRepeatMode } from "../src/receiver/queue.ts";

const entry = (name: string) => ({ media: { contentId: name, contentType: "audio/mpeg" }, autoplay: true, startTime: 0, activeTrackIds: [] });

test("queue: load assigns ids and makes the start index current", () => {
  const q = new MediaQueue();
  const items = q.load([entry("a"), entry("b"), entry("c")], 1);
  assert.deepEqual(items.map((item) => item.itemId), [1, 2, 3]);
  assert.equal(q.current()?.media.contentId, "b");
});

test("queue: next and prev follow the order and stop at the end under REPEAT_OFF", () => {
  const q = new MediaQueue();
  q.load([entry("a"), entry("b")]);
  assert.equal(q.peekNext()?.media.contentId, "b");
  q.jumpTo(2);
  assert.equal(q.peekNext(), undefined, "no item after the last one");
  assert.equal(q.peekPrev()?.media.contentId, "a");
});

test("queue: REPEAT_ALL wraps, REPEAT_SINGLE replays the current item", () => {
  const q = new MediaQueue();
  q.load([entry("a"), entry("b")], 1, "REPEAT_ALL");
  assert.equal(q.peekNext()?.media.contentId, "a", "wraps to the first item");
  q.repeatMode = "REPEAT_SINGLE";
  assert.equal(q.peekNext()?.media.contentId, "b");
  assert.equal(q.peekPrev()?.media.contentId, "b");
});

test("queue: removing the current item moves to the one that takes its place", () => {
  const q = new MediaQueue();
  q.load([entry("a"), entry("b"), entry("c")], 1);
  const result = q.remove([2]);
  assert.deepEqual(result, { removed: 1, currentRemoved: true });
  assert.equal(q.current()?.media.contentId, "c");
});

test("queue: removing the last item as current leaves the previous one current", () => {
  const q = new MediaQueue();
  q.load([entry("a"), entry("b")], 1);
  q.remove([2]);
  assert.equal(q.current()?.media.contentId, "a");
});

test("queue: insert before an id, or append when the id is unknown", () => {
  const q = new MediaQueue();
  q.load([entry("a"), entry("c")]);
  q.insert([entry("b")], 2);
  assert.deepEqual(q.list().map((item) => item.media.contentId), ["a", "b", "c"]);
  q.insert([entry("d")], 999);
  assert.equal(q.list().at(-1)?.media.contentId, "d");
});

test("queue: reorder moves items in the order given", () => {
  const q = new MediaQueue();
  q.load([entry("a"), entry("b"), entry("c"), entry("d")]);
  assert.equal(q.reorder([4, 1], 2), true);
  // [d, a] keep the order given and go before b, the first item not moved.
  assert.deepEqual(q.list().map((item) => item.media.contentId), ["d", "a", "b", "c"]);
  assert.equal(q.reorder([99]), false, "unknown ids change nothing");
});

test("queue: isRepeatMode accepts only the four Cast modes", () => {
  assert.equal(isRepeatMode("REPEAT_ALL"), true);
  assert.equal(isRepeatMode("REPEAT_EVERYTHING"), false);
  assert.equal(isRepeatMode(3), false);
});
