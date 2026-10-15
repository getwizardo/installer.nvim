import { test } from "node:test";
import assert from "node:assert/strict";
import { watchDevices, type WatchHooks } from "../src/sender/watch.ts";

function harness(scans: Array<string[] | Error>) {
  const log: string[] = [];
  let call = 0;
  const hooks: WatchHooks<string> = {
    async scan() {
      const next = scans[Math.min(call, scans.length - 1)]!;
      call++;
      if (next instanceof Error) throw next;
      return next;
    },
    key: (item) => item,
    onAppear: (item) => log.push(`+${item}`),
    onDisappear: (item) => log.push(`-${item}`),
    onError: (message) => log.push(`!${message}`),
    async sleep() {},
  };
  return { hooks, log };
}

test("watch: reports devices as they appear and as they go away, once each", async () => {
  const h = harness([["Living room"], ["Living room", "Kitchen"], ["Kitchen"]]);
  await watchDevices(h.hooks, { intervalMs: 1000, rounds: 3 });
  assert.deepEqual(h.log, ["+Living room", "+Kitchen", "-Living room"]);
});

test("watch: a failed scan is reported and the next round still runs", async () => {
  const h = harness([new Error("mDNS unavailable"), ["TV"]]);
  await watchDevices(h.hooks, { intervalMs: 1000, rounds: 2 });
  assert.deepEqual(h.log, ["!mDNS unavailable", "+TV"]);
});

test("watch: a device that is still present is not reported again", async () => {
  const h = harness([["TV"], ["TV"], ["TV"]]);
  await watchDevices(h.hooks, { intervalMs: 1000, rounds: 3 });
  assert.deepEqual(h.log, ["+TV"]);
});
