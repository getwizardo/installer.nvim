import { test } from "node:test";
import assert from "node:assert/strict";
import {
  GOOGLECAST_SERVICE,
  MdnsBrowser,
  browseQuery,
  deviceIdFrom,
  escapeLabel,
  instanceName,
  matchQuestion,
  serviceRecords,
  serviceTxt,
  type CastServiceConfig,
} from "../src/net/mdns.ts";
import { TYPE_A, TYPE_ANY, TYPE_PTR, TYPE_SRV, TYPE_TXT, decodePacket, encodePacket } from "../src/net/dns.ts";

const config: CastServiceConfig = { name: "Karu · Neovim", host: "karu-nvim.local", address: "192.168.1.24", port: 8009 };

test("mdns: TXT record carries the keys senders need", () => {
  const entries = serviceTxt(config);
  const txt = Object.fromEntries(entries.map((entry) => [entry.slice(0, entry.indexOf("=")), entry.slice(entry.indexOf("=") + 1)]));
  assert.equal(txt.fn, "Karu · Neovim");
  assert.equal(txt.md, "Karu");
  assert.match(txt.id!, /^[0-9a-f]{12}$/);
  assert.equal(txt.ve, "05");
  assert.ok("ca" in txt && "st" in txt && "ic" in txt, "Cast senders read ca/st/ic");
  assert.equal(deviceIdFrom("karu-nvim.local"), deviceIdFrom("karu-nvim.local"), "device id is stable");
  assert.notEqual(deviceIdFrom("a"), deviceIdFrom("b"));
});

test("mdns: service records — PTR shared, SRV/TXT/A cache-flushed with port 8009", () => {
  const records = serviceRecords(config);
  assert.equal(records.length, 4);
  const [ptr, srv, txt, a] = records;
  assert.equal(ptr!.name, GOOGLECAST_SERVICE);
  assert.equal(ptr!.type, TYPE_PTR);
  assert.equal(ptr!.flush, false);
  assert.deepEqual(ptr!.data, { kind: "ptr", target: instanceName(config) });
  assert.equal(srv!.type, TYPE_SRV);
  assert.equal(srv!.flush, true);
  assert.deepEqual(srv!.data, { kind: "srv", priority: 0, weight: 0, port: 8009, target: "karu-nvim.local" });
  assert.equal(txt!.type, TYPE_TXT);
  assert.equal(a!.type, TYPE_A);
  assert.deepEqual(a!.data, { kind: "a", address: "192.168.1.24" });
  assert.equal(escapeLabel("a.b"), "a\\.b");
});

test("mdns: questions are matched (PTR / SRV / TXT / A / ANY)", () => {
  assert.equal(matchQuestion(config, GOOGLECAST_SERVICE, TYPE_PTR).length, 1);
  assert.equal(matchQuestion(config, instanceName(config), TYPE_SRV).length, 1);
  assert.equal(matchQuestion(config, instanceName(config), TYPE_TXT).length, 1);
  assert.equal(matchQuestion(config, "karu-nvim.local", TYPE_A).length, 1);
  assert.ok(matchQuestion(config, instanceName(config), TYPE_ANY).length >= 2);
  assert.equal(matchQuestion(config, "other._googlecast._tcp.local", TYPE_PTR).length, 0);
});

test("mdns: browse query is a PTR question for _googlecast._tcp.local", () => {
  const decoded = decodePacket(browseQuery());
  assert.equal(decoded.questions[0]!.name, GOOGLECAST_SERVICE);
  assert.equal(decoded.questions[0]!.type, TYPE_PTR);
  assert.equal(decoded.isResponse, false);
});

test("mdns browser: ingest a device response and publish a resolved device", () => {
  const browser = new MdnsBrowser();
  const seen: string[] = [];
  browser.onDevice = (device) => seen.push(`${device.name}@${device.address}:${device.port}`);

  const packet = encodePacket({
    id: 0,
    response: true,
    answers: [
      { name: GOOGLECAST_SERVICE, type: TYPE_PTR, klass: 1, ttl: 4500, flush: false, data: { kind: "ptr", target: "Living Room._googlecast._tcp.local" } },
      { name: "Living Room._googlecast._tcp.local", type: TYPE_SRV, klass: 1, ttl: 4500, flush: true, data: { kind: "srv", priority: 0, weight: 0, port: 8009, target: "chromecast.local" } },
      { name: "Living Room._googlecast._tcp.local", type: TYPE_TXT, klass: 1, ttl: 4500, flush: true, data: { kind: "txt", entries: ["id=c0ffee123456", "fn=Living Room TV", "md=Chromecast Ultra"] } },
    ],
    additional: [{ name: "chromecast.local", type: TYPE_A, klass: 1, ttl: 120, flush: true, data: { kind: "a", address: "192.168.1.50" } }],
  });
  browser.handleMessage(packet);

  assert.deepEqual(seen, ["Living Room TV@192.168.1.50:8009"]);
  const devices = browser.devices;
  assert.equal(devices.length, 1);
  assert.deepEqual(
    { name: devices[0]!.name, id: devices[0]!.id, address: devices[0]!.address, port: devices[0]!.port, model: devices[0]!.model },
    { name: "Living Room TV", id: "c0ffee123456", address: "192.168.1.50", port: 8009, model: "Chromecast Ultra" }
  );
});

test("mdns browser: a device without an address is not published yet", () => {
  const browser = new MdnsBrowser();
  let published = 0;
  browser.onDevice = () => published++;
  browser.ingest([
    { name: GOOGLECAST_SERVICE, type: TYPE_PTR, klass: 1, ttl: 4500, flush: false, data: { kind: "ptr", target: "Kitchen._googlecast._tcp.local" } },
    { name: "Kitchen._googlecast._tcp.local", type: TYPE_SRV, klass: 1, ttl: 4500, flush: true, data: { kind: "srv", priority: 0, weight: 0, port: 8009, target: "kitchen.local" } },
  ]);
  assert.equal(published, 0);
  assert.equal(browser.devices.length, 0);
  browser.ingest([{ name: "kitchen.local", type: TYPE_A, klass: 1, ttl: 120, flush: true, data: { kind: "a", address: "10.0.0.7" } }]);
  assert.equal(published, 1);
  assert.equal(browser.devices[0]!.address, "10.0.0.7");
});
