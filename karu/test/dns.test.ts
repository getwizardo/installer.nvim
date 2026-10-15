import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CLASS_IN,
  TYPE_A,
  TYPE_ANY,
  TYPE_PTR,
  TYPE_SRV,
  TYPE_TXT,
  decodePacket,
  encodePacket,
  encodeName,
  readName,
  splitName,
  txtEntriesToObject,
  type ResourceRecord,
} from "../src/net/dns.ts";

test("names: labels, escaping and compression pointers", () => {
  const encoded = encodeName("_googlecast._tcp.local");
  assert.deepEqual([...encoded], [11, 95, 103, 111, 111, 103, 108, 101, 99, 97, 115, 116, 4, 95, 116, 99, 112, 5, 108, 111, 99, 97, 108, 0]);
  assert.deepEqual(readName(encoded, 0), { name: "_googlecast._tcp.local", next: encoded.length });

  // Escaped dots survive as part of one label.
  assert.deepEqual(splitName("Karu\\.neovim._googlecast._tcp.local"), ["Karu.neovim", "_googlecast", "_tcp", "local"]);

  // A compression pointer back to offset 0 (0xC000) resolves to the same name.
  const packet = Uint8Array.from([...encodeName("a.local"), 0xc0, 0x00]);
  assert.deepEqual(readName(packet, packet.length - 2), { name: "a.local", next: packet.length });
  // …and a pointer loop does not hang.
  const loop = Uint8Array.from([1, 97, 0, 0xc0, 0x00]);
  assert.equal(readName(loop, 3).name, "a");
});

test("packets: query and response round-trip", () => {
  const query = encodePacket({
    id: 0,
    response: false,
    questions: [{ name: "_googlecast._tcp.local", type: TYPE_PTR, klass: CLASS_IN, unicastResponse: false }],
  });
  const decodedQuery = decodePacket(query);
  assert.equal(decodedQuery.isResponse, false);
  assert.equal(decodedQuery.questions.length, 1);
  assert.equal(decodedQuery.questions[0]!.name, "_googlecast._tcp.local");
  assert.equal(decodedQuery.questions[0]!.type, TYPE_PTR);
  assert.equal(decodedQuery.questions[0]!.unicastResponse, false);

  const answers: ResourceRecord[] = [
    { name: "_googlecast._tcp.local", type: TYPE_PTR, klass: CLASS_IN, ttl: 4500, flush: false, data: { kind: "ptr", target: "Karu._googlecast._tcp.local" } },
    { name: "Karu._googlecast._tcp.local", type: TYPE_SRV, klass: CLASS_IN, ttl: 4500, flush: true, data: { kind: "srv", priority: 0, weight: 0, port: 8009, target: "karu.local" } },
    { name: "Karu._googlecast._tcp.local", type: TYPE_TXT, klass: CLASS_IN, ttl: 4500, flush: true, data: { kind: "txt", entries: ["id=abc123", "fn=Karu · Neovim", "md=Karu"] } },
    { name: "karu.local", type: TYPE_A, klass: CLASS_IN, ttl: 120, flush: true, data: { kind: "a", address: "192.168.1.24" } },
  ];
  const response = encodePacket({ id: 0, response: true, answers });
  assert.equal(response[2]! & 0x80, 0x80, "QR bit set");
  const decoded = decodePacket(response);
  assert.equal(decoded.isResponse, true);
  assert.equal(decoded.answers.length, 4);
  assert.deepEqual(decoded.answers[0]!.data, { kind: "ptr", target: "Karu._googlecast._tcp.local" });
  assert.deepEqual(decoded.answers[1]!.data, { kind: "srv", priority: 0, weight: 0, port: 8009, target: "karu.local" });
  assert.deepEqual(decoded.answers[2]!.data, { kind: "txt", entries: ["id=abc123", "fn=Karu · Neovim", "md=Karu"] });
  assert.deepEqual(decoded.answers[3]!.data, { kind: "a", address: "192.168.1.24" });
  assert.equal(decoded.answers[1]!.flush, true, "cache-flush bit preserved");
  assert.equal(decoded.answers[0]!.flush, false, "PTR stays shared");
  assert.equal(txtEntriesToObject(["id=abc123", "fn=Karu"]).id, "abc123");
  assert.equal(txtEntriesToObject(["flag"]).flag, "");
  assert.equal(TYPE_ANY, 255);
});
