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
  loadFailed,
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
import { Reader, Writer, decodeString } from "../protocol/protobuf.ts";

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
  private mediaSessionCounter = 1;

  volume = { level: 0.5, muted: false };
  state: MediaState = { mediaSessionId: 0, playerState: "IDLE", currentTime: 0, volume: { level: 0.5, muted: false } };

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
        return { text: this.statusTo(sourceId, requestId), binary: [] };
      }
      default:
        if (type !== "") this.log(`receiver: unknown message ${type}`);
        return { text: [], binary: [] };
    }
  }

  private handleMedia(sender: Sender, sourceId: string, json: Json | null, type: string): HandleResult {
    const requestId = requestIdOf(json);
    switch (type) {
      case "LOAD": {
        const media = (json?.media ?? null) as MediaInformation | null;
        if (!media || typeof media.contentId !== "string" || media.contentId === "") {
          return { text: [], binary: [] };
        }
        const accepted = this.bridge.onLoad?.(media, {
          autoplay: json?.autoplay !== false,
          currentTime: typeof json?.currentTime === "number" ? json.currentTime : 0,
        });
        if (accepted === false) {
          return { text: [], binary: [this.loadFailedBinary(sourceId, requestId)] };
        }
        this.appRunning = true;
        this.state = {
          mediaSessionId: this.mediaSessionCounter,
          playerState: "BUFFERING",
          media,
          currentTime: typeof json?.currentTime === "number" ? json.currentTime : 0,
          volume: { ...this.volume },
        };
        this.log(`media: LOAD ${media.contentId}`);
        return { text: this.mediaStatusTo(sourceId, requestId), binary: [] };
      }
      case "PLAY":
        this.state.playerState = "PLAYING";
        this.state.idleReason = undefined;
        this.bridge.onPlay?.();
        return { text: this.broadcastMedia(requestId), binary: [] };
      case "PAUSE":
        this.state.playerState = "PAUSED";
        this.bridge.onPause?.();
        return { text: this.broadcastMedia(requestId), binary: [] };
      case "STOP":
        this.state.playerState = "IDLE";
        this.state.idleReason = "CANCELLED";
        this.bridge.onStop?.();
        return { text: this.broadcastMedia(requestId), binary: [] };
      case "SEEK": {
        const relative = typeof json?.relativeTime === "number" ? (json.relativeTime as number) : undefined;
        const absolute = typeof json?.currentTime === "number" ? (json.currentTime as number) : undefined;
        const target = absolute ?? Math.max(0, this.state.currentTime + (relative ?? 0));
        this.state.currentTime = target;
        this.bridge.onSeek?.(target);
        return { text: this.broadcastMedia(requestId), binary: [] };
      }
      case "GET_STATUS":
      case "GET_MEDIA_STATUS":
        this.bridge.onStatusRequest?.();
        return { text: this.mediaStatusTo(sourceId, requestId), binary: [] };
      default: {
        const status = parseMediaStatus(json);
        if (status) return { text: [], binary: [] };
        this.log(`media: unknown message ${type} from ${sender.id}`);
        return { text: [], binary: [] };
      }
    }
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
      repeatMode: "REPEAT_OFF",
    };
    if (this.state.idleReason) entry.idleReason = this.state.idleReason;
    if (this.state.media) entry.media = this.state.media;
    return entry;
  }

  /** Called by the player bridge when the real playback state changes. */
  updateFromPlayer(update: Partial<MediaState>): OutgoingText[] {
    if (update.playerState !== undefined) this.state.playerState = update.playerState;
    if (update.currentTime !== undefined) this.state.currentTime = update.currentTime;
    if (update.media !== undefined) this.state.media = update.media;
    if (update.idleReason !== undefined) this.state.idleReason = update.idleReason;
    if (this.state.mediaSessionId === 0) this.state.mediaSessionId = this.mediaSessionCounter;
    return this.broadcastMedia();
  }

  private loadFailedBinary(destinationId: string, requestId: number): OutgoingBinary {
    return {
      destinationId,
      namespace: NS_MEDIA,
      payload: new TextEncoder().encode(loadFailed(requestId, 103)),
    };
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
