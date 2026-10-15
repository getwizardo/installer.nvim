/**
 * The media queue a receiver keeps for its sender: ordered items with stable
 * ids, a current item and a repeat mode. Pure data, no sockets, so the rules
 * (repeat, wrap-around, removing the current item) are unit-tested directly.
 *
 * REPEAT_ALL_AND_SHUFFLE repeats like REPEAT_ALL. Shuffle order is not
 * implemented, so playback order stays the queue order.
 */
import type { MediaInformation } from "../protocol/messages.ts";

export const REPEAT_MODES = ["REPEAT_OFF", "REPEAT_ALL", "REPEAT_SINGLE", "REPEAT_ALL_AND_SHUFFLE"] as const;
export type RepeatMode = (typeof REPEAT_MODES)[number];

export function isRepeatMode(value: unknown): value is RepeatMode {
  return typeof value === "string" && (REPEAT_MODES as readonly string[]).includes(value);
}

export interface QueueItem {
  itemId: number;
  media: MediaInformation;
  autoplay: boolean;
  startTime: number;
  activeTrackIds: number[];
  customData?: Record<string, unknown>;
}

export type QueueEntry = Omit<QueueItem, "itemId">;

export interface RemoveResult {
  removed: number;
  /** True when the current item was among the removed ones. */
  currentRemoved: boolean;
}

export class MediaQueue {
  private items: QueueItem[] = [];
  private nextId = 1;
  repeatMode: RepeatMode = "REPEAT_OFF";
  currentItemId: number | undefined;

  get length(): number {
    return this.items.length;
  }

  list(): QueueItem[] {
    return [...this.items];
  }

  ids(): number[] {
    return this.items.map((item) => item.itemId);
  }

  get(itemId: number): QueueItem | undefined {
    return this.items.find((item) => item.itemId === itemId);
  }

  current(): QueueItem | undefined {
    return this.currentItemId === undefined ? undefined : this.get(this.currentItemId);
  }

  /** Replace the whole queue and make `startIndex` the current item. */
  load(entries: QueueEntry[], startIndex = 0, repeatMode: RepeatMode = this.repeatMode): QueueItem[] {
    this.items = entries.map((entry) => ({ ...entry, itemId: this.allocate() }));
    this.repeatMode = repeatMode;
    const index = Math.min(Math.max(0, startIndex), Math.max(0, this.items.length - 1));
    this.currentItemId = this.items[index]?.itemId;
    return [...this.items];
  }

  /** Insert before `insertBefore` (an item id), or append when it is missing. */
  insert(entries: QueueEntry[], insertBefore?: number): QueueItem[] {
    const created = entries.map((entry) => ({ ...entry, itemId: this.allocate() }));
    const at = insertBefore === undefined ? -1 : this.items.findIndex((item) => item.itemId === insertBefore);
    if (at < 0) this.items.push(...created);
    else this.items.splice(at, 0, ...created);
    return created;
  }

  /** Remove items by id. If the current item goes, the next remaining item takes its place. */
  remove(itemIds: number[]): RemoveResult {
    const before = this.items.length;
    const doomed = new Set(itemIds);
    const currentRemoved = this.currentItemId !== undefined && doomed.has(this.currentItemId);
    const currentIndex = this.currentItemId === undefined ? -1 : this.indexOf(this.currentItemId);
    this.items = this.items.filter((item) => !doomed.has(item.itemId));
    if (currentRemoved) {
      // The item after the removed one, counting from its old position.
      const successor = this.items.find((_, index) => index >= currentIndex) ?? this.items.at(-1);
      this.currentItemId = successor?.itemId;
    }
    return { removed: before - this.items.length, currentRemoved };
  }

  /** Move the given items, in the order given, before `insertBefore` (or to the end). */
  reorder(itemIds: number[], insertBefore?: number): boolean {
    const moving = itemIds.map((id) => this.get(id)).filter((item): item is QueueItem => item !== undefined);
    if (moving.length === 0) return false;
    const moveSet = new Set(moving.map((item) => item.itemId));
    const rest = this.items.filter((item) => !moveSet.has(item.itemId));
    const at = insertBefore === undefined ? -1 : rest.findIndex((item) => item.itemId === insertBefore);
    if (at < 0) this.items = [...rest, ...moving];
    else this.items = [...rest.slice(0, at), ...moving, ...rest.slice(at)];
    return true;
  }

  indexOf(itemId: number): number {
    return this.items.findIndex((item) => item.itemId === itemId);
  }

  /** The item that plays after the current one under the repeat mode, without moving to it. */
  peekNext(): QueueItem | undefined {
    if (this.items.length === 0) return undefined;
    if (this.currentItemId === undefined) return this.items[0];
    if (this.repeatMode === "REPEAT_SINGLE") return this.current();
    const index = this.indexOf(this.currentItemId);
    if (index + 1 < this.items.length) return this.items[index + 1];
    return this.repeatMode === "REPEAT_OFF" ? undefined : this.items[0];
  }

  /** The item before the current one, wrapping under the repeat modes that repeat the queue. */
  peekPrev(): QueueItem | undefined {
    if (this.items.length === 0) return undefined;
    if (this.currentItemId === undefined) return this.items.at(-1);
    if (this.repeatMode === "REPEAT_SINGLE") return this.current();
    const index = this.indexOf(this.currentItemId);
    if (index > 0) return this.items[index - 1];
    return this.repeatMode === "REPEAT_OFF" ? undefined : this.items.at(-1);
  }

  /** Make `itemId` current. Returns the item, or undefined when it is not in the queue. */
  jumpTo(itemId: number): QueueItem | undefined {
    const item = this.get(itemId);
    if (item) this.currentItemId = itemId;
    return item;
  }

  private allocate(): number {
    return this.nextId++;
  }
}
