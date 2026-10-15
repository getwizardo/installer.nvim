/**
 * Minimal protobuf wire-format codec (proto3 subset), no dependencies.
 *
 * Google Cast frames are a single `CastMessage` protobuf preceded by a 4-byte
 * big-endian length. We only need: varint, length-delimited (string/bytes and
 * nested messages), fixed32/64 (decoded and skipped so unknown fields do not
 * break parsing) and the ability to skip anything we do not understand.
 *
 * Wire types: 0 = varint, 1 = 64-bit, 2 = length-delimited, 5 = 32-bit.
 */

export const WIRE_VARINT = 0;
export const WIRE_FIXED64 = 1;
export const WIRE_BYTES = 2;
export const WIRE_FIXED32 = 5;

export class Writer {
  private readonly chunks: number[] = [];

  bytes(): Uint8Array {
    return Uint8Array.from(this.chunks);
  }

  length(): number {
    return this.chunks.length;
  }

  /** Raw byte, no tag. */
  raw(byte: number): this {
    this.chunks.push(byte & 0xff);
    return this;
  }

  rawBytes(data: Uint8Array | number[]): this {
    for (const b of data) this.chunks.push(b & 0xff);
    return this;
  }

  varint(value: number | bigint): this {
    let v = typeof value === "bigint" ? value : BigInt(Math.trunc(value));
    if (v < 0n) v = BigInt.asUintN(64, v);
    for (;;) {
      const byte = Number(v & 0x7fn);
      v >>= 7n;
      if (v === 0n) {
        this.chunks.push(byte);
        return this;
      }
      this.chunks.push(byte | 0x80);
    }
  }

  tag(field: number, wire: number): this {
    return this.varint((field << 3) | wire);
  }

  /** field = varint (skipped entirely when `undefined`). */
  uint(field: number, value: number | undefined | null): this {
    if (value === undefined || value === null) return this;
    this.tag(field, WIRE_VARINT);
    return this.varint(value);
  }

  /** field = length-delimited string (UTF-8, like protobuf `string`). */
  string(field: number, value: string | undefined | null): this {
    if (value === undefined || value === null) return this;
    const data = new TextEncoder().encode(value);
    this.tag(field, WIRE_BYTES);
    this.varint(data.length);
    return this.rawBytes(data);
  }

  /** field = length-delimited bytes. */
  bytesField(field: number, value: Uint8Array | undefined | null): this {
    if (value === undefined || value === null) return this;
    this.tag(field, WIRE_BYTES);
    this.varint(value.length);
    return this.rawBytes(value);
  }

  /** field = embedded message. */
  message(field: number, value: Uint8Array | undefined | null): this {
    return this.bytesField(field, value);
  }
}

export interface Field {
  field: number;
  wire: number;
  /** varint value when wire === 0 */
  int?: number;
  /** raw payload when wire === 2 */
  data?: Uint8Array;
}

export class Reader {
  private pos = 0;
  private readonly buf: Uint8Array;

  constructor(buf: Uint8Array) {
    this.buf = buf;
  }

  eof(): boolean {
    return this.pos >= this.buf.length;
  }

  get offset(): number {
    return this.pos;
  }

  varint(): number {
    let result = 0n;
    let shift = 0n;
    for (;;) {
      if (this.pos >= this.buf.length) throw new Error("protobuf: truncated varint");
      const byte = this.buf[this.pos++]!;
      result |= BigInt(byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) break;
      shift += 7n;
      if (shift > 63n) throw new Error("protobuf: varint overflow");
    }
    return Number(BigInt.asIntN(64, result));
  }

  take(n: number): Uint8Array {
    if (this.pos + n > this.buf.length) throw new Error("protobuf: truncated field");
    const out = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }

  /** Read the next field, or null at end of buffer. */
  next(): Field | null {
    if (this.eof()) return null;
    const key = this.varint();
    const field = key >>> 3;
    const wire = key & 0x7;
    switch (wire) {
      case WIRE_VARINT:
        return { field, wire, int: this.varint() };
      case WIRE_BYTES: {
        const len = this.varint();
        if (len < 0) throw new Error("protobuf: negative length");
        return { field, wire, data: this.take(len) };
      }
      case WIRE_FIXED64:
        this.take(8);
        return { field, wire };
      case WIRE_FIXED32:
        this.take(4);
        return { field, wire };
      default:
        throw new Error(`protobuf: unsupported wire type ${wire}`);
    }
  }
}

/** Decode a whole buffer into fields, tolerating (and skipping) unknown ones. */
export function decodeFields(buf: Uint8Array): Field[] {
  const reader = new Reader(buf);
  const fields: Field[] = [];
  for (;;) {
    const field = reader.next();
    if (!field) break;
    fields.push(field);
  }
  return fields;
}

export function decodeString(data: Uint8Array): string {
  return new TextDecoder().decode(data);
}

/** Build a nested message (helper for tests and small payloads). */
export function encodeMessage(build: (w: Writer) => void): Uint8Array {
  const w = new Writer();
  build(w);
  return w.bytes();
}
