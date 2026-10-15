import { test } from "node:test";
import assert from "node:assert/strict";
import { NS_CONNECTION, NS_DEVICE_AUTH, NS_HEARTBEAT, NS_MEDIA, NS_RECEIVER, PAYLOAD_BINARY, PAYLOAD_STRING } from "../src/protocol/castMessage.ts";
import { ReceiverCore, SUPPORTED_MEDIA_COMMANDS, decodeAuthResponse, type PlayerBridge } from "../src/receiver/core.ts";
import { CastClient } from "../src/sender/client.ts";
import { generateSelfSignedCertificate, signChallenge } from "../src/net/tls.ts";

function makeCore(bridge: PlayerBridge = {}) {
  const logs: string[] = [];
  const identities = generateSelfSignedCertificate({ commonName: "receiver" });
  const core = new ReceiverCore({
    config: { name: "Karu · Neovim", deviceId: "0123456789ab", port: 8009 },
    bridge,
    deviceAuth: () => ({ signature: signChallenge(identities.privateKey, identities.certDer), certificate: identities.certDer }),
    log: (message) => logs.push(message),
  });
  return { core, logs, identities };
}

const json = (payload: unknown) => JSON.stringify(payload);

test("receiver: CONNECT answers with a receiver status", () => {
  const { core } = makeCore();
  const result = core.handle("sender-1", "receiver-0", NS_CONNECTION, PAYLOAD_STRING, json({ type: "CONNECT", origin: {} }));
  assert.equal(result.text.length, 1);
  const payload = JSON.parse(result.text[0]!.payload);
  assert.equal(payload.type, "RECEIVER_STATUS");
  assert.deepEqual(payload.status.applications, []);
  assert.equal(payload.status.volume.level, 0.5);
  assert.equal(payload.status.isActiveInput, true);
  assert.deepEqual(core.connectedSenders, ["sender-1"]);
  assert.equal(result.text[0]!.destinationId, "sender-1");

  // CLOSE marks the sender gone.
  core.handle("sender-1", "receiver-0", NS_CONNECTION, PAYLOAD_STRING, json({ type: "CLOSE" }));
  assert.deepEqual(core.connectedSenders, []);
});

test("receiver: GET_STATUS / heartbeat / app availability", () => {
  const { core } = makeCore();
  const status = core.handle("sender-1", "receiver-0", NS_RECEIVER, PAYLOAD_STRING, json({ type: "GET_STATUS", requestId: 5 }));
  assert.equal(JSON.parse(status.text[0]!.payload).requestId, 5);

  const pong = core.handle("sender-1", "receiver-0", NS_HEARTBEAT, PAYLOAD_STRING, json({ type: "PING", requestId: 9 }));
  assert.deepEqual(JSON.parse(pong.text[0]!.payload), { type: "PONG" });

  const availability = core.handle("sender-1", "receiver-0", NS_RECEIVER, PAYLOAD_STRING, json({ type: "GET_APP_AVAILABILITY", appId: ["CC1AD845", "233637DE"] }));
  const parsed = JSON.parse(availability.text[0]!.payload);
  assert.equal(parsed.type, "GET_APP_AVAILABILITY");
  assert.equal(parsed.availability.CC1AD845, "APP_AVAILABLE");
  assert.equal(parsed.availability["233637DE"], "APP_UNAVAILABLE");

  const unknown = core.handle("sender-1", "receiver-0", "urn:x-cast:com.example", PAYLOAD_STRING, json({ type: "NOPE" }));
  assert.deepEqual(unknown, { text: [], binary: [] });
});

test("receiver: LAUNCH starts the media receiver, other apps are refused", () => {
  const { core } = makeCore();
  const launched = core.handle("sender-1", "receiver-0", NS_RECEIVER, PAYLOAD_STRING, json({ type: "LAUNCH", appId: "CC1AD845", requestId: 2 }));
  const payload = JSON.parse(launched.text[0]!.payload);
  assert.equal(payload.requestId, 2);
  assert.equal(payload.status.applications.length, 1);
  assert.equal(payload.status.applications[0].appId, "CC1AD845");
  assert.equal(payload.status.applications[0].transportId, "web-1");
  assert.equal(payload.status.applications[0].displayName, "Default Media Receiver");
  assert.deepEqual(payload.status.applications[0].namespaces, [{ name: NS_MEDIA }, { name: "urn:x-cast:com.google.cast.debugoverlay" }]);

  const refused = core.handle("sender-1", "receiver-0", NS_RECEIVER, PAYLOAD_STRING, json({ type: "LAUNCH", appId: "9AC194DC" }));
  assert.equal(JSON.parse(refused.text[0]!.payload).type, "LAUNCH_ERROR");
});

test("receiver: SET_VOLUME updates state and tells the bridge", () => {
  const calls: [number, boolean][] = [];
  const { core } = makeCore({ onVolume: (level, muted) => calls.push([level, muted]) });
  const result = core.handle("sender-1", "receiver-0", NS_RECEIVER, PAYLOAD_STRING, json({ type: "SET_VOLUME", volume: { level: 0.8, muted: true }, requestId: 3 }));
  assert.deepEqual(calls, [[0.8, true]]);
  assert.equal(JSON.parse(result.text[0]!.payload).status.volume.level, 0.8);
  assert.equal(core.volume.muted, true);
});

test("receiver: media LOAD is bridged and answered with BUFFERING", () => {
  const loads: unknown[] = [];
  const { core } = makeCore({ onLoad: (media, options) => { loads.push({ media, options }); return true; } });
  const result = core.handle(
    "sender-1",
    "web-1",
    NS_MEDIA,
    PAYLOAD_STRING,
    json({ type: "LOAD", requestId: 4, autoplay: true, media: { contentId: "https://example.com/song.mp3", contentType: "audio/mpeg", metadata: { title: "Song" } } })
  );
  assert.equal(loads.length, 1);
  assert.equal((loads[0] as { media: { contentId: string } }).media.contentId, "https://example.com/song.mp3");
  const payload = JSON.parse(result.text[0]!.payload);
  assert.equal(payload.type, "MEDIA_STATUS");
  assert.equal(payload.status[0].playerState, "BUFFERING");
  assert.equal(payload.status[0].media.contentId, "https://example.com/song.mp3");
  assert.equal(payload.status[0].mediaSessionId, 1);
  assert.equal(payload.status[0].supportedMediaCommands, SUPPORTED_MEDIA_COMMANDS);
});

test("receiver: a refused LOAD becomes LOAD_FAILED (binary error path)", () => {
  const { core } = makeCore({ onLoad: () => false });
  const result = core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "LOAD", requestId: 8, media: { contentId: "magnet:?xt=1" } }));
  assert.equal(result.binary.length, 1);
  assert.equal(result.binary[0]!.destinationId, "sender-1");
  const parsed = JSON.parse(new TextDecoder().decode(result.binary[0]!.payload));
  assert.equal(parsed.type, "LOAD_FAILED");
  assert.equal(parsed.detailedErrorCode, 103);
  assert.equal(result.text.length, 0);

  // A LOAD without media is ignored entirely.
  assert.deepEqual(core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "LOAD", requestId: 9 })), { text: [], binary: [] });
});

test("receiver: transport commands broadcast state and drive the bridge", () => {
  const events: string[] = [];
  const { core } = makeCore({
    onLoad: () => {
      events.push("load");
      return true;
    },
    onPlay: () => {
      events.push("play");
    },
    onPause: () => {
      events.push("pause");
    },
    onStop: () => {
      events.push("stop");
    },
    onSeek: (seconds) => {
      events.push(`seek:${seconds}`);
    },
  });
  core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "LOAD", requestId: 1, media: { contentId: "u", contentType: "audio/mpeg" } }));

  const played = core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "PLAY", requestId: 2 }));
  assert.equal(played.text[0]!.destinationId, "*", "state changes are broadcast");
  assert.equal(JSON.parse(played.text[0]!.payload).status[0].playerState, "PLAYING");

  core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "PAUSE", requestId: 3 }));
  core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "SEEK", requestId: 4, relativeTime: 30 }));
  assert.equal(core.state.currentTime, 30);
  core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "STOP", requestId: 5 }));
  assert.deepEqual(events, ["load", "play", "pause", "seek:30", "stop"]);
  assert.equal(core.state.playerState, "IDLE");
  assert.equal(core.state.idleReason, "CANCELLED");

  const getStatus = core.handle("sender-1", "web-1", NS_MEDIA, PAYLOAD_STRING, json({ type: "GET_STATUS", requestId: 6 }));
  assert.equal(getStatus.text[0]!.destinationId, "sender-1");
  assert.equal(JSON.parse(getStatus.text[0]!.payload).requestId, 6);

  // STOP on the platform kills the app and pushes media state too.
  const stopped = core.handle("sender-1", "receiver-0", NS_RECEIVER, PAYLOAD_STRING, json({ type: "STOP", sessionId: "web-1-session", requestId: 7 }));
  assert.ok(stopped.text.some((message) => message.namespace === NS_MEDIA));
});

test("receiver: updateFromPlayer broadcasts the real state", () => {
  const { core } = makeCore();
  core.updateFromPlayer({ playerState: "PLAYING", currentTime: 12.5, media: { contentId: "x", contentType: "audio/mpeg" } });
  const messages = core.updateFromPlayer({ playerState: "PAUSED" });
  assert.equal(messages[0]!.destinationId, "*");
  const status = JSON.parse(messages[0]!.payload).status[0];
  assert.equal(status.playerState, "PAUSED");
  assert.equal(status.currentTime, 12.5);
  assert.equal(status.media.contentId, "x");
});

test("receiver: the device-auth answer verifies against its certificate", () => {
  const { core, identities } = makeCore();
  const result = core.handle("sender-1", "receiver-0", NS_DEVICE_AUTH, PAYLOAD_BINARY, Uint8Array.from([0x0a, 0x00]));
  assert.equal(result.binary.length, 1);
  const response = result.binary[0]!;
  assert.equal(response.namespace, NS_DEVICE_AUTH);
  const decoded = decodeAuthResponse(response.payload);
  assert.ok(decoded.signature && decoded.certificate);
  assert.deepEqual([...decoded.certificate!], [...identities.certDer]);
  assert.equal(CastClient.verifyDeviceAuth(response.payload), true, "signature over the certificate checks out");
});
