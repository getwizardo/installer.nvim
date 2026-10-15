import { test } from "node:test";
import assert from "node:assert/strict";
import { runQueue, type QueueEvent, type QueueHooks } from "../src/sender/queue.ts";
import type { MediaStatusEntry } from "../src/protocol/messages.ts";

/** Scripted receiver: each status() call reads the next state from the script. */
function scripted(states: Array<Partial<MediaStatusEntry> | null>, opts: { refuse?: string[]; throwOn?: string } = {}) {
  const events: QueueEvent[] = [];
  const loads: string[] = [];
  let clock = 0;
  let next = 0;
  const hooks: QueueHooks = {
    async load(item) {
      if (item.source === opts.throwOn) throw new Error("cannot resolve " + item.source);
      loads.push(item.source);
      if (opts.refuse?.includes(item.source)) return null;
      return { playerState: "BUFFERING" } as MediaStatusEntry;
    },
    async status() {
      const state = states[Math.min(next, states.length - 1)];
      next++;
      return state === null ? null : ({ mediaSessionId: 1, ...state } as MediaStatusEntry);
    },
    async sleep(ms) {
      clock += ms;
    },
    now: () => clock,
    onEvent: (event) => events.push(event),
  };
  return { hooks, events, loads };
}

const OPTIONS = { pollMs: 1000, startTimeoutMs: 5000 };

test("queue: plays items in order, each one ends when the receiver goes IDLE after playing", async () => {
  const run = scripted([
    { playerState: "PLAYING" },
    { playerState: "PLAYING" },
    { playerState: "IDLE", idleReason: "FINISHED" },
    { playerState: "PLAYING" },
    { playerState: "IDLE", idleReason: "FINISHED" },
  ]);
  const result = await runQueue([{ source: "a" }, { source: "b" }], run.hooks, OPTIONS);
  assert.deepEqual(run.loads, ["a", "b"]);
  assert.deepEqual(result, { played: 2, failed: 0, stopped: false });
  assert.equal(run.events[0]!.event, "queue_start");
  assert.deepEqual(run.events.at(-1), { event: "queue_done", played: 2, failed: 0, stopped: false });
  assert.ok(run.events.some((e) => e.event === "item_done" && e.index === 1 && e.reason === "finished"));
});

test("queue: a refused LOAD fails that item and moves on", async () => {
  const run = scripted([{ playerState: "PLAYING" }, { playerState: "IDLE", idleReason: "FINISHED" }], { refuse: ["bad"] });
  const result = await runQueue([{ source: "bad" }, { source: "good" }], run.hooks, OPTIONS);
  assert.deepEqual(result, { played: 1, failed: 1, stopped: false });
  const failure = run.events.find((e) => e.event === "item_failed");
  assert.ok(failure && failure.event === "item_failed" && failure.error.includes("refused"));
});

test("queue: a load that throws (e.g. yt-dlp missing) is reported, not fatal", async () => {
  const run = scripted([{ playerState: "PLAYING" }, { playerState: "IDLE", idleReason: "FINISHED" }], { throwOn: "nope" });
  const result = await runQueue([{ source: "nope" }, { source: "ok" }], run.hooks, OPTIONS);
  assert.deepEqual(result, { played: 1, failed: 1, stopped: false });
  const failure = run.events.find((e) => e.event === "item_failed");
  assert.ok(failure && failure.event === "item_failed" && failure.error.includes("cannot resolve nope"));
});

test("queue: playback that never starts times out and the queue continues", async () => {
  // Always IDLE with no reason: the receiver accepted the LOAD and did nothing.
  const run = scripted([{ playerState: "IDLE" }]);
  const result = await runQueue([{ source: "stuck" }], run.hooks, { pollMs: 1000, startTimeoutMs: 3000 });
  assert.deepEqual(result, { played: 0, failed: 1, stopped: false });
  const failure = run.events.find((e) => e.event === "item_failed");
  assert.ok(failure && failure.event === "item_failed" && failure.error.includes("did not start"));
});

test("queue: an ERROR idle fails the item at once", async () => {
  const run = scripted([{ playerState: "PLAYING" }, { playerState: "IDLE", idleReason: "ERROR" }, { playerState: "PLAYING" }]);
  const result = await runQueue([{ source: "broken" }], run.hooks, OPTIONS);
  assert.deepEqual(result, { played: 0, failed: 1, stopped: false });
});

test("queue: a CANCELLED idle means someone stopped playback, so the queue ends", async () => {
  const run = scripted([{ playerState: "PLAYING" }, { playerState: "IDLE", idleReason: "CANCELLED" }]);
  const result = await runQueue([{ source: "a" }, { source: "b" }], run.hooks, OPTIONS);
  assert.deepEqual(result, { played: 0, failed: 0, stopped: true });
  assert.deepEqual(run.loads, ["a"], "the second item is never loaded");
});

test("queue: no media left after playing counts as finished", async () => {
  const run = scripted([{ playerState: "PLAYING" }, null]);
  const result = await runQueue([{ source: "a" }], run.hooks, OPTIONS);
  assert.deepEqual(result, { played: 1, failed: 0, stopped: false });
});
