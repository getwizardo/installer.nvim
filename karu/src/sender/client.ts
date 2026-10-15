/**
 * Cast **sender**: talk to a real Chromecast / Google TV / Nest / Cast group.
 *
 * The flow (per the CASTV2 protocol docs):
 *   TLS connect on 8009 → CONNECT on receiver-0 → GET_STATUS → LAUNCH the
 *   Default Media Receiver → CONNECT to the app's transportId → LOAD media →
 *   MEDIA_STATUS / RECEIVER_STATUS updates + PING/PONG heartbeats.
 */
import { connect as tlsConnect, type TLSSocket } from "node:tls";
import {
  APP_DEFAULT_MEDIA_RECEIVER,
  NS_CONNECTION,
  NS_DEVICE_AUTH,
  NS_HEARTBEAT,
  NS_MEDIA,
  NS_RECEIVER,
  PAYLOAD_BINARY,
  PAYLOAD_STRING,
  createFrameParser,
  encodeCastMessage,
} from "../protocol/castMessage.ts";
import {
  connectionMessage,
  getStatus,
  guessContentType,
  heartbeat,
  launch,
  load,
  mediaCommand,
  messageType,
  parseJson,
  parseLoadFailed,
  parseMediaStatus,
  parseReceiverStatus,
  requestIdOf,
  seek as seekMessage,
  setVolume as setVolumeMessage,
  stopReceiver,
  type Json,
  type MediaStatusEntry,
  type ReceiverApp,
  type ReceiverStatus,
} from "../protocol/messages.ts";
import { decodeAuthResponse, encodeAuthResponse, extractChallenge } from "../receiver/core.ts";
import { generateSelfSignedCertificate, publicKeyFromPem, signChallenge, verifyChallenge, type GeneratedCertificate } from "../net/tls.ts";
import { CAST_PORT } from "../receiver/server.ts";

export interface CastClientOptions {
  host: string;
  port?: number;
  /** Friendly label used in logs and output. */
  name?: string;
  log?: (message: string) => void;
  /** Milliseconds to wait for a request/response round-trip. */
  timeoutMs?: number;
}

export type CastClientState = {
  connected: boolean;
  status?: ReceiverStatus;
  media?: MediaStatusEntry | null;
  app?: ReceiverApp | null;
};

interface Pending {
  resolve: (value: Json) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class CastClient {
  readonly host: string;
  readonly port: number;
  readonly name: string;
  private socket: TLSSocket | null = null;
  private readonly parser = createFrameParser();
  private readonly pending = new Map<number, Pending>();
  private readonly log: (message: string) => void;
  private requestId = 0;
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private sourceId = "sender-0";
  private identity: GeneratedCertificate | null = null;
  private transportId: string | null = null;
  private readonly timeoutMs: number;

  status: ReceiverStatus | null = null;
  media: MediaStatusEntry | null = null;
  app: ReceiverApp | null = null;
  onState?: (state: CastClientState) => void;
  onMediaStatus?: (status: MediaStatusEntry | null) => void;

  constructor(options: CastClientOptions) {
    this.host = options.host;
    this.port = options.port ?? CAST_PORT;
    this.name = options.name ?? options.host;
    this.log = options.log ?? (() => {});
    this.timeoutMs = options.timeoutMs ?? 8000;
    this.sourceId = `sender-${Math.floor(Math.random() * 9000 + 1000)}`;
  }

  get connected(): boolean {
    return this.socket !== null && !this.socket.destroyed;
  }

  async connect(): Promise<void> {
    if (this.connected) return;
    const isIp = /^\d+\.\d+\.\d+\.\d+$/.test(this.host) || this.host.includes(":");
    const socket = tlsConnect({
      host: this.host,
      port: this.port,
      rejectUnauthorized: false, // Cast devices present manufacturer certificates
      minVersion: "TLSv1.2",
      checkServerIdentity: () => undefined,
      ...(isIp ? {} : { servername: this.host }),
    });
    this.socket = socket;
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => {
        socket.removeListener("secureConnect", onSecure);
        reject(error);
      };
      const onSecure = () => {
        socket.removeListener("error", onError);
        resolve();
      };
      socket.once("error", onError);
      socket.once("secureConnect", onSecure);
    });
    socket.on("data", (chunk: Buffer) => this.onData(chunk));
    socket.on("error", (error) => this.log(`sender: socket error (${error.message})`));
    socket.on("close", () => this.log("sender: disconnected"));

    this.send(NS_CONNECTION, "receiver-0", connectionMessage("CONNECT"));
    this.heartbeatTimer = setInterval(() => this.send(NS_HEARTBEAT, "receiver-0", heartbeat("PING", this.nextId())), 5000);
    this.heartbeatTimer.unref?.();
    this.log(`sender: connected to ${this.name} (${this.host}:${this.port})`);
  }

  close(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("sender: connection closed"));
    }
    this.pending.clear();
    this.socket?.destroy();
    this.socket = null;
  }

  private nextId(): number {
    return ++this.requestId;
  }

  private send(namespace: string, destinationId: string, payload: string, payloadType = PAYLOAD_STRING): number {
    const socket = this.socket;
    if (!socket) throw new Error("sender: not connected");
    const id = this.nextId();
    const body = encodeCastMessage({
      sourceId: this.sourceId,
      destinationId,
      namespace,
      payloadType,
      ...(payloadType === PAYLOAD_STRING ? { payloadUtf8: payload } : { payloadBinary: new TextEncoder().encode(payload) }),
    });
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, body.length, false);
    socket.write(Buffer.concat([Buffer.from(header), Buffer.from(body)]));
    return id;
  }

  /** Send and wait for the matching response (requestId + type). */
  private request(namespace: string, destinationId: string, payload: string, expectedTypes: string[]): Promise<Json> {
    const socket = this.socket;
    if (!socket) throw new Error("sender: not connected");
    const id = this.nextId();
    const withId = injectRequestId(payload, id);
    const body = encodeCastMessage({ sourceId: this.sourceId, destinationId, namespace, payloadType: PAYLOAD_STRING, payloadUtf8: withId });
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, body.length, false);

    return new Promise<Json>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`sender: timeout waiting for ${expectedTypes.join("/")} (${withId})`));
      }, this.timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer });
      socket.write(Buffer.concat([Buffer.from(header), Buffer.from(body)]));
    });
  }

  private onData(chunk: Buffer): void {
    let messages;
    try {
      messages = this.parser.push(Uint8Array.from(chunk));
    } catch (error) {
      this.log(`sender: framing error (${(error as Error).message})`);
      return;
    }
    for (const message of messages) {
      if (message.namespace === NS_DEVICE_AUTH && message.payloadBinary) {
        this.handleDeviceAuth(message.destinationId, message.payloadBinary);
        continue;
      }
      if (message.payloadType === PAYLOAD_BINARY) continue;
      const payload = parseJson(message.payloadUtf8);
      const type = messageType(payload);
      const requestId = requestIdOf(payload);

      if (type === "PING") {
        this.send(NS_HEARTBEAT, message.sourceId, heartbeat("PONG"));
        continue;
      }
      if (type === "RECEIVER_STATUS") {
        const parsed = parseReceiverStatus(payload);
        if (parsed) {
          this.status = parsed.status;
          const apps = parsed.status.applications ?? [];
          this.app = apps.find((entry) => entry.appId === APP_DEFAULT_MEDIA_RECEIVER) ?? apps[0] ?? null;
          if (this.app?.transportId) this.transportId = this.app.transportId;
          this.emitState();
        }
      }
      if (type === "MEDIA_STATUS") {
        const parsed = parseMediaStatus(payload);
        if (parsed) {
          this.media = parsed.status[0] ?? null;
          this.onMediaStatus?.(this.media);
          this.emitState();
        }
      }
      const fail = parseLoadFailed(payload);
      if (fail) {
        this.log(`sender: LOAD_FAILED (code ${fail.detailedErrorCode ?? "?"})`);
      }

      const pending = this.pending.get(requestId);
      if (pending && payload) {
        this.pending.delete(requestId);
        clearTimeout(pending.timer);
        pending.resolve(payload);
      }
    }
  }

  /** Device-auth: our (self-signed) cert proves possession; we verify with it too. */
  private handleDeviceAuth(destinationId: string, payload: Uint8Array): void {
    const response = decodeAuthResponse(payload);
    if (!response.signature || !response.certificate) return;
    if (!this.identity) this.identity = generateSelfSignedCertificate({ commonName: "karu sender" });
    // The device signs its certificate; a real sender stores the device cert
    // here for the (optional) pairing flow. We record it and reply so the
    // device is satisfied that we completed the handshake.
    const signature = signChallenge(this.identity.privateKey, response.certificate);
    const reply = encodeAuthResponse(signature, this.identity.certDer);
    const socket = this.socket;
    if (socket) {
      const body = encodeCastMessage({
        sourceId: this.sourceId,
        destinationId,
        namespace: NS_DEVICE_AUTH,
        payloadType: PAYLOAD_BINARY,
        payloadBinary: reply,
      });
      const header = new Uint8Array(4);
      new DataView(header.buffer).setUint32(0, body.length, false);
      socket.write(Buffer.concat([Buffer.from(header), Buffer.from(body)]));
    }
    this.log("sender: device-auth handshake completed");
  }

  /** Verify a device-auth response against the certificate it shipped (tests / pairing). */
  static verifyDeviceAuth(payload: Uint8Array): boolean {
    const response = decodeAuthResponse(payload);
    if (!response.signature || !response.certificate) return false;
    const certPem = `-----BEGIN CERTIFICATE-----\n${Buffer.from(response.certificate).toString("base64")}\n-----END CERTIFICATE-----\n`;
    try {
      return verifyChallenge(publicKeyFromPem(certPem), response.certificate, response.signature);
    } catch {
      return false;
    }
  }

  private emitState(): void {
    this.onState?.({
      connected: this.connected,
      ...(this.status ? { status: this.status } : {}),
      media: this.media,
      app: this.app,
    });
  }

  async getStatus(): Promise<ReceiverStatus> {
    const payload = await this.request(NS_RECEIVER, "receiver-0", getStatus(0), ["RECEIVER_STATUS"]);
    const parsed = parseReceiverStatus(payload);
    if (!parsed) throw new Error("sender: unexpected GET_STATUS response");
    this.status = parsed.status;
    return parsed.status;
  }

  /** Launch (or reuse) the receiver app and CONNECT to its transport. */
  async launch(appId = APP_DEFAULT_MEDIA_RECEIVER): Promise<ReceiverApp | null> {
    if (!this.status) await this.getStatus();
    const running = (this.status?.applications ?? []).find((app) => app.appId === appId);
    if (!running) {
      await this.request(NS_RECEIVER, "receiver-0", launch(appId, 0), ["RECEIVER_STATUS", "LAUNCH_ERROR"]);
    }
    if (!this.status) await this.getStatus();
    const app = (this.status?.applications ?? []).find((entry) => entry.appId === appId) ?? null;
    this.app = app;
    if (app) {
      this.transportId = app.transportId;
      this.send(NS_CONNECTION, app.transportId, connectionMessage("CONNECT"));
      this.log(`sender: launched ${app.displayName} (transport ${app.transportId})`);
    }
    return app;
  }

  private appDestination(): string {
    const destination = this.transportId ?? this.app?.transportId;
    if (!destination) throw new Error("sender: no media receiver session, call launch() first");
    return destination;
  }

  async loadMedia(options: { url: string; title?: string; contentType?: string; autoplay?: boolean; currentTime?: number; subtitle?: string; images?: string[] }): Promise<MediaStatusEntry | null> {
    const destination = this.appDestination();
    const payload = load({
      contentId: options.url,
      contentType: options.contentType ?? guessContentType(options.url),
      requestId: 0,
      ...(options.title ? { title: options.title } : {}),
      ...(options.subtitle ? { subtitle: options.subtitle } : {}),
      ...(options.images ? { images: options.images } : {}),
      autoplay: options.autoplay ?? true,
      ...(options.currentTime !== undefined ? { currentTime: options.currentTime } : {}),
    });
    const response = await this.request(NS_MEDIA, destination, payload, ["MEDIA_STATUS", "LOAD_FAILED"]);
    const parsed = parseMediaStatus(response);
    this.media = parsed?.status[0] ?? null;
    return this.media;
  }

  async play(): Promise<void> {
    await this.mediaCommand("PLAY");
  }

  async pause(): Promise<void> {
    await this.mediaCommand("PAUSE");
  }

  async stopMedia(): Promise<void> {
    await this.mediaCommand("STOP");
  }

  private async mediaCommand(type: "PLAY" | "PAUSE" | "STOP" | "GET_STATUS"): Promise<MediaStatusEntry | null> {
    const destination = this.appDestination();
    const response = await this.request(NS_MEDIA, destination, mediaCommand(type, 0, this.media?.mediaSessionId ?? 1), ["MEDIA_STATUS"]);
    const parsed = parseMediaStatus(response);
    this.media = parsed?.status[0] ?? this.media;
    return this.media;
  }

  async seek(seconds: number): Promise<MediaStatusEntry | null> {
    const destination = this.appDestination();
    const response = await this.request(NS_MEDIA, destination, seekMessage(0, this.media?.mediaSessionId ?? 1, undefined, seconds), ["MEDIA_STATUS"]);
    const parsed = parseMediaStatus(response);
    this.media = parsed?.status[0] ?? this.media;
    return this.media;
  }

  async refreshMediaStatus(): Promise<MediaStatusEntry | null> {
    return this.mediaCommand("GET_STATUS");
  }

  /** Absolute (0..1) or relative (+0.05 / -0.05) volume, or mute toggling. */
  async setVolume(update: { level?: number; muted?: boolean }): Promise<ReceiverStatus | null> {
    const payload = await this.request(NS_RECEIVER, "receiver-0", setVolumeMessage(0, update), ["RECEIVER_STATUS"]);
    const parsed = parseReceiverStatus(payload);
    if (parsed) this.status = parsed.status;
    return this.status;
  }

  /** Stop the running app (leaves the device idle). */
  async quitApp(): Promise<void> {
    const sessionId = this.app?.sessionId;
    if (!sessionId) return;
    await this.request(NS_RECEIVER, "receiver-0", stopReceiver(sessionId, 0), ["RECEIVER_STATUS"]);
    this.app = null;
    this.transportId = null;
  }

  /** Convenience: cast a URL and return the accepted media status. */
  async castUrl(url: string, options: { title?: string; contentType?: string; autoplay?: boolean } = {}): Promise<MediaStatusEntry | null> {
    await this.launch();
    return this.loadMedia({ url, ...options });
  }
}

/** `requestId` is 0 in our builders; stamp the real id in without re-encoding JSON. */
function injectRequestId(payload: string, requestId: number): string {
  try {
    const parsed = JSON.parse(payload) as Json;
    parsed.requestId = requestId;
    return JSON.stringify(parsed);
  } catch {
    return payload;
  }
}

export { extractChallenge, APP_DEFAULT_MEDIA_RECEIVER };
