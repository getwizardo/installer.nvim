/**
 * Multicast DNS (`_googlecast._tcp.local`), responder + browser.
 *
 * Cast devices are discovered over mDNS: a sender multicasts a PTR query for
 * `_googlecast._tcp.local`, and each device answers with PTR (instance name),
 * SRV (host + port 8009), TXT (id / fn / md / ve / ca / st / rs) and an A or
 * AAAA record with its address.
 *
 * Karu plays both sides: `MdnsResponder` makes this machine show up in the
 * YouTube / YouTube Music app's Cast list, `MdnsBrowser` finds real devices so
 * `:Karu cast` can send to them.
 */
import { createSocket, type Socket } from "node:dgram";
import { networkInterfaces } from "node:os";
import {
  CLASS_IN,
  TYPE_A,
  TYPE_ANY,
  TYPE_PTR,
  TYPE_SRV,
  TYPE_TXT,
  decodePacket,
  encodePacket,
  type ResourceRecord,
  txtEntriesToObject,
} from "./dns.ts";

export const GOOGLECAST_SERVICE = "_googlecast._tcp.local";
export const MDNS_ADDRESS = "224.0.0.251";
export const MDNS_PORT = 5353;
/** Records live 75 minutes; re-announce well before that. */
export const RECORD_TTL = 4500;

export interface CastServiceConfig {
  /** Friendly name shown by senders, e.g. `Karu · Neovim`. */
  name: string;
  /** mDNS host name of this machine, e.g. `karu-nvim.local`. */
  host: string;
  /** Address advertised in the A record. */
  address: string;
  port: number;
  /** Extra TXT keys; sensible Cast defaults are filled in for you. */
  txt?: Record<string, string>;
}

export const DEFAULT_MODEL = "Karu";

/** Escape a label so dots inside an instance name survive encoding. */
export function escapeLabel(label: string): string {
  return label.replace(/([.\\])/g, "\\$1");
}

export function instanceName(config: Pick<CastServiceConfig, "name">): string {
  return `${escapeLabel(config.name)}.${GOOGLECAST_SERVICE}`;
}

/** Pick a stable-ish device id (12 hex chars) from the machine hostname. */
export function deviceIdFrom(seed: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < seed.length; i++) {
    hash ^= seed.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  let out = "";
  let value = hash;
  for (let i = 0; i < 3; i++) {
    out += (value >>> 0).toString(16).padStart(8, "0").slice(0, 4);
    value = Math.imul(value ^ 0x9e3779b9, 0x85ebca6b) >>> 0;
  }
  return out.slice(0, 12);
}

/** The TXT record a Cast sender expects. */
export function serviceTxt(config: CastServiceConfig): string[] {
  const txt: Record<string, string> = {
    id: deviceIdFrom(config.host),
    fn: config.name,
    md: DEFAULT_MODEL,
    ve: "05",
    ca: "5",
    st: "0",
    ic: "/setup/icon.png",
    rm: "",
    rs: "",
  };
  return Object.entries({ ...txt, ...(config.txt ?? {}) }).map(([key, value]) => `${key}=${value}`);
}

/** PTR + SRV + TXT (+ A) records describing our service. */
export function serviceRecords(config: CastServiceConfig, options: { includeAddress?: boolean } = {}): ResourceRecord[] {
  const instance = instanceName(config);
  const records: ResourceRecord[] = [
    {
      name: GOOGLECAST_SERVICE,
      type: TYPE_PTR,
      klass: CLASS_IN,
      ttl: RECORD_TTL,
      flush: false, // PTR records are shared between responders
      data: { kind: "ptr", target: instance },
    },
    {
      name: instance,
      type: TYPE_SRV,
      klass: CLASS_IN,
      ttl: RECORD_TTL,
      flush: true,
      data: { kind: "srv", priority: 0, weight: 0, port: config.port, target: config.host },
    },
    {
      name: instance,
      type: TYPE_TXT,
      klass: CLASS_IN,
      ttl: RECORD_TTL,
      flush: true,
      data: { kind: "txt", entries: serviceTxt(config) },
    },
  ];
  if (options.includeAddress !== false) {
    records.push({
      name: config.host,
      type: TYPE_A,
      klass: CLASS_IN,
      ttl: RECORD_TTL,
      flush: true,
      data: { kind: "a", address: config.address },
    });
  }
  return records;
}

/** A PTR question for the Cast service (what a sender multicasts). */
export function browseQuery(id = 0): Uint8Array {
  return encodePacket({
    id,
    response: false,
    questions: [{ name: GOOGLECAST_SERVICE, type: TYPE_PTR, klass: CLASS_IN, unicastResponse: false }],
  });
}

export interface CastDevice {
  /** TXT `id`, the stable device id senders also use. */
  id: string;
  /** TXT `fn`, falling back to the mDNS instance name. */
  name: string;
  /** TXT `md`, model name. */
  model: string;
  address: string;
  port: number;
  host: string;
  txt: Record<string, string>;
  /** Where the record came from: "mdns" or a manual address. */
  source: "mdns" | "manual";
}

// ---------------------------------------------------------------------------
// Responder
// ---------------------------------------------------------------------------

export interface ResponderOptions {
  address?: string;
  /** Answer timeouts, probes and unicast requests the way Avahi does. */
  log?: (message: string) => void;
}

export class MdnsResponder {
  private socket: Socket | null = null;
  private readonly address: string;
  private readonly log: (message: string) => void;
  private announceTimer: NodeJS.Timeout | null = null;
  /** Services we answer for (Cast, plus anything else registered later). */
  private readonly services: CastServiceConfig[] = [];

  constructor(config: CastServiceConfig, options: ResponderOptions = {}) {
    this.address = options.address ?? config.address;
    config.address = this.address;
    this.services.push(config);
    this.log = options.log ?? (() => {});
  }

  addService(config: CastServiceConfig): void {
    this.services.push(config);
  }

  get config(): CastServiceConfig {
    return this.services[0]!;
  }

  async start(): Promise<void> {
    if (this.socket) return;
    const socket = createSocket({ type: "udp4", reuseAddr: true });
    this.socket = socket;
    await new Promise<void>((resolve, reject) => {
      socket.once("error", reject);
      socket.bind(MDNS_PORT, () => {
        try {
          socket.addMembership(MDNS_ADDRESS);
          socket.setMulticastTTL(255);
          socket.setMulticastLoopback(true);
        } catch (error) {
          this.log(`mdns: membership failed: ${(error as Error).message}`);
        }
        socket.removeListener("error", reject);
        resolve();
      });
    });
    socket.on("error", (error) => this.log(`mdns: ${error.message}`));
    socket.on("message", (message, remote) => this.handleMessage(message, remote.address, remote.port));
    this.announce();
    this.announceTimer = setInterval(() => this.announce(), 60_000);
    this.announceTimer.unref?.();
    this.log(`mdns: advertising ${this.config.name} on ${GOOGLECAST_SERVICE} port ${this.config.port}`);
  }

  async stop(): Promise<void> {
    if (this.announceTimer) clearInterval(this.announceTimer);
    this.announceTimer = null;
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    await new Promise<void>((resolve) => socket.close(() => resolve()));
  }

  /** Unsolicited response (announcement) for every service. */
  announce(): void {
    const socket = this.socket;
    if (!socket) return;
    const answers = this.services.flatMap((config) => serviceRecords(config));
    socket.send(encodePacket({ id: 0, response: true, answers }), MDNS_PORT, MDNS_ADDRESS, (error) => {
      if (error) this.log(`mdns: announce failed: ${error.message}`);
    });
  }

  private handleMessage(message: Uint8Array, fromAddress: string, fromPort: number): void {
    let packet;
    try {
      packet = decodePacket(message);
    } catch (error) {
      this.log(`mdns: bad packet from ${fromAddress}: ${(error as Error).message}`);
      return;
    }
    if (packet.isResponse || packet.questions.length === 0) return;

    const answers: ResourceRecord[] = [];
    for (const question of packet.questions) {
      for (const config of this.services) {
        answers.push(...matchQuestion(config, question.name, question.type));
      }
    }
    if (answers.length === 0) return;

    const unicast = fromPort !== MDNS_PORT || packet.questions.some((question) => question.unicastResponse);
    const payload = encodePacket({
      id: packet.id,
      response: true,
      questions: packet.questions, // mDNS responses echo the question
      answers,
    });
    const socket = this.socket;
    if (!socket) return;
    if (unicast) socket.send(payload, fromPort, fromAddress);
    else socket.send(payload, MDNS_PORT, MDNS_ADDRESS);
    this.log(`mdns: answered ${answers.length} record(s) to ${fromAddress}:${fromPort}`);
  }
}

/** Which of our records answer a question, honouring mDNS name matching. */
export function matchQuestion(config: CastServiceConfig, name: string, type: number): ResourceRecord[] {
  const instance = instanceName(config);
  const normalized = name.replace(/\.$/, "").toLowerCase();
  const records = serviceRecords(config);
  const wanted = (record: ResourceRecord, recordName: string) =>
    normalized === recordName.toLowerCase() && (type === TYPE_ANY || type === record.type);
  return records.filter((record) => {
    if (record.name === GOOGLECAST_SERVICE) return wanted(record, GOOGLECAST_SERVICE) || type === TYPE_ANY;
    if (record.name === instance) return wanted(record, instance);
    if (record.name === config.host) return wanted(record, config.host) || (type === TYPE_ANY && normalized === config.host.toLowerCase());
    return false;
  });
}

// ---------------------------------------------------------------------------
// Browser (discovery)
// ---------------------------------------------------------------------------

export interface BrowserOptions {
  /** Stop browsing after this many milliseconds. */
  timeoutMs?: number;
  log?: (message: string) => void;
}

export class MdnsBrowser {
  private socket: Socket | null = null;
  private timer: NodeJS.Timeout | null = null;
  private pollTimer: NodeJS.Timeout | null = null;
  private readonly found = new Map<string, Partial<CastDevice>>();
  private readonly log: (message: string) => void;
  /** Called whenever a device is (re)discovered. */
  onDevice?: (device: CastDevice) => void;

  constructor(options: BrowserOptions = {}) {
    this.log = options.log ?? (() => {});
  }

  get devices(): CastDevice[] {
    return [...this.found.values()]
      .filter((device): device is CastDevice => Boolean(device.address) && Boolean(device.name))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  async start(timeoutMs = 3000): Promise<CastDevice[]> {
    const socket = createSocket({ type: "udp4", reuseAddr: true });
    this.socket = socket;
    await new Promise<void>((resolve, reject) => {
      socket.once("error", reject);
      socket.bind(MDNS_PORT, () => {
        try {
          socket.addMembership(MDNS_ADDRESS);
        } catch (error) {
          this.log(`mdns browse: membership failed: ${(error as Error).message}`);
        }
        socket.removeListener("error", reject);
        resolve();
      });
    });
    socket.on("error", (error) => this.log(`mdns browse: ${error.message}`));
    socket.on("message", (message) => this.handleMessage(message));

    const query = browseQuery();
    const send = () => this.socket?.send(query, MDNS_PORT, MDNS_ADDRESS);
    send();
    this.pollTimer = setInterval(send, 1000);
    this.pollTimer.unref?.();

    await new Promise<void>((resolve) => {
      this.timer = setTimeout(resolve, timeoutMs);
      this.timer.unref?.();
    });
    await this.stop();
    return this.devices;
  }

  async stop(): Promise<void> {
    if (this.pollTimer) clearInterval(this.pollTimer);
    if (this.timer) clearTimeout(this.timer);
    this.pollTimer = null;
    this.timer = null;
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    await new Promise<void>((resolve) => socket.close(() => resolve()));
  }

  /** Feed a raw mDNS packet, exposed for tests. */
  handleMessage(message: Uint8Array): void {
    let packet;
    try {
      packet = decodePacket(message);
    } catch (error) {
      this.log(`mdns browse: bad packet: ${(error as Error).message}`);
      return;
    }
    this.ingest(packet.answers);
    this.ingest(packet.additional);
    this.ingest(packet.authority);
  }

  ingest(records: ResourceRecord[]): void {
    for (const record of records) {
      const key = record.name.replace(/\.$/, "").toLowerCase();
      if (record.type === TYPE_PTR && key === GOOGLECAST_SERVICE.toLowerCase() && record.data.kind === "ptr") {
        const target = record.data.target;
        if (!this.found.has(target)) {
          this.found.set(target, { name: target.replace(new RegExp(`\\.?${GOOGLECAST_SERVICE}$`, "i"), "").replace(/\\\./g, "."), source: "mdns" });
        }
        continue;
      }
      if (record.type === TYPE_SRV && record.data.kind === "srv" && record.name.toLowerCase().endsWith(GOOGLECAST_SERVICE)) {
        const entry = this.found.get(record.name) ?? {};
        entry.port = record.data.port;
        entry.host = record.data.target;
        this.found.set(record.name, entry);
        this.publish(record.name);
        continue;
      }
      if (record.type === TYPE_TXT && record.data.kind === "txt" && record.name.toLowerCase().endsWith(GOOGLECAST_SERVICE)) {
        const entry = this.found.get(record.name) ?? {};
        const txt = txtEntriesToObject(record.data.entries);
        entry.txt = txt;
        entry.name = txt.fn || entry.name || record.name.replace(new RegExp(`\\.?${GOOGLECAST_SERVICE}$`, "i"), "");
        entry.model = txt.md ?? "Cast device";
        entry.id = txt.id ?? entry.id ?? record.name;
        this.found.set(record.name, entry);
        this.publish(record.name);
        continue;
      }
      if ((record.type === TYPE_A || record.type === 28) && (record.data.kind === "a" || record.data.kind === "aaaa")) {
        const address = record.data.address;
        for (const [name, entry] of this.found) {
          if (entry.host && entry.host.toLowerCase() === record.name.toLowerCase()) {
            entry.address = address;
            this.found.set(name, entry);
            this.publish(name);
          }
        }
      }
    }
  }

  private publish(name: string): void {
    const entry = this.found.get(name);
    if (!entry || !entry.address || !entry.port || !entry.name) return;
    const device: CastDevice = {
      id: entry.id ?? entry.name,
      name: entry.name,
      model: entry.model ?? "Cast device",
      address: entry.address,
      port: entry.port,
      host: entry.host ?? "",
      txt: entry.txt ?? {},
      source: "mdns",
    };
    this.found.set(name, device);
    this.onDevice?.(device);
  }
}

/** Convenience: browse for `timeoutMs` and return what answered. */
export async function discoverDevices(options: BrowserOptions & { timeoutMs?: number } = {}): Promise<CastDevice[]> {
  const browser = new MdnsBrowser(options);
  return browser.start(options.timeoutMs ?? 3000);
}

/** The IPv4 address of the interface that routes to the outside world. */
export function primaryAddress(): string {
  const interfaces = networkInterfaces();
  for (const entries of Object.values(interfaces)) {
    for (const entry of entries ?? []) {
      if (!entry.internal && entry.family === "IPv4" && !entry.address.startsWith("169.254.")) return entry.address;
    }
  }
  return "127.0.0.1";
}

export function hostName(): string {
  const hostname = process.env["HOSTNAME"] ?? process.env["COMPUTERNAME"] ?? "karu";
  return `${hostname.split(".")[0]!.toLowerCase()}.local`;
}
