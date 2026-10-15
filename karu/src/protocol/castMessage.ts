/**
 * CASTV2 message layer: the `CastMessage` protobuf, the 4-byte length framing,
 * and the namespace constants.
 *
 * Schema (cast_channel.proto, the fields that matter):
 *   message CastMessage {
 *     enum ProtocolVersion { CASTV2_1_0 = 0; }
 *     enum PayloadType     { STRING = 0; BINARY = 1; }
 *     required ProtocolVersion protocol_version = 1;
 *     required string source_id                 = 2;
 *     required string destination_id            = 3;
 *     required string namespace                 = 4;
 *     required PayloadType payload_type         = 5;
 *     optional string payload_utf8              = 6;
 *     optional bytes  payload_binary            = 7;
 *   }
 */
import { Reader, Writer, decodeString } from "./protobuf.ts";

export const CASTV2_1_0 = 0;
export const PAYLOAD_STRING = 0;
export const PAYLOAD_BINARY = 1;

export const NS_CONNECTION = "urn:x-cast:com.google.cast.tp.connection";
export const NS_HEARTBEAT = "urn:x-cast:com.google.cast.tp.heartbeat";
export const NS_RECEIVER = "urn:x-cast:com.google.cast.receiver";
export const NS_DEVICE_AUTH = "urn:x-cast:com.google.cast.tp.deviceauth";
export const NS_MEDIA = "urn:x-cast:com.google.cast.media";
export const NS_SETUP = "urn:x-cast:com.google.cast.tp.setup";

/** The Google "Default Media Receiver" app id — every sender knows it. */
export const APP_DEFAULT_MEDIA_RECEIVER = "CC1AD845";

export interface CastMessage {
  sourceId: string;
  destinationId: string;
  namespace: string;
  payloadType: number;
  payloadUtf8?: string;
  payloadBinary?: Uint8Array;
  protocolVersion?: number;
}

export function encodeCastMessage(msg: CastMessage): Uint8Array {
  const w = new Writer();
  w.uint(1, msg.protocolVersion ?? CASTV2_1_0);
  w.string(2, msg.sourceId);
  w.string(3, msg.destinationId);
  w.string(4, msg.namespace);
  w.uint(5, msg.payloadType);
  if (msg.payloadUtf8 !== undefined) w.string(6, msg.payloadUtf8);
  if (msg.payloadBinary !== undefined) w.bytesField(7, msg.payloadBinary);
  return w.bytes();
}

export function decodeCastMessage(buf: Uint8Array): CastMessage {
  const reader = new Reader(buf);
  const msg: CastMessage = {
    sourceId: "",
    destinationId: "",
    namespace: "",
    payloadType: PAYLOAD_STRING,
  };
  for (;;) {
    const field = reader.next();
    if (!field) break;
    switch (field.field) {
      case 1:
        msg.protocolVersion = field.int ?? 0;
        break;
      case 2:
        msg.sourceId = decodeString(field.data!);
        break;
      case 3:
        msg.destinationId = decodeString(field.data!);
        break;
      case 4:
        msg.namespace = decodeString(field.data!);
        break;
      case 5:
        msg.payloadType = field.int ?? 0;
        break;
      case 6:
        msg.payloadUtf8 = decodeString(field.data!);
        break;
      case 7:
        msg.payloadBinary = field.data!.slice();
        break;
      default:
        // Unknown field — `Reader.next()` already consumed it.
        break;
    }
  }
  return msg;
}

/** Length-prefixed frame: `uint32be length || CastMessage`. */
export function frameCastMessage(msg: CastMessage): Uint8Array {
  const body = encodeCastMessage(msg);
  const frame = new Uint8Array(body.length + 4);
  new DataView(frame.buffer).setUint32(0, body.length, false);
  frame.set(body, 4);
  return frame;
}

export interface FrameParser {
  /** Feed bytes in; returns every complete CastMessage found so far. */
  push(chunk: Uint8Array): CastMessage[];
  /** Bytes buffered but not yet a complete frame. */
  pending(): number;
}

/**
 * Incremental frame parser — TCP gives no message boundaries, so we buffer
 * until a whole frame is available. Frames larger than `maxFrame` (1 MiB, the
 * sanity limit real receivers use) are rejected instead of buffered forever.
 */
export function createFrameParser(maxFrame = 1 << 20): FrameParser {
  let buffer = new Uint8Array(0);
  return {
    push(chunk: Uint8Array): CastMessage[] {
      const merged = new Uint8Array(buffer.length + chunk.length);
      merged.set(buffer, 0);
      merged.set(chunk, buffer.length);
      buffer = merged;

      const out: CastMessage[] = [];
      for (;;) {
        if (buffer.length < 4) break;
        const length = new DataView(buffer.buffer, buffer.byteOffset, 4).getUint32(0, false);
        if (length > maxFrame) {
          throw new Error(`castv2: frame too large (${length} bytes)`);
        }
        if (buffer.length < 4 + length) break;
        const body = buffer.subarray(4, 4 + length);
        out.push(decodeCastMessage(body));
        buffer = buffer.subarray(4 + length);
      }
      // Copy so the retained buffer is not a view into a large chunk.
      buffer = buffer.slice();
      return out;
    },
    pending(): number {
      return buffer.length;
    },
  };
}

/** JSON payload helpers — every non-binary Cast message body is JSON. */
export function jsonPayload(msg: CastMessage): Record<string, unknown> | null {
  if (msg.payloadType !== PAYLOAD_STRING || !msg.payloadUtf8) return null;
  try {
    const parsed = JSON.parse(msg.payloadUtf8);
    return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}
