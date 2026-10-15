/**
 * The bridge between an incoming Cast session and the local player.
 *
 * Cast receivers can only hand playback to something local, so Karu forwards
 * everything to **Kikru**, the same HTTP cast server the `kikru://` URL
 * handler and the appcast flow already use (`:Kikru cast server`, default
 * `http://127.0.0.1:8722`). If that server is not running, Karu can fall back
 * to launching mpv/ffplay directly so a cast is never silently dropped.
 */
import { spawn, type ChildProcess } from "node:child_process";
import type { MediaInformation } from "../protocol/messages.ts";
import { guessContentType } from "../protocol/messages.ts";
import type { PlayerBridge } from "./core.ts";

export interface BridgeOptions {
  /** Kikru cast-server base URL. */
  baseUrl?: string;
  /** Shared secret for `?token=` (kikru.cast.token). */
  token?: string;
  /** Fall back to a local binary when Kikru is unreachable. */
  fallbackPlayer?: "mpv" | "ffplay" | "none";
  /** URL opened in a browser when the receiver should show something. */
  log?: (message: string) => void;
  /** Injectable for tests. */
  fetchImpl?: typeof fetch;
}

export interface CastEvent {
  kind: "cast" | "play" | "pause" | "stop" | "seek" | "volume";
  detail: string;
}

/** Turn whatever a sender asked for into something the local player understands. */
export function normalizeContentId(contentId: string): { kind: "url" | "search" | "youtube-id"; value: string } {
  const trimmed = contentId.trim();
  if (/^[A-Za-z0-9_-]{11}$/.test(trimmed)) return { kind: "youtube-id", value: trimmed };
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) return { kind: "url", value: trimmed };
  if (trimmed.startsWith("/")) return { kind: "url", value: `file://${trimmed}` };
  return { kind: "search", value: trimmed };
}

export class PlayerBridgeImpl implements PlayerBridge {
  private child: ChildProcess | null = null;
  private readonly baseUrl: string;
  private readonly token?: string;
  private readonly fallback: "mpv" | "ffplay" | "none";
  private readonly log: (message: string) => void;
  private readonly fetchImpl: typeof fetch;
  /** Set by the CLI so the Lua side can react to bridged events. */
  onEvent?: (event: CastEvent) => void;

  constructor(options: BridgeOptions = {}) {
    this.baseUrl = (options.baseUrl ?? "http://127.0.0.1:8722").replace(/\/+$/, "");
    if (options.token) this.token = options.token;
    this.fallback = options.fallbackPlayer ?? "none";
    this.log = options.log ?? (() => {});
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async health(): Promise<boolean> {
    try {
      const response = await this.fetchImpl(this.url("/status"), { signal: AbortSignal.timeout(1500) });
      return response.ok;
    } catch {
      return false;
    }
  }

  /** Fire-and-forget call into the Kikru cast server. */
  private async call(path: string, label: string): Promise<boolean> {
    try {
      const response = await this.fetchImpl(this.url(path), { signal: AbortSignal.timeout(4000) });
      const ok = response.ok;
      this.log(`bridge: ${label} -> ${ok ? "ok" : `HTTP ${response.status}`}`);
      return ok;
    } catch (error) {
      this.log(`bridge: ${label} failed (${(error as Error).message})`);
      return false;
    }
  }

  private url(path: string): string {
    const separator = path.includes("?") ? "&" : "?";
    return this.token ? `${this.baseUrl}${path}${separator}token=${encodeURIComponent(this.token)}` : `${this.baseUrl}${path}`;
  }

  onLoad(media: MediaInformation, options: { autoplay: boolean; currentTime: number }): boolean {
    const target = normalizeContentId(media.contentId);
    const title = typeof media.metadata?.title === "string" ? media.metadata.title : media.contentId;
    this.log(`bridge: LOAD ${target.kind} ${target.value}${options.autoplay ? "" : " (paused)"}`);
    this.onEvent?.({ kind: "cast", detail: target.value });

    const query = target.kind === "search" ? `/ytm?q=${encodeURIComponent(target.value)}` : `/cast?url=${encodeURIComponent(target.value)}`;
    void this.call(query, `load ${title}`).then((ok) => {
      if (!ok) this.fallbackPlay(target.value);
    });
    return true;
  }

  onPlay(): void {
    void this.call("/play", "play");
    this.onEvent?.({ kind: "play", detail: "" });
  }

  onPause(): void {
    void this.call("/pause", "pause");
    this.onEvent?.({ kind: "pause", detail: "" });
  }

  onStop(): void {
    void this.call("/stop", "stop");
    this.killFallback();
    this.onEvent?.({ kind: "stop", detail: "" });
  }

  onSeek(seconds: number): void {
    void this.call(`/seek?value=${Math.max(0, Math.round(seconds))}`, `seek ${seconds}`);
    this.onEvent?.({ kind: "seek", detail: String(seconds) });
  }

  onVolume(level: number, muted: boolean): void {
    const percent = Math.round(muted ? 0 : level * 100);
    void this.call(`/volume?value=${percent}`, `volume ${percent}%`);
    this.onEvent?.({ kind: "volume", detail: String(percent) });
  }

  /** Last-resort local playback when Kikru is not reachable. */
  private fallbackPlay(url: string): void {
    if (this.fallback === "none") {
      this.log("bridge: Kikru unreachable and no fallback player configured, cast dropped");
      return;
    }
    this.killFallback();
    const args = this.fallback === "mpv" ? ["--no-video", "--really-quiet", url] : ["-nodisp", "-autoexit", "-loglevel", "quiet", url];
    try {
      this.child = spawn(this.fallback, args, { stdio: "ignore", detached: false });
      this.log(`bridge: falling back to ${this.fallback} for ${url}`);
    } catch (error) {
      this.log(`bridge: fallback failed (${(error as Error).message})`);
    }
  }

  killFallback(): void {
    if (this.child) {
      this.child.kill("SIGTERM");
      this.child = null;
    }
  }

  /** Stop the fallback player; call on shutdown. */
  close(): void {
    this.killFallback();
  }
}

export { guessContentType };
