/**
 * Typed JSON payloads for the Cast namespaces.
 *
 * Every namespace except `deviceauth` carries JSON:
 *   tp.connection  { type: "CONNECT" | "CLOSE" }
 *   tp.heartbeat   { type: "PING" | "PONG" }
 *   receiver       { type: "GET_STATUS" | "LAUNCH" | "STOP" | "SET_VOLUME" | "RECEIVER_STATUS" }
 *   media          { type: "LOAD" | "PLAY" | "PAUSE" | "STOP" | "SEEK" | "GET_STATUS"
 *                         | "MEDIA_STATUS" | "LOAD_FAILED" }
 *
 * The builders/parsers here are pure functions so they can be unit-tested
 * without a socket, and reused by both the receiver and the sender.
 */

export const APP_ID = "CC1AD845"; // Default Media Receiver
export const METADATA_TYPE_GENERIC = 0;
export const METADATA_TYPE_MUSIC = 3;

export type Json = Record<string, unknown>;

export interface ReceiverVolume {
  level: number;
  muted: boolean;
  controlType?: string;
  stepInterval?: number;
}

export interface ReceiverApp {
  appId: string;
  appType?: string;
  displayName: string;
  iconUrl?: string;
  isIdleScreen?: boolean;
  launchedFromCloud?: boolean;
  namespaces: { name: string }[];
  sessionId: string;
  statusText: string;
  transportId: string;
  universalAppId?: string;
}

export interface ReceiverStatus {
  applications?: ReceiverApp[];
  volume?: ReceiverVolume;
  isActiveInput?: boolean;
  isStandBy?: boolean;
  userEq?: Json;
}

export interface MediaImage {
  url: string;
}

export interface MediaMetadata extends Json {
  metadataType?: number;
  title?: string;
  subtitle?: string;
  artist?: string;
  albumName?: string;
  images?: MediaImage[];
}

export interface MediaInformation extends Json {
  contentId: string;
  contentType: string;
  streamType?: "BUFFERED" | "LIVE";
  duration?: number;
  metadata?: MediaMetadata;
  customData?: Json;
}

export interface MediaStatusEntry {
  mediaSessionId: number;
  playerState: "IDLE" | "PLAYING" | "PAUSED" | "BUFFERING";
  idleReason?: "CANCELLED" | "INTERRUPTED" | "FINISHED" | "ERROR";
  media?: MediaInformation;
  currentTime?: number;
  volume?: { level: number; muted: boolean };
  supportedMediaCommands?: number;
  repeatMode?: string;
}

export interface MediaStatusPayload {
  type: "MEDIA_STATUS";
  requestId: number;
  status: MediaStatusEntry[];
}

export interface LoadFailedPayload {
  type: "LOAD_FAILED";
  requestId: number;
  itemId?: unknown;
  detailedErrorCode?: number;
}

// ---------------------------------------------------------------------------
// builders
// ---------------------------------------------------------------------------

export function connectionMessage(type: "CONNECT" | "CLOSE"): string {
  return JSON.stringify({ type });
}

export function heartbeat(type: "PING" | "PONG", requestId?: number): string {
  return requestId === undefined ? JSON.stringify({ type }) : JSON.stringify({ type, requestId });
}

export function getStatus(requestId: number): string {
  return JSON.stringify({ type: "GET_STATUS", requestId });
}

export function launch(appId: string, requestId: number): string {
  return JSON.stringify({ type: "LAUNCH", appId, requestId });
}

export function stopReceiver(sessionId: string, requestId: number): string {
  return JSON.stringify({ type: "STOP", sessionId, requestId });
}

export function setVolume(requestId: number, update: { level?: number; muted?: boolean }): string {
  const volume: Json = {};
  if (update.level !== undefined) volume.level = Math.min(1, Math.max(0, update.level));
  if (update.muted !== undefined) volume.muted = update.muted;
  return JSON.stringify({ type: "SET_VOLUME", volume, requestId });
}

export interface LoadOptions {
  contentId: string;
  contentType: string;
  streamType?: "BUFFERED" | "LIVE";
  duration?: number;
  title?: string;
  subtitle?: string;
  images?: string[];
  metadataType?: number;
  autoplay?: boolean;
  currentTime?: number;
  requestId: number;
}

export function load(opts: LoadOptions): string {
  const metadata: MediaMetadata = {
    metadataType: opts.metadataType ?? METADATA_TYPE_MUSIC,
    title: opts.title,
    subtitle: opts.subtitle,
    artist: opts.subtitle,
    images: (opts.images ?? []).map((url) => ({ url })),
  };
  const media: MediaInformation = {
    contentId: opts.contentId,
    contentType: opts.contentType,
    streamType: opts.streamType ?? (opts.duration ? "BUFFERED" : "BUFFERED"),
    metadata,
  };
  if (opts.duration && opts.duration > 0) media.duration = opts.duration;
  return JSON.stringify({
    type: "LOAD",
    requestId: opts.requestId,
    media,
    autoplay: opts.autoplay ?? true,
    currentTime: opts.currentTime ?? 0,
  });
}

export function mediaCommand(
  type: "PLAY" | "PAUSE" | "STOP" | "GET_STATUS",
  requestId: number,
  mediaSessionId: number
): string {
  return JSON.stringify({ type, requestId, mediaSessionId });
}

export function seek(requestId: number, mediaSessionId: number, relative: number | undefined, absolute: number | undefined): string {
  const payload: Json = { type: "SEEK", requestId, mediaSessionId };
  if (relative !== undefined) payload.relativeTime = relative;
  if (absolute !== undefined) payload.currentTime = absolute;
  return JSON.stringify(payload);
}

export function mediaStatus(payload: MediaStatusPayload): string {
  return JSON.stringify(payload);
}

export function loadFailed(requestId: number, detailedErrorCode: number): string {
  return JSON.stringify({ type: "LOAD_FAILED", requestId, detailedErrorCode });
}

export function receiverStatusPayload(requestId: number, status: ReceiverStatus): string {
  return JSON.stringify({ type: "RECEIVER_STATUS", requestId, status });
}

// ---------------------------------------------------------------------------
// parsers (never throw: a malformed payload is ignored, like the real impls)
// ---------------------------------------------------------------------------

export function parseJson(text: string | undefined): Json | null {
  if (!text) return null;
  try {
    const parsed = JSON.parse(text) as unknown;
    return typeof parsed === "object" && parsed !== null ? (parsed as Json) : null;
  } catch {
    return null;
  }
}

export function messageType(payload: Json | null): string {
  return payload && typeof payload.type === "string" ? payload.type : "";
}

export function requestIdOf(payload: Json | null): number {
  const id = payload?.requestId;
  return typeof id === "number" && Number.isFinite(id) ? id : 0;
}

export function parseMediaStatus(payload: Json | null): MediaStatusPayload | null {
  if (!payload || payload.type !== "MEDIA_STATUS") return null;
  const status = Array.isArray(payload.status) ? (payload.status as MediaStatusEntry[]) : [];
  return { type: "MEDIA_STATUS", requestId: requestIdOf(payload), status };
}

export function parseLoadFailed(payload: Json | null): LoadFailedPayload | null {
  if (!payload || payload.type !== "LOAD_FAILED") return null;
  return {
    type: "LOAD_FAILED",
    requestId: requestIdOf(payload),
    itemId: payload.itemId,
    detailedErrorCode: typeof payload.detailedErrorCode === "number" ? payload.detailedErrorCode : undefined,
  };
}

export function parseReceiverStatus(payload: Json | null): { requestId: number; status: ReceiverStatus } | null {
  if (!payload || payload.type !== "RECEIVER_STATUS") return null;
  const status = (payload.status ?? {}) as ReceiverStatus;
  return { requestId: requestIdOf(payload), status };
}

export function parseLaunchError(payload: Json | null): string | null {
  if (!payload || payload.type !== "LAUNCH_ERROR") return null;
  return typeof payload.reason === "string" ? payload.reason : "launch failed";
}

// ---------------------------------------------------------------------------
// content types & helpers
// ---------------------------------------------------------------------------

const CONTENT_TYPES: [RegExp, string][] = [
  [/\.mp3($|\?)/i, "audio/mpeg"],
  [/\.(m4a|aac)($|\?)/i, "audio/mp4"],
  [/\.(flac|oga|ogg|opus)($|\?)/i, "audio/ogg"],
  [/\.wav($|\?)/i, "audio/wav"],
  [/\.mp4($|\?)/i, "video/mp4"],
  [/\.webm($|\?)/i, "video/webm"],
  [/\.m3u8($|\?)/i, "application/x-mpegURL"],
  [/\.ts($|\?)/i, "video/mp2t"],
  [/\.jpg|\.jpeg($|\?)/i, "image/jpeg"],
  [/\.png($|\?)/i, "image/png"],
];

export function guessContentType(url: string): string {
  for (const [pattern, type] of CONTENT_TYPES) {
    if (pattern.test(url)) return type;
  }
  return "audio/mpeg";
}

/** Stable 32-bit-ish session id source for `mediaSessionId`. */
export function mediaSessionIdFor(seed: number): number {
  return Math.max(1, Math.floor(seed));
}
