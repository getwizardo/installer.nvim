/**
 * DNS packet codec (the subset mDNS needs), pure, no sockets, so it is fully
 * unit-testable. Handles name compression pointers in both the question and
 * the RDATA sections, which real Cast devices do use.
 */
import { Reader, Writer, decodeString } from "../protocol/protobuf.ts";

export const TYPE_A = 1;
export const TYPE_PTR = 12;
export const TYPE_TXT = 16;
export const TYPE_AAAA = 28;
export const TYPE_SRV = 33;
export const TYPE_ANY = 255;

export const CLASS_IN = 1;
/** Cache-flush bit in responses / unicast-response bit in questions. */
export const CLASS_TOP_BIT = 0x8000;

/** mDNS response flags: QR=1, AA=1. */
export const FLAG_RESPONSE = 0x8400;

export interface Question {
  name: string;
  type: number;
  klass: number;
  unicastResponse: boolean;
}

export type RData =
  | { kind: "ptr"; target: string }
  | { kind: "srv"; priority: number; weight: number; port: number; target: string }
  | { kind: "txt"; entries: string[] }
  | { kind: "a"; address: string }
  | { kind: "aaaa"; address: string }
  | { kind: "raw"; bytes: Uint8Array };

export interface ResourceRecord {
  name: string;
  type: number;
  klass: number;
  ttl: number;
  flush: boolean;
  data: RData;
}

export interface DnsPacket {
  id: number;
  flags: number;
  isResponse: boolean;
  questions: Question[];
  answers: ResourceRecord[];
  authority: ResourceRecord[];
  additional: ResourceRecord[];
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

/** Encode a dotted name into DNS label form (no compression). */
export function encodeName(name: string): Uint8Array {
  const w = new Writer();
  for (const label of splitName(name)) {
    const bytes = new TextEncoder().encode(label);
    if (bytes.length === 0 || bytes.length > 63) continue;
    w.raw(bytes.length).rawBytes(bytes);
  }
  w.raw(0);
  return w.bytes();
}

/**
 * Split a dotted name into labels, honouring `\.` escapes (needed for service
 * instance names that contain dots, e.g. "Karu · Neovim" is fine but
 * "Karu.v1" must be escaped by whoever builds it).
 */
export function splitName(name: string): string[] {
  const labels: string[] = [];
  let current = "";
  for (let i = 0; i < name.length; i++) {
    const ch = name[i]!;
    if (ch === "\\" && i + 1 < name.length) {
      current += name[++i]!;
      continue;
    }
    if (ch === ".") {
      labels.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  if (current !== "" || labels.length === 0) labels.push(current);
  return labels.filter((label) => label !== "");
}

/** Read a (possibly compressed) name at `offset`; returns the name and the offset after it. */
export function readName(buf: Uint8Array, offset: number): { name: string; next: number } {
  const labels: string[] = [];
  let pos = offset;
  let next = offset;
  let jumped = false;
  const guard = new Set<number>();

  for (;;) {
    if (pos >= buf.length) break;
    const len = buf[pos]!;
    if ((len & 0xc0) === 0xc0) {
      if (pos + 1 >= buf.length) break;
      const pointer = ((len & 0x3f) << 8) | buf[pos + 1]!;
      if (!jumped) next = pos + 2;
      jumped = true;
      if (guard.has(pointer)) break; // compression loop
      guard.add(pointer);
      pos = pointer;
      continue;
    }
    if (len === 0) {
      pos += 1;
      if (!jumped) next = pos;
      break;
    }
    const start = pos + 1;
    const end = start + len;
    if (end > buf.length) break;
    labels.push(decodeString(buf.subarray(start, end)));
    pos = end;
    if (!jumped) next = pos;
  }

  return { name: labels.join("."), next };
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

function encodeRData(data: RData): Uint8Array {
  switch (data.kind) {
    case "ptr":
      return encodeName(data.target);
    case "srv": {
      const w = new Writer();
      w.raw((data.priority >> 8) & 0xff).raw(data.priority & 0xff);
      w.raw((data.weight >> 8) & 0xff).raw(data.weight & 0xff);
      w.raw((data.port >> 8) & 0xff).raw(data.port & 0xff);
      return concat(w.bytes(), encodeName(data.target));
    }
    case "txt": {
      const w = new Writer();
      for (const entry of data.entries) {
        const bytes = new TextEncoder().encode(entry);
        const chunk = bytes.length > 255 ? bytes.subarray(0, 255) : bytes;
        w.raw(chunk.length).rawBytes(chunk);
      }
      return w.bytes();
    }
    case "a":
      return Uint8Array.from(data.address.split(".").map((part) => Number(part) & 0xff));
    case "aaaa": {
      const groups = expandIpv6(data.address);
      const out = new Uint8Array(16);
      groups.forEach((group, index) => {
        out[index * 2] = (group >> 8) & 0xff;
        out[index * 2 + 1] = group & 0xff;
      });
      return out;
    }
    case "raw":
      return data.bytes;
  }
}

export function encodeRecord(record: ResourceRecord): Uint8Array {
  const rdata = encodeRData(record.data);
  const w = new Writer();
  w.rawBytes(encodeName(record.name));
  w.raw((record.type >> 8) & 0xff).raw(record.type & 0xff);
  const klass = (record.klass & 0x7fff) | (record.flush ? CLASS_TOP_BIT : 0);
  w.raw((klass >> 8) & 0xff).raw(klass & 0xff);
  w.raw((record.ttl >>> 24) & 0xff).raw((record.ttl >>> 16) & 0xff).raw((record.ttl >>> 8) & 0xff).raw(record.ttl & 0xff);
  w.raw((rdata.length >> 8) & 0xff).raw(rdata.length & 0xff);
  return concat(w.bytes(), rdata);
}

function encodeQuestion(question: Question): Uint8Array {
  const w = new Writer();
  w.rawBytes(encodeName(question.name));
  w.raw((question.type >> 8) & 0xff).raw(question.type & 0xff);
  const klass = (question.klass & 0x7fff) | (question.unicastResponse ? CLASS_TOP_BIT : 0);
  w.raw((klass >> 8) & 0xff).raw(klass & 0xff);
  return w.bytes();
}

export interface PacketParts {
  id: number;
  response: boolean;
  authoritative?: boolean;
  questions?: Question[];
  answers?: ResourceRecord[];
  authority?: ResourceRecord[];
  additional?: ResourceRecord[];
}

export function encodePacket(parts: PacketParts): Uint8Array {
  let flags = parts.response ? FLAG_RESPONSE : 0;
  if (parts.authoritative === false) flags &= ~0x0400;
  const answers = parts.answers ?? [];
  const authority = parts.authority ?? [];
  const additional = parts.additional ?? [];
  const questions = parts.questions ?? [];

  const header = new Uint8Array(12);
  const view = new DataView(header.buffer);
  view.setUint16(0, parts.id & 0xffff, false);
  view.setUint16(2, flags & 0xffff, false);
  view.setUint16(4, questions.length, false);
  view.setUint16(6, answers.length, false);
  view.setUint16(8, authority.length, false);
  view.setUint16(10, additional.length, false);

  const chunks: Uint8Array[] = [header];
  for (const question of questions) chunks.push(encodeQuestion(question));
  for (const record of answers) chunks.push(encodeRecord(record));
  for (const record of authority) chunks.push(encodeRecord(record));
  for (const record of additional) chunks.push(encodeRecord(record));
  return concat(...chunks);
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

export function decodePacket(buf: Uint8Array): DnsPacket {
  const view = new DataView(buf.buffer, buf.byteOffset, Math.min(buf.length, 12));
  const id = buf.length >= 2 ? view.getUint16(0, false) : 0;
  const flags = buf.length >= 4 ? view.getUint16(2, false) : 0;
  const counts = buf.length >= 12 ? [view.getUint16(4, false), view.getUint16(6, false), view.getUint16(8, false), view.getUint16(10, false)] : [0, 0, 0, 0];

  const reader = new Reader(buf);
  reader.take(Math.min(12, buf.length));

  const questions: Question[] = [];
  for (let i = 0; i < (counts[0] ?? 0); i++) {
    const { name, next } = readName(buf, reader.offset);
    const klass = buf[next + 2] !== undefined && buf[next + 3] !== undefined ? (buf[next + 2]! << 8) | buf[next + 3]! : 0;
    const type = buf[next] !== undefined && buf[next + 1] !== undefined ? (buf[next]! << 8) | buf[next + 1]! : 0;
    reader.take(next + 4 - reader.offset);
    questions.push({
      name,
      type,
      klass: klass & 0x7fff,
      unicastResponse: (klass & CLASS_TOP_BIT) !== 0,
    });
  }

  const readRecords = (count: number): ResourceRecord[] => {
    const records: ResourceRecord[] = [];
    for (let i = 0; i < count; i++) {
      if (reader.eof()) break;
      const { name, next } = readName(buf, reader.offset);
      reader.take(next - reader.offset);
      const type = ((buf[reader.offset]! << 8) | buf[reader.offset + 1]!) >>> 0;
      const klassRaw = ((buf[reader.offset + 2]! << 8) | buf[reader.offset + 3]!) >>> 0;
      const ttl =
        ((buf[reader.offset + 4]! << 24) | (buf[reader.offset + 5]! << 16) | (buf[reader.offset + 6]! << 8) | buf[reader.offset + 7]!) >>> 0;
      const rdlength = ((buf[reader.offset + 8]! << 8) | buf[reader.offset + 9]!) >>> 0;
      reader.take(10);
      const rdataStart = reader.offset;
      const rdata = buf.subarray(rdataStart, rdataStart + rdlength);
      reader.take(rdlength);

      records.push({
        name,
        type,
        klass: klassRaw & 0x7fff,
        ttl,
        flush: (klassRaw & CLASS_TOP_BIT) !== 0,
        data: decodeRData(buf, type, rdata, rdataStart),
      });
    }
    return records;
  };

  return {
    id,
    flags,
    isResponse: (flags & 0x8000) !== 0,
    questions,
    answers: readRecords(counts[1] ?? 0),
    authority: readRecords(counts[2] ?? 0),
    additional: readRecords(counts[3] ?? 0),
  };
}

function decodeRData(packet: Uint8Array, type: number, rdata: Uint8Array, rdataStart: number): RData {
  switch (type) {
    case TYPE_PTR: {
      const { name } = readName(packet, rdataStart);
      return { kind: "ptr", target: name } as RData;
    }
    case TYPE_SRV: {
      const priority = (rdata[0]! << 8) | rdata[1]!;
      const weight = (rdata[2]! << 8) | rdata[3]!;
      const port = (rdata[4]! << 8) | rdata[5]!;
      const { name } = readName(packet, rdataStart + 6);
      return { kind: "srv", priority, weight, port, target: name };
    }
    case TYPE_TXT: {
      const entries: string[] = [];
      let offset = 0;
      while (offset < rdata.length) {
        const len = rdata[offset]!;
        entries.push(decodeString(rdata.subarray(offset + 1, offset + 1 + len)));
        offset += 1 + len;
      }
      return { kind: "txt", entries };
    }
    case TYPE_A:
      return { kind: "a", address: `${rdata[0]}.${rdata[1]}.${rdata[2]}.${rdata[3]}` };
    case TYPE_AAAA: {
      const groups: string[] = [];
      for (let i = 0; i < 16; i += 2) groups.push((((rdata[i] ?? 0) << 8) | (rdata[i + 1] ?? 0)).toString(16));
      return { kind: "aaaa", address: groups.join(":") };
    }
    default:
      return { kind: "raw", bytes: rdata.slice() };
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

export function concat(...chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

export function txtEntriesToObject(entries: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const entry of entries) {
    const index = entry.indexOf("=");
    if (index <= 0) out[entry] = "";
    else out[entry.slice(0, index)] = entry.slice(index + 1);
  }
  return out;
}

function expandIpv6(address: string): number[] {
  const [head, tail] = address.split("::");
  const left = head ? head.split(":").filter(Boolean) : [];
  const right = tail ? tail.split(":").filter(Boolean) : [];
  const missing = 8 - left.length - right.length;
  const groups = [...left, ...Array.from({ length: Math.max(0, missing) }, () => "0"), ...right];
  return groups.slice(0, 8).map((group) => parseInt(group || "0", 16) & 0xffff);
}
