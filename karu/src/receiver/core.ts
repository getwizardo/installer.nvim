/**
 * The Cast receiver state machine, sockets and TLS live in `server.ts`, so
 * everything here is a pure `handle()` call that can be unit-tested.
 *
 * Two endpoints are modelled, exactly like a real device:
 *   `receiver-0`   the platform: status, LAUNCH/STOP of apps, volume
 *   `<transportId>` the running app (our Default Media Receiver session)
 *
 * Messages destined for `*` are broadcasts. A sender only receives messages
 * after it CONNECTs to the endpoint on the connection namespace.
 */
import {
  APP_DEFAULT_MEDIA_RECEIVER,
  NS_CONNECTION,
  NS_DEVICE_AUTH,
  NS_HEARTBEAT,
  NS_MEDIA,
  NS_RECEIVER,
  PAYLOAD_BINARY,
  PAYLOAD_STRING,
} from "../protocol/castMessage.ts";
import {
  connectionMessage,
  getStatus,
  heartbeat,
  mediaStatus,
  messageType,
  parseJson,
  parseMediaStatus,
  receiverStatusPayload,
  requestIdOf,
  type Json,
  type MediaInformation,
  type MediaStatusEntry,
} from "../protocol/messages.ts";

/** Commands that act on the loaded session, so they check `mediaSessionId`. */
const TRANSPORT_COMMANDS = new Set(["PLAY", "PAUSE", "STOP", "SEEK", "SET_PLAYBACK_RATE", "EDIT_TRACKS_INFO"]);

function numbersFrom(value: unknown): number[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter((entry): entry is number => typeof entry === "number");
}

/** A queue entry from a media object plus the per-item options. Null when there is no content id. */
function entryFrom(
  raw: unknown,
  options: { autoplay?: unknown; startTime?: unknown; activeTrackIds?: unknown; customData?: unknown }
): QueueEntry | null {
  if (!raw || typeof raw !== "object") return null;
  const media = raw as MediaInformation;
  if (typeof media.contentId !== "string" || media.contentId === "") return null;
  const customData = options.customData && typeof options.customData === "object" ? (options.customData as Record<string, unknown>) : undefined;
  return {
    media,
    autoplay: options.autoplay !== false,
    startTime: typeof options.startTime === "number" && options.startTime >= 0 ? options.startTime : 0,
    activeTrackIds: numbersFrom(options.activeTrackIds) ?? [],
    ...(customData ? { customData } : {}),
  };
}

/** Every item of a queue request, or undefined when one of them is malformed or the list is empty. */
function entriesFrom(value: unknown): QueueEntry[] | undefined {
  if (!Array.isArray(value) || value.length === 0) return undefined;
  const entries: QueueEntry[] = [];
  for (const raw of value) {
    const item = raw as { media?: unknown; autoplay?: unknown; startTime?: unknown; activeTrackIds?: unknown; customData?: unknown } | null;
    const entry = entryFrom(item?.media, item ?? {});
    if (!entry) return undefined;
    entries.push(entry);
  }
  return entries;
}
import { Reader, Writer, decodeString } from "../protocol/protobuf.ts";
import { MediaQueue, isRepeatMode, type QueueEntry } from "./queue.ts";

export const PLATFORM_ID = "receiver-0";
/** supportedMediaCommands: pause|seek|volume|mute|skip-forward|skip-back|queue-* */
export const SUPPORTED_MEDIA_COMMANDS = 1 | 2 | 4 | 8 | 16 | 32 | 64 | 128;

export interface ReceiverConfig {
  /** Friendly device name (also used in the mDNS TXT record). */
  name: string;
  /** Stable device id shown by senders. */
  deviceId: string;
  port: number;
  /** Media receiver app id/name; the default is Google's Default Media Receiver. */
  appId?: string;
  appDisplayName?: string;
  statusText?: string;
  /** Transport id of the app session (senders address media messages to it). */
  transportId?: string;
}

export interface OutgoingText {
  destinationId: string;
  namespace: string;
  payload: string;
}

export interface OutgoingBinary {
  destinationId: string;
  namespace: string;
  payload: Uint8Array;
}

export interface MediaState {
  mediaSessionId: number;
  playerState: MediaStatusEntry["playerState"];
  idleReason?: MediaStatusEntry["idleReason"];
  media?: MediaInformation;
  currentTime: number;
  volume: { level: number; muted: boolean };
  currentItemId?: number;
  playbackRate: number;
  activeTrackIds: number[];
}

export interface PlayerBridge {
  /** A sender asked to play this media (URL or path). Return false to reject. */
  onLoad?: (media: MediaInformation, options: { autoplay: boolean; currentTime: number }) => boolean | void;
  onPlay?: () => void;
  onPause?: () => void;
  onStop?: () => void;
  onSeek?: (seconds: number) => void;
  /** Device-level volume changed by a sender. */
  onVolume?: (level: number, muted: boolean) => void;
  onStatusRequest?: () => void;
  /** Playback rate changed by a sender (SET_PLAYBACK_RATE). */
  onRate?: (rate: number) => void;
  /** Active text/audio tracks changed by a sender (EDIT_TRACKS_INFO). */
  onTracks?: (trackIds: number[]) => void;
}

export interface HandleResult {
  text: OutgoingText[];
  binary: OutgoingBinary[];
}

export interface ReceiverOptions {
  config: ReceiverConfig;
  bridge?: PlayerBridge;
  /**
   * Sign the device-auth response; wired to the TLS identity in `server.ts`.
   * The certificate travels with the signature so the sender can verify it.
   */
  deviceAuth?: (challenge: Uint8Array | null) => { signature: Uint8Array; certificate?: Uint8Array };
  log?: (message: string) => void;
}

interface Sender {
  id: string;
  connected: boolean;
  lastSeen: number;
  userAgent?: string;
}

export class ReceiverCore {
  readonly config: Required<ReceiverConfig>;
  private readonly bridge: PlayerBridge;
  private readonly deviceAuth?: (challenge: Uint8Array | null) => { signature: Uint8Array; certificate?: Uint8Array };
  private readonly log: (message: string) => void;
  private readonly senders = new Map<string, Sender>();
  private requestCounter = 0;
  private appRunning = false;
  private mediaSessionCounter = 0;
  private readonly queue = new MediaQueue();

  volume = { level: 0.5, muted: false };
  state: MediaState = {
    mediaSessionId: 0,
    playerState: "IDLE",
    currentTime: 0,
    volume: { level: 0.5, muted: false },
    playbackRate: 1,
    activeTrackIds: [],
  };

  constructor(options: ReceiverOptions) {
    this.config = {
      name: options.config.name,
      deviceId: options.config.deviceId,
      port: options.config.port,
      appId: options.config.appId ?? APP_DEFAULT_MEDIA_RECEIVER,
      appDisplayName: options.config.appDisplayName ?? "Default Media Receiver",
      statusText: options.config.statusText ?? options.config.name,
      transportId: options.config.transportId ?? "web-1",
    };
    this.bridge = options.bridge ?? {};
    this.deviceAuth = options.deviceAuth;
    this.log = options.log ?? (() => {});
  }

  /** Senders that completed a CONNECT and have not closed. */
  get connectedSenders(): string[] {
    return [...this.senders.values()].filter((sender) => sender.connected).map((sender) => sender.id);
  }

  /** Feed one incoming CastMessage; returns everything to write back. */
  handle(sourceId: string, destinationId: string, namespace: string, payloadType: number, payload: string | Uint8Array): HandleResult {
    const sender = this.sender(sourceId);

    if (namespace === NS_DEVICE_AUTH) {
      return this.handleDeviceAuth(sourceId, payloadType, payload);
    }
    if (payloadType === PAYLOAD_BINARY) {
      // Nothing else in the protocol is binary; ignore quietly.
      return { text: [], binary: [] };
    }
    const json = parseJson(typeof payload === "string" ? payload : decodeString(payload));
    const type = messageType(json);

    switch (namespace) {
      case NS_CONNECTION:
        return this.handleConnection(sender, destinationId, type);
      case NS_HEARTBEAT:
        if (type === "PING") {
          return { text: [{ destinationId: sourceId, namespace: NS_HEARTBEAT, payload: heartbeat("PONG") }], binary: [] };
        }
        return { text: [], binary: [] };
      case NS_RECEIVER:
        return this.handleReceiver(sender, sourceId, json, type);
      case NS_MEDIA:
        return this.handleMedia(sender, sourceId, json, type);
      default:
        this.log(`receiver: unknown namespace ${namespace} from ${sourceId}`);
        return { text: [], binary: [] };
    }
  }

  // --- namespaces ---------------------------------------------------------

  private handleConnection(sender: Sender, destinationId: string, type: string): HandleResult {
    if (type === "CONNECT") {
      sender.connected = true;
      sender.lastSeen = Date.now();
      sender.userAgent = sender.userAgent ?? "cast-sender";
      this.log(`receiver: ${sender.id} connected to ${destinationId}`);
      // A real receiver answers a CONNECT with the current status so the sender
      // knows whether an app is already running.
      return { text: this.statusTo(sender.id, 0), binary: [] };
    }
    if (type === "CLOSE") {
      sender.connected = false;
      this.log(`receiver: ${sender.id} disconnected`);
    }
    return { text: [], binary: [] };
  }

  private handleReceiver(sender: Sender, sourceId: string, json: Json | null, type: string): HandleResult {
    const requestId = requestIdOf(json);
    switch (type) {
      case "GET_STATUS":
        return { text: this.statusTo(sourceId, requestId), binary: [] };
      case "GET_APP_AVAILABILITY": {
        const apps = Array.isArray(json?.appId) ? (json!.appId as string[]) : [];
        const availability: Json = {};
        for (const appId of apps) availability[appId] = appId === this.config.appId ? "APP_AVAILABLE" : "APP_UNAVAILABLE";
        return {
          text: [{ destinationId: sourceId, namespace: NS_RECEIVER, payload: JSON.stringify({ type, requestId, availability }) }],
          binary: [],
        };
      }
      case "LAUNCH": {
        const appId = typeof json?.appId === "string" ? json.appId : this.config.appId;
        if (appId !== this.config.appId) {
          this.log(`receiver: refusing to launch unsupported app ${appId}`);
          return {
            text: [{ destinationId: sourceId, namespace: NS_RECEIVER, payload: JSON.stringify({ type: "LAUNCH_ERROR", requestId, reason: "APP_UNAVAILABLE" }) }],
            binary: [],
          };
        }
        this.appRunning = true;
        this.log(`receiver: launched ${this.config.appDisplayName} (${appId})`);
        return { text: this.statusTo(sourceId, requestId, true), binary: [] };
      }
      case "STOP": {
        this.appRunning = false;
        this.state = { ...this.state, playerState: "IDLE", idleReason: "CANCELLED" };
        this.bridge.onStop?.();
        const messages = this.statusTo(sourceId, requestId);
        return { text: [...messages, ...this.broadcastMedia()], binary: [] };
      }
      case "SET_VOLUME": {
        const volume = (json?.volume ?? {}) as { level?: number; muted?: boolean };
        if (typeof volume.level === "number") this.volume.level = Math.min(1, Math.max(0, volume.level));
        if (typeof volume.muted === "boolean") this.volume.muted = volume.muted;
        this.state.volume = { ...this.volume };
        this.bridge.onVolume?.(this.volume.level, this.volume.muted);
        const status = this.statusTo(sourceId, requestId);
        // Other senders see the new level too; the requester already has its reply.
        const broadcast = this.statusTo("*", 0);
        return { text: [...status, ...broadcast], binary: [] };
      }
      default:
        if (type !== "") this.log(`receiver: unknown message ${type}`);
        return { text: [], binary: [] };
    }
  }

  private handleMedia(sender: Sender, sourceId: string, json: Json | null, type: string): HandleResult {
    const requestId = requestIdOf(json);
    const reply = (payload: string): HandleResult => ({ text: [{ destinationId: sourceId, namespace: NS_MEDIA, payload }], binary: [] });
    const invalid = (reason: string): HandleResult => reply(JSON.stringify({ type: "INVALID_REQUEST", requestId, reason }));
    const changed = (): HandleResult => ({ text: this.broadcastMedia(requestId), binary: [] });

    if (TRANSPORT_COMMANDS.has(type)) {
      // A sender that names a session must name the current one. Without a loaded
      // item there is no session to control.
      if (!this.state.media) return invalid("INVALID_MEDIA_SESSION_ID");
      if (json?.mediaSessionId !== undefined && json.mediaSessionId !== this.state.mediaSessionId) {
        return invalid("INVALID_MEDIA_SESSION_ID");
      }
    }

    switch (type) {
      case "LOAD": {
        // LOAD replaces the whole queue with one item.
        const entry = entryFrom(json?.media, {
          autoplay: json?.autoplay,
          startTime: json?.currentTime,
          activeTrackIds: json?.activeTrackIds,
          customData: json?.customData,
        });
        if (!entry) return { text: [], binary: [] };
        this.queue.load([entry], 0);
        return this.startCurrentFor(sourceId, requestId);
      }

      case "QUEUE_LOAD": {
        const entries = entriesFrom(json?.items);
        if (!entries) return invalid("INVALID_PARAMS");
        const startIndex = typeof json?.startIndex === "number" ? Math.floor(json.startIndex) : 0;
        if (json?.repeatMode !== undefined && !isRepeatMode(json.repeatMode)) return invalid("INVALID_PARAMS");
        const repeat = isRepeatMode(json?.repeatMode) ? json.repeatMode : this.queue.repeatMode;
        this.queue.load(entries, startIndex, repeat);
        const startTime = typeof json?.currentTime === "number" ? json.currentTime : undefined;
        return this.startCurrentFor(sourceId, requestId, startTime);
      }

      case "QUEUE_INSERT": {
        const entries = entriesFrom(json?.items);
        if (!entries) return invalid("INVALID_PARAMS");
        const before = typeof json?.insertBefore === "number" ? json.insertBefore : undefined;
        this.queue.insert(entries, before);
        return changed();
      }

      case "QUEUE_REMOVE": {
        const ids = numbersFrom(json?.itemIds);
        if (!ids || ids.length === 0) return invalid("INVALID_PARAMS");
        const result = this.queue.remove(ids);
        if (!result.currentRemoved) return changed();
        if (this.queue.current()) return this.startCurrentFor(sourceId, requestId);
        return this.stopFor(requestId);
      }

      case "QUEUE_REORDER": {
        const ids = numbersFrom(json?.itemIds);
        if (!ids || ids.length === 0) return invalid("INVALID_PARAMS");
        const before = typeof json?.insertBefore === "number" ? json.insertBefore : undefined;
        if (!this.queue.reorder(ids, before)) return invalid("INVALID_PARAMS");
        return changed();
      }

      case "QUEUE_UPDATE": {
        if (json?.repeatMode !== undefined) {
          if (!isRepeatMode(json.repeatMode)) return invalid("INVALID_PARAMS");
          this.queue.repeatMode = json.repeatMode;
        }
        const jump = typeof json?.jump === "number" ? Math.trunc(json.jump) : 0;
        if (jump !== 0 && this.queue.current()) {
          const index = Math.max(0, Math.min(this.queue.length - 1, this.queue.indexOf(this.queue.currentItemId!) + jump));
          const target = this.queue.list()[index];
          if (target) this.queue.jumpTo(target.itemId);
          return this.startCurrentFor(sourceId, requestId);
        }
        return changed();
      }

      case "QUEUE_NEXT":
      case "QUEUE_PREV": {
        const target = type === "QUEUE_NEXT" ? this.queue.peekNext() : this.queue.peekPrev();
        if (!target) return changed();
        this.queue.jumpTo(target.itemId);
        return this.startCurrentFor(sourceId, requestId);
      }

      case "QUEUE_GET_ITEM_IDS":
        return reply(JSON.stringify({ type: "QUEUE_ITEM_IDS", requestId, itemIds: this.queue.ids() }));

      case "QUEUE_GET_ITEMS": {
        const wanted = numbersFrom(json?.itemIds);
        const items = (wanted ? wanted.map((id) => this.queue.get(id)).filter((item) => item !== undefined) : this.queue.list()).map(
          (item) => ({ itemId: item.itemId, media: item.media, autoplay: item.autoplay, startTime: item.startTime, activeTrackIds: item.activeTrackIds, customData: item.customData })
        );
        return reply(JSON.stringify({ type: "QUEUE_ITEMS", requestId, items }));
      }

      case "PLAY":
        this.state.playerState = "PLAYING";
        this.state.idleReason = undefined;
        this.bridge.onPlay?.();
        return changed();

      case "PAUSE":
        this.state.playerState = "PAUSED";
        this.bridge.onPause?.();
        return changed();

      case "STOP":
        return this.stopFor(requestId);

      case "SEEK": {
        const relative = typeof json?.relativeTime === "number" ? (json.relativeTime as number) : undefined;
        const absolute = typeof json?.currentTime === "number" ? (json.currentTime as number) : undefined;
        const target = absolute ?? Math.max(0, this.state.currentTime + (relative ?? 0));
        this.state.currentTime = target;
        // resumeState says whether playback continues after the seek.
        if (json?.resumeState === "PLAY") {
          this.state.playerState = "PLAYING";
          this.state.idleReason = undefined;
        } else if (json?.resumeState === "PAUSE") {
          this.state.playerState = "PAUSED";
        }
        this.bridge.onSeek?.(target);
        return changed();
      }

      case "SET_PLAYBACK_RATE": {
        const rate = json?.playbackRate;
        if (typeof rate !== "number" || !(rate >= 0.25 && rate <= 4)) return invalid("INVALID_PARAMS");
        this.state.playbackRate = rate;
        this.bridge.onRate?.(rate);
        return changed();
      }

      case "EDIT_TRACKS_INFO": {
        const ids = numbersFrom(json?.activeTrackIds) ?? [];
        this.state.activeTrackIds = ids;
        this.bridge.onTracks?.(ids);
        return changed();
      }

      case "GET_STATUS":
      case "GET_MEDIA_STATUS":
        this.bridge.onStatusRequest?.();
        return { text: this.mediaStatusTo(sourceId, requestId), binary: [] };

      case "PRECACHE":
      case "USER_ACTION":
        return { text: [], binary: [] };

      default: {
        if (parseMediaStatus(json)) return { text: [], binary: [] };
        this.log(`media: unsupported command ${type || "(none)"} from ${sender.id}`);
        return invalid("INVALID_COMMAND");
      }
    }
  }

  /**
   * Start the queue's current item and answer the sender. A refused item gets
   * LOAD_FAILED addressed to the sender and no status broadcast, as before.
   */
  private startCurrentFor(sourceId: string, requestId: number, startTime?: number): HandleResult {
    const item = this.queue.current();
    if (!item) return this.stopFor(requestId);
    if (!this.startCurrent(startTime)) {
      return { text: [], binary: [this.loadFailedBinary(sourceId, requestId, item.itemId)] };
    }
    return { text: this.broadcastMedia(requestId), binary: [] };
  }

  /** Begin playback of the queue's current item. False when the bridge refuses it (state becomes IDLE/ERROR). */
  private startCurrent(startTime?: number): boolean {
    const item = this.queue.current();
    if (!item) return false;
    const currentTime = startTime ?? item.startTime;
    const accepted = this.bridge.onLoad?.(item.media, { autoplay: item.autoplay, currentTime });
    if (accepted === false) {
      this.state = { ...this.state, playerState: "IDLE", idleReason: "ERROR", media: undefined, currentItemId: item.itemId };
      this.log(`media: refused ${item.media.contentId}`);
      return false;
    }
    this.appRunning = true;
    this.state = {
      mediaSessionId: this.nextSession(),
      playerState: item.autoplay ? "BUFFERING" : "PAUSED",
      media: item.media,
      currentTime,
      currentItemId: item.itemId,
      volume: { ...this.volume },
      playbackRate: this.state.playbackRate,
      activeTrackIds: item.activeTrackIds,
    };
    this.log(`media: LOAD ${item.media.contentId}`);
    return true;
  }

  private stopFor(requestId: number): HandleResult {
    this.state = { ...this.state, playerState: "IDLE", idleReason: "CANCELLED" };
    this.bridge.onStop?.();
    return { text: this.broadcastMedia(requestId), binary: [] };
  }

  private nextSession(): number {
    this.mediaSessionCounter += 1;
    return this.mediaSessionCounter;
  }

  private handleDeviceAuth(sourceId: string, payloadType: number, payload: string | Uint8Array): HandleResult {
    if (payloadType !== PAYLOAD_BINARY || !this.deviceAuth) return { text: [], binary: [] };
    const challenge = extractChallenge(payload instanceof Uint8Array ? payload : new TextEncoder().encode(payload));
    const auth = this.deviceAuth(challenge);
    this.log(`deviceauth: answered challenge from ${sourceId}`);
    return {
      text: [],
      binary: [
        {
          destinationId: sourceId,
          namespace: NS_DEVICE_AUTH,
          payload: encodeAuthResponse(auth.signature, auth.certificate),
        },
      ],
    };
  }

  // --- outgoing messages --------------------------------------------------

  statusTo(destinationId: string, requestId: number, withApp = this.appRunning): OutgoingText[] {
    const status: Json = {
      applications: withApp
        ? [
            {
              appId: this.config.appId,
              appType: "WEB",
              displayName: this.config.appDisplayName,
              iconUrl: "",
              isIdleScreen: false,
              launchedFromCloud: false,
              namespaces: [{ name: NS_MEDIA }, { name: "urn:x-cast:com.google.cast.debugoverlay" }],
              sessionId: `${this.config.transportId}-session`,
              statusText: this.config.statusText,
              transportId: this.config.transportId,
              universalAppId: this.config.appId,
            },
          ]
        : [],
      isActiveInput: true,
      isStandBy: false,
      userEq: {},
      volume: {
        controlType: "master",
        level: this.volume.level,
        muted: this.volume.muted,
        stepInterval: 0.05,
      },
    };
    return [{ destinationId, namespace: NS_RECEIVER, payload: receiverStatusPayload(requestId, status as never) }];
  }

  /** MEDIA_STATUS for one sender. */
  mediaStatusTo(destinationId: string, requestId: number): OutgoingText[] {
    return [{ destinationId, namespace: NS_MEDIA, payload: mediaStatus({ type: "MEDIA_STATUS", requestId, status: [this.statusEntry()] }) }];
  }

  /** MEDIA_STATUS for every connected sender (receivers broadcast state). */
  broadcastMedia(requestId = 0): OutgoingText[] {
    const payload = mediaStatus({ type: "MEDIA_STATUS", requestId, status: [this.statusEntry()] });
    return [{ destinationId: "*", namespace: NS_MEDIA, payload }];
  }

  statusEntry(): MediaStatusEntry {
    const entry: MediaStatusEntry = {
      mediaSessionId: this.state.mediaSessionId || this.mediaSessionCounter,
      playerState: this.state.playerState,
      currentTime: this.state.currentTime,
      volume: { level: this.volume.level, muted: this.volume.muted },
      supportedMediaCommands: SUPPORTED_MEDIA_COMMANDS,
      repeatMode: this.queue.repeatMode,
      playbackRate: this.state.playbackRate,
      activeTrackIds: this.state.activeTrackIds,
    };
    if (this.state.currentItemId !== undefined) entry.currentItemId = this.state.currentItemId;
    const next = this.queue.peekNext();
    if (next && next.itemId !== this.state.currentItemId) entry.nextItemId = next.itemId;
    if (this.state.idleReason) entry.idleReason = this.state.idleReason;
    if (this.state.media) entry.media = this.state.media;
    return entry;
  }

  /** Called by the player bridge when the real playback state changes. */
  updateFromPlayer(update: Partial<MediaState>): OutgoingText[] {
    const finished = update.playerState === "IDLE" && update.idleReason === "FINISHED";
    const next = finished && this.queue.currentItemId !== undefined ? this.queue.peekNext() : undefined;
    if (next) {
      // The queue goes on by itself. A refused item leaves the state at IDLE/ERROR.
      this.queue.jumpTo(next.itemId);
      this.startCurrent();
    } else {
      if (update.playerState !== undefined) this.state.playerState = update.playerState;
      if (update.currentTime !== undefined) this.state.currentTime = update.currentTime;
      if (update.media !== undefined) this.state.media = update.media;
      if (update.idleReason !== undefined) this.state.idleReason = update.idleReason;
    }
    if (this.state.mediaSessionId === 0) this.state.mediaSessionId = this.nextSession();
    return this.broadcastMedia();
  }

  private loadFailedBinary(destinationId: string, requestId: number, itemId?: number): OutgoingBinary {
    const payload = JSON.stringify({ type: "LOAD_FAILED", requestId, itemId, detailedErrorCode: 103 });
    return { destinationId, namespace: NS_MEDIA, payload: new TextEncoder().encode(payload) };
  }

  private sender(id: string): Sender {
    let sender = this.senders.get(id);
    if (!sender) {
      sender = { id, connected: false, lastSeen: Date.now() };
      this.senders.set(id, sender);
    }
    sender.lastSeen = Date.now();
    return sender;
  }
}

// --- deviceauth encoding ----------------------------------------------------

/** `DeviceAuthMessage { challenge = 1; response = 2 }` */
export function extractChallenge(payload: Uint8Array): Uint8Array | null {
  const reader = new Reader(payload);
  for (;;) {
    const field = reader.next();
    if (!field) break;
    if (field.field === 1 && field.data) return field.data.length > 0 ? field.data.slice() : null;
  }
  return null;
}

/**
 * `AuthResponse { signature = 1; client_auth_certificate = 2; client_ca = 4 }`
 * wrapped in `DeviceAuthMessage { response = 2 }`.
 */
export function encodeAuthResponse(signature: Uint8Array, certificate?: Uint8Array): Uint8Array {
  const response = new Writer();
  response.bytesField(1, signature);
  if (certificate) {
    response.bytesField(2, certificate);
    response.bytesField(4, certificate);
  }
  const out = new Writer();
  out.message(2, response.bytes());
  return out.bytes();
}

export function decodeAuthResponse(payload: Uint8Array): { signature?: Uint8Array; certificate?: Uint8Array } {
  const result: { signature?: Uint8Array; certificate?: Uint8Array } = {};
  const reader = new Reader(payload);
  for (;;) {
    const field = reader.next();
    if (!field) break;
    if (field.field !== 2 || !field.data) continue;
    const inner = new Reader(field.data);
    for (;;) {
      const nested = inner.next();
      if (!nested) break;
      if (nested.field === 1 && nested.data) result.signature = nested.data.slice();
      if (nested.field === 2 && nested.data && !result.certificate) result.certificate = nested.data.slice();
    }
  }
  return result;
}

export const CONNECTION_MESSAGE = connectionMessage;
export const GET_STATUS_MESSAGE = getStatus;
