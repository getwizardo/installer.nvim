/**
 * The Cast receiver socket server: TLS on 8009 (Cast's fixed port), mDNS
 * advertisement, and the glue between sockets and `ReceiverCore`.
 */
import { createServer, type Server, type TLSSocket } from "node:tls";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { NS_CONNECTION, NS_HEARTBEAT, NS_RECEIVER, PAYLOAD_BINARY, PAYLOAD_STRING, encodeCastMessage, createFrameParser } from "../protocol/castMessage.ts";
import { MdnsResponder, deviceIdFrom, hostName, primaryAddress, type CastServiceConfig } from "../net/mdns.ts";
import { TLS_MIN_VERSION, loadOrCreateCertificate, signChallenge, type CertificateFiles } from "../net/tls.ts";
import { ReceiverCore, PLATFORM_ID, encodeAuthResponse, type HandleResult, type ReceiverConfig } from "./core.ts";
import type { PlayerBridge } from "./core.ts";

export const CAST_PORT = 8009;

export interface ReceiverServerOptions {
  name?: string;
  port?: number;
  address?: string;
  /** Skip mDNS (tests, or when another responder owns the name). */
  advertise?: boolean;
  appId?: string;
  appDisplayName?: string;
  bridge?: PlayerBridge;
  certDir?: string;
  log?: (message: string) => void;
  /** Extra TXT keys for the mDNS record (e.g. a YouTube app id). */
  txt?: Record<string, string>;
}

export interface ReceiverInfo {
  name: string;
  deviceId: string;
  port: number;
  address: string;
  host: string;
  appId: string;
  certDir: string;
}

interface Connection {
  socket: TLSSocket;
  sourceId: string;
  parser: ReturnType<typeof createFrameParser>;
  lastSeen: number;
}

export class CastReceiverServer {
  private server: Server | null = null;
  private responder: MdnsResponder | null = null;
  private readonly connections = new Set<Connection>();
  private core: ReceiverCore | null = null;
  private cert: CertificateFiles | null = null;
  private idleTimer: NodeJS.Timeout | null = null;

  private readonly options: ReceiverServerOptions;
  private readonly log: (message: string) => void;
  info: ReceiverInfo | null = null;

  constructor(options: ReceiverServerOptions = {}) {
    this.options = options;
    this.log = options.log ?? (() => {});
  }

  /** The receiver state machine (exposed for the bridge and for tests). */
  get receiver(): ReceiverCore {
    if (!this.core) throw new Error("karu: receiver not started");
    return this.core;
  }

  async start(): Promise<ReceiverInfo> {
    const port = this.options.port ?? CAST_PORT;
    const address = this.options.address ?? primaryAddress();
    const name = this.options.name ?? "Karu · Neovim";
    const host = hostName();
    const deviceId = deviceIdFrom(host + name);
    const certDir = this.options.certDir ?? defaultCertDir();

    this.cert = loadOrCreateCertificate(certDir, { commonName: name });
    if (this.cert.created) this.log(`tls: generated a self-signed certificate in ${certDir}`);

    const config: ReceiverConfig = {
      name,
      deviceId,
      port,
      appId: this.options.appId,
      appDisplayName: this.options.appDisplayName ?? "Default Media Receiver",
      statusText: name,
    };

    this.core = new ReceiverCore({
      config,
      ...(this.options.bridge ? { bridge: this.options.bridge } : {}),
      deviceAuth: () => ({ signature: signChallenge(this.cert!.privateKey, this.cert!.certDer), certificate: this.cert!.certDer }),
      log: this.log,
    });

    const server = createServer(
      {
        key: this.cert.keyPem,
        cert: this.cert.certPem,
        requestCert: false,
        rejectUnauthorized: false,
        minVersion: TLS_MIN_VERSION,
      },
      (socket) => this.handleConnection(socket)
    );
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, "0.0.0.0", () => {
        server.removeListener("error", reject);
        resolve();
      });
    });
    server.on("error", (error) => this.log(`receiver: ${error.message}`));
    // Port 0 means "pick a free port" (used by tests) — report the real one.
    const bound = server.address();
    const boundPort = typeof bound === "object" && bound ? bound.port : port;

    if (this.options.advertise !== false) {
      const service: CastServiceConfig = {
        name,
        host,
        address,
        port: boundPort,
        ...(this.options.txt ? { txt: this.options.txt } : {}),
      };
      this.responder = new MdnsResponder(service, { log: this.log });
      try {
        await this.responder.start();
      } catch (error) {
        this.log(`mdns: unavailable (${(error as Error).message}) — senders must add the address manually`);
        this.responder = null;
      }
    }

    this.idleTimer = setInterval(() => this.sweepIdle(), 15_000);
    this.idleTimer.unref?.();

    this.info = { name, deviceId, port: boundPort, address, host, appId: config.appId ?? "", certDir };
    this.log(`karu: receiving on ${address}:${boundPort} as “${name}” (id ${deviceId})`);
    return this.info;
  }

  async stop(): Promise<void> {
    if (this.idleTimer) clearInterval(this.idleTimer);
    this.idleTimer = null;
    for (const connection of this.connections) connection.socket.destroy();
    this.connections.clear();
    await this.responder?.stop();
    this.responder = null;
    const server = this.server;
    this.server = null;
    if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  /** Push the real playback state to every connected sender. */
  updateFromPlayer(update: Parameters<ReceiverCore["updateFromPlayer"]>[0]): number {
    if (!this.core) return 0;
    const messages = this.core.updateFromPlayer(update);
    let sent = 0;
    for (const message of messages) sent += this.write(message);
    return sent;
  }

  private handleConnection(socket: TLSSocket): void {
    const connection: Connection = { socket, sourceId: "", parser: createFrameParser(), lastSeen: Date.now() };
    this.connections.add(connection);
    this.log(`receiver: connection from ${socket.remoteAddress ?? "?"}`);

    socket.on("data", (chunk: Buffer) => {
      connection.lastSeen = Date.now();
      let messages;
      try {
        messages = connection.parser.push(Uint8Array.from(chunk));
      } catch (error) {
        this.log(`receiver: framing error (${(error as Error).message})`);
        socket.destroy();
        return;
      }
      for (const message of messages) {
        if (message.sourceId) connection.sourceId = message.sourceId;
        let result: HandleResult;
        try {
          result = this.core!.handle(
            message.sourceId,
            message.destinationId,
            message.namespace,
            message.payloadType,
            message.payloadType === PAYLOAD_BINARY ? (message.payloadBinary ?? new Uint8Array(0)) : (message.payloadUtf8 ?? "")
          );
        } catch (error) {
          this.log(`receiver: handler error (${(error as Error).message})`);
          continue;
        }
        for (const text of result.text) this.write({ ...text, via: connection });
        for (const binary of result.binary) this.write({ ...binary, via: connection });
      }
    });

    socket.on("error", (error) => this.log(`receiver: socket error (${error.message})`));
    socket.on("close", () => {
      this.connections.delete(connection);
      this.log(`receiver: connection closed (${connection.sourceId || "unknown"})`);
    });
  }

  /** Write one message; `destinationId === "*"` fans out to every sender. */
  private write(message: { destinationId: string; namespace: string; payload: string | Uint8Array; via?: Connection }): number {
    const isBinary = typeof message.payload !== "string";
    const payloadUtf8 = typeof message.payload === "string" ? message.payload : undefined;
    const payloadBinary = typeof message.payload !== "string" ? message.payload : undefined;

    if (message.destinationId === "*") {
      let count = 0;
      for (const connection of this.connections) {
        if (!connection.sourceId) continue;
        count += this.writeTo(connection, message.namespace, PAYLOAD_STRING, payloadUtf8, payloadBinary, message.via);
      }
      return count;
    }
    const target = message.via ?? this.findBySourceId(message.destinationId);
    if (!target) return 0;
    return this.writeTo(target, message.namespace, isBinary ? PAYLOAD_BINARY : PAYLOAD_STRING, payloadUtf8, payloadBinary, message.via);
  }

  private writeTo(
    connection: Connection,
    namespace: string,
    payloadType: number,
    payloadUtf8: string | undefined,
    payloadBinary: Uint8Array | undefined,
    via: Connection | undefined
  ): number {
    // The platform endpoint answers with receiver-0; app endpoints keep the
    // transport id. Senders match on source/destination, so be consistent.
    const sourceId = namespace === NS_HEARTBEAT || namespace === NS_RECEIVER || namespace === NS_CONNECTION ? PLATFORM_ID : (this.core?.config.transportId ?? "web-1");
    const destination = connection.sourceId || via?.sourceId || "sender-0";
    const frame = encodeCastMessage({
      sourceId,
      destinationId: destination,
      namespace,
      payloadType,
      ...(payloadUtf8 !== undefined ? { payloadUtf8 } : {}),
      ...(payloadBinary !== undefined ? { payloadBinary } : {}),
    });
    const length = new Uint8Array(4);
    new DataView(length.buffer).setUint32(0, frame.length, false);
    connection.socket.write(Buffer.concat([Buffer.from(length), Buffer.from(frame)]));
    return 1;
  }

  private findBySourceId(sourceId: string): Connection | undefined {
    for (const connection of this.connections) {
      if (connection.sourceId === sourceId) return connection;
    }
    return undefined;
  }

  private sweepIdle(): void {
    const cutoff = Date.now() - 60_000;
    for (const connection of this.connections) {
      if (connection.lastSeen < cutoff) {
        this.log(`receiver: closing idle connection ${connection.sourceId || "unknown"}`);
        connection.socket.destroy();
        this.connections.delete(connection);
      }
    }
  }
}

export function defaultCertDir(): string {
  const base = process.env["XDG_DATA_HOME"] ?? process.env["XDG_CACHE_HOME"] ?? join(tmpdir(), "karu");
  const dir = join(base, "karu");
  mkdirSync(dir, { recursive: true });
  return dir;
}

export { encodeAuthResponse };
