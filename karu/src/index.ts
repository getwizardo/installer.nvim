/**
 * Karu: Google Cast (CASTV2) in TypeScript.
 *
 * Two directions, one implementation:
 *   - `CastReceiverServer` makes this machine appear in the Cast list of the
 *     YouTube / YouTube Music apps (and anything else that scans for
 *     `_googlecast._tcp`) and bridges every LOAD into Kikru.
 *   - `CastClient` discovers and drives real Chromecast / Google TV devices.
 */
export { CastReceiverServer, CAST_PORT, defaultCertDir, type ReceiverInfo, type ReceiverServerOptions } from "./receiver/server.ts";
export {
  ReceiverCore,
  PLATFORM_ID,
  SUPPORTED_MEDIA_COMMANDS,
  decodeAuthResponse,
  encodeAuthResponse,
  extractChallenge,
  type HandleResult,
  type MediaState,
  type PlayerBridge,
  type ReceiverConfig,
} from "./receiver/core.ts";
export { PlayerBridgeImpl, normalizeContentId, type BridgeOptions, type CastEvent } from "./receiver/bridge.ts";
export { CastClient, type CastClientOptions, type CastClientState } from "./sender/client.ts";
export { discover, probeAddress, selectDevice, parseAddress, type DiscoveredDevice, type DiscoveryOptions } from "./sender/discovery.ts";
export { MdnsBrowser, MdnsResponder, discoverDevices, deviceIdFrom, GOOGLECAST_SERVICE, hostName, primaryAddress, serviceRecords, serviceTxt, type CastDevice, type CastServiceConfig } from "./net/mdns.ts";
export {
  CLASS_IN,
  TYPE_A,
  TYPE_ANY,
  TYPE_PTR,
  TYPE_SRV,
  TYPE_TXT,
  decodePacket,
  encodePacket,
  readName,
  type DnsPacket,
  type Question,
  type ResourceRecord,
} from "./net/dns.ts";
export { generateSelfSignedCertificate, loadOrCreateCertificate, signChallenge, verifyChallenge, type CertificateOptions, type GeneratedCertificate } from "./net/tls.ts";
export {
  APP_DEFAULT_MEDIA_RECEIVER,
  NS_CONNECTION,
  NS_DEVICE_AUTH,
  NS_HEARTBEAT,
  NS_MEDIA,
  NS_RECEIVER,
  createFrameParser,
  decodeCastMessage,
  encodeCastMessage,
  type CastMessage,
} from "./protocol/castMessage.ts";
export * as lyrics from "./lyrics/index.ts";
export * as messages from "./protocol/messages.ts";
export * as protobuf from "./protocol/protobuf.ts";
