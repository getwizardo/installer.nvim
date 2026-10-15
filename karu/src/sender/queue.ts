/**
 * Play a list of media one after another on a Cast receiver.
 *
 * An item is done when the receiver goes IDLE after it has been playing. A
 * refused LOAD, an ERROR idle, or no playback within `startTimeoutMs` fails the
 * item and the queue moves on. A CANCELLED idle means someone stopped playback
 * on purpose, so the queue ends. The receiver is reached only through `hooks`,
 * which keeps this logic testable without sockets.
 */
import type { MediaStatusEntry } from "../protocol/messages.ts";

export interface QueueItem {
  source: string;
  title?: string;
}

export type QueueEvent =
  | { event: "queue_start"; total: number }
  | { event: "item_start"; index: number; source: string }
  | { event: "item_done"; index: number; source: string; reason: "finished" | "cancelled" }
  | { event: "item_failed"; index: number; source: string; error: string }
  | { event: "queue_done"; played: number; failed: number; stopped: boolean };

export interface QueueHooks {
  /** Resolve and start one item. Returns the status after LOAD, or null when the receiver refused it. */
  load(item: QueueItem): Promise<MediaStatusEntry | null>;
  /** Current media status, or null when nothing is loaded. */
  status(): Promise<MediaStatusEntry | null>;
  sleep(ms: number): Promise<void>;
  now(): number;
  onEvent(event: QueueEvent): void;
}

export interface QueueOptions {
  pollMs: number;
  startTimeoutMs: number;
}

export interface QueueResult {
  played: number;
  failed: number;
  stopped: boolean;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export async function runQueue(items: QueueItem[], hooks: QueueHooks, options: QueueOptions): Promise<QueueResult> {
  const result: QueueResult = { played: 0, failed: 0, stopped: false };
  hooks.onEvent({ event: "queue_start", total: items.length });

  for (let i = 0; i < items.length; i++) {
    const item = items[i]!;
    const index = i + 1;
    hooks.onEvent({ event: "item_start", index, source: item.source });

    let started: MediaStatusEntry | null;
    try {
      started = await hooks.load(item);
    } catch (error) {
      result.failed++;
      hooks.onEvent({ event: "item_failed", index, source: item.source, error: describe(error) });
      continue;
    }
    if (!started) {
      result.failed++;
      hooks.onEvent({ event: "item_failed", index, source: item.source, error: "the receiver refused the media" });
      continue;
    }

    const deadline = hooks.now() + options.startTimeoutMs;
    let sawPlayback = false;
    let outcome: "finished" | "cancelled" | "failed" | null = null;
    let error = "";
    while (outcome === null) {
      let entry: MediaStatusEntry | null;
      try {
        entry = await hooks.status();
      } catch (caught) {
        outcome = "failed";
        error = describe(caught);
        break;
      }
      const state = entry?.playerState ?? "IDLE";
      if (state !== "IDLE") {
        sawPlayback = true;
      } else if (sawPlayback) {
        if (entry?.idleReason === "ERROR") {
          outcome = "failed";
          error = "the receiver reported an error";
        } else if (entry?.idleReason === "CANCELLED") {
          outcome = "cancelled";
        } else {
          outcome = "finished";
        }
        break;
      } else if (entry?.idleReason === "ERROR") {
        outcome = "failed";
        error = "the receiver reported an error";
        break;
      }
      if (!sawPlayback && hooks.now() >= deadline) {
        outcome = "failed";
        error = `playback did not start within ${Math.round(options.startTimeoutMs / 1000)}s`;
        break;
      }
      await hooks.sleep(options.pollMs);
    }

    if (outcome === "finished") {
      result.played++;
      hooks.onEvent({ event: "item_done", index, source: item.source, reason: "finished" });
    } else if (outcome === "cancelled") {
      hooks.onEvent({ event: "item_done", index, source: item.source, reason: "cancelled" });
      result.stopped = true;
      break;
    } else {
      result.failed++;
      hooks.onEvent({ event: "item_failed", index, source: item.source, error });
    }
  }

  hooks.onEvent({ event: "queue_done", played: result.played, failed: result.failed, stopped: result.stopped });
  return result;
}
