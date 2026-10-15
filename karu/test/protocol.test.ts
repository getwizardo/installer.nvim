import { test } from "node:test";
import assert from "node:assert/strict";
import { Reader, Writer, decodeFields } from "../src/protocol/protobuf.ts";
import {
  PAYLOAD_BINARY,
  PAYLOAD_STRING,
  decodeCastMessage,
  encodeCastMessage,
  frameCastMessage,
  createFrameParser,
  jsonPayload,
} from "../src/protocol/castMessage.ts";

test("protobuf: varints round-trip across boundaries", () => {
  for (const value of [0, 1, 127, 128, 300, 16383, 16384, 2 ** 31 - 1]) {
    const writer = new Writer();
    writer.varint(value);
    const buf = writer.bytes();
    assert.equal(new Reader(buf).varint(), value, `varint ${value}`);
  }
});

test("protobuf: strings, bytes and nested messages", () => {
  const writer = new Writer();
  writer.string(1, "héllo · 世界");
  writer.bytesField(2, Uint8Array.from([1, 2, 3]));
  writer.uint(3, 42);
  writer.message(4, Uint8Array.from([0x08, 0x01]));
  const fields = decodeFields(writer.bytes());
  assert.equal(fields.length, 4);
  assert.equal(new TextDecoder().decode(fields[0]!.data!), "héllo · 世界");
  assert.deepEqual([...fields[1]!.data!], [1, 2, 3]);
  assert.equal(fields[2]!.int, 42);
  assert.deepEqual([...fields[3]!.data!], [0x08, 0x01]);
});

test("protobuf: undefined fields are omitted (proto3 default behaviour)", () => {
  const writer = new Writer();
  writer.string(1, undefined);
  writer.uint(2, null);
  writer.string(3, "");
  assert.equal(writer.length(), 2, "only the empty string field is written");
});

test("CastMessage: encode/decode round-trip", () => {
  const encoded = encodeCastMessage({
    sourceId: "sender-0",
    destinationId: "receiver-0",
    namespace: "urn:x-cast:com.google.cast.receiver",
    payloadType: PAYLOAD_STRING,
    payloadUtf8: JSON.stringify({ type: "GET_STATUS", requestId: 7 }),
  });
  const decoded = decodeCastMessage(encoded);
  assert.equal(decoded.protocolVersion, 0, "CASTV2_1_0");
  assert.equal(decoded.sourceId, "sender-0");
  assert.equal(decoded.destinationId, "receiver-0");
  assert.equal(decoded.namespace, "urn:x-cast:com.google.cast.receiver");
  assert.equal(decoded.payloadType, PAYLOAD_STRING);
  assert.deepEqual(jsonPayload(decoded), { type: "GET_STATUS", requestId: 7 });
});

test("CastMessage: binary payloads and unknown fields survive", () => {
  const encoded = encodeCastMessage({
    sourceId: "a",
    destinationId: "b",
    namespace: "urn:x-cast:com.google.cast.tp.deviceauth",
    payloadType: PAYLOAD_BINARY,
    payloadBinary: Uint8Array.from([9, 8, 7]),
  });
  const decoded = decodeCastMessage(encoded);
  assert.equal(decoded.payloadType, PAYLOAD_BINARY);
  assert.deepEqual([...decoded.payloadBinary!], [9, 8, 7]);
  assert.equal(jsonPayload(decoded), null, "binary payload is not JSON");

  // A future protocol version may add fields we do not know; they must be skipped.
  const writer = new Writer();
  writer.uint(1, 0);
  writer.string(2, "s");
  writer.string(3, "d");
  writer.string(4, "ns");
  writer.uint(5, 0);
  writer.string(6, "{}");
  writer.uint(9, 1234); // unknown varint
  writer.string(10, "extra"); // unknown bytes
  const decoded2 = decodeCastMessage(writer.bytes());
  assert.equal(decoded2.sourceId, "s");
  assert.deepEqual(jsonPayload(decoded2), {});
});

test("framing: length prefix + incremental parser across chunk boundaries", () => {
  const first = frameCastMessage({ sourceId: "s1", destinationId: "receiver-0", namespace: "ns", payloadType: PAYLOAD_STRING, payloadUtf8: '{"type":"PING"}' });
  const second = frameCastMessage({ sourceId: "s1", destinationId: "receiver-0", namespace: "ns", payloadType: PAYLOAD_STRING, payloadUtf8: '{"type":"PONG"}' });

  // The 4-byte header is the big-endian length of the protobuf body.
  const declared = new DataView(first.buffer, first.byteOffset, 4).getUint32(0, false);
  assert.equal(declared, first.length - 4);
  assert.ok(declared > 15, "the body is the encoded CastMessage, not just the JSON");

  const parser = createFrameParser();
  assert.deepEqual(parser.push(first.subarray(0, 3)), [], "incomplete header");
  assert.equal(parser.pending(), 3);
  assert.deepEqual(parser.push(first.subarray(3, 9)), [], "partial body");
  const messages = parser.push(Uint8Array.from([...first.subarray(9), ...second]));
  assert.equal(messages.length, 2);
  assert.deepEqual(jsonPayload(messages[0]!), { type: "PING" });
  assert.deepEqual(jsonPayload(messages[1]!), { type: "PONG" });
  assert.equal(parser.pending(), 0);
});

test("framing: an oversized frame is rejected instead of buffered", () => {
  const parser = createFrameParser(16);
  const header = new Uint8Array(4);
  new DataView(header.buffer).setUint32(0, 64, false);
  assert.throws(() => parser.push(header), /frame too large/);
});
