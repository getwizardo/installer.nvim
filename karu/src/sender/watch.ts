/**
 * Watch for Cast devices over time. Each round scans, reports devices that
 * appeared and devices that went away, then sleeps. A failed scan is reported
 * through `onError` and the watch keeps going, so one bad round does not end it.
 */
export interface WatchHooks<T> {
  scan(): Promise<T[]>;
  key(item: T): string;
  onAppear(item: T): void;
  onDisappear(item: T): void;
  onError(message: string): void;
  sleep(ms: number): Promise<void>;
}

export interface WatchOptions {
  intervalMs: number;
  /** Number of scans to run. Omit to run until the caller stops the process. */
  rounds?: number;
}

export async function watchDevices<T>(hooks: WatchHooks<T>, options: WatchOptions): Promise<void> {
  const known = new Map<string, T>();
  const rounds = options.rounds ?? Number.POSITIVE_INFINITY;
  for (let round = 0; round < rounds; round++) {
    let found: T[];
    try {
      found = await hooks.scan();
    } catch (error) {
      hooks.onError(error instanceof Error ? error.message : String(error));
      await hooks.sleep(options.intervalMs);
      continue;
    }
    const seen = new Set<string>();
    for (const item of found) {
      const key = hooks.key(item);
      seen.add(key);
      if (!known.has(key)) {
        known.set(key, item);
        hooks.onAppear(item);
      }
    }
    for (const [key, item] of known) {
      if (!seen.has(key)) {
        known.delete(key);
        hooks.onDisappear(item);
      }
    }
    if (round + 1 < rounds) await hooks.sleep(options.intervalMs);
  }
}
