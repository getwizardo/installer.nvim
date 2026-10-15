/**
 * Self-signed TLS material for the Cast receiver, generated in pure TypeScript.
 *
 * Real Cast devices present a certificate signed by Google's device CA, but
 * senders talk to them with certificate validation disabled (the transport is
 * TLS for confidentiality, authentication happens in the `deviceauth`
 * namespace). Every open-source receiver, and pychromecast, VLC, Chromium, 
 * therefore works with a self-signed certificate. We build one from scratch:
 * X.509 v3 DER assembled by hand and signed with ECDSA P-256 via node:crypto,
 * so there is no dependency on `openssl` or a pre-baked certificate.
 */
import { createPrivateKey, createPublicKey, generateKeyPairSync, sign as signWith, verify as verifyWith, type KeyObject } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

// --- DER primitives --------------------------------------------------------

function derLength(length: number): number[] {
  if (length < 0x80) return [length];
  const bytes: number[] = [];
  let value = length;
  while (value > 0) {
    bytes.unshift(value & 0xff);
    value >>>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

function tlv(tag: number, content: Uint8Array | number[]): Uint8Array {
  const body = content instanceof Uint8Array ? content : Uint8Array.from(content);
  return Uint8Array.from([tag, ...derLength(body.length), ...body]);
}

function seq(...parts: (Uint8Array | number[])[]): Uint8Array {
  return tlv(0x30, concatBytes(...parts));
}

function setOf(...parts: (Uint8Array | number[])[]): Uint8Array {
  return tlv(0x31, concatBytes(...parts));
}

function integer(bytes: Uint8Array): Uint8Array {
  const body = bytes[0]! & 0x80 ? concatBytes(Uint8Array.from([0]), bytes) : bytes;
  return tlv(0x02, body);
}

function oid(dotted: string): Uint8Array {
  const parts = dotted.split(".").map((part) => Number(part));
  const first = parts[0]! * 40 + parts[1]!;
  const body: number[] = [first];
  for (const part of parts.slice(2)) {
    const stack: number[] = [];
    let value = part;
    do {
      stack.unshift(value & 0x7f);
      value >>>= 7;
    } while (value > 0);
    for (let i = 0; i < stack.length - 1; i++) body.push(stack[i]! | 0x80);
    body.push(stack[stack.length - 1]!);
  }
  return tlv(0x06, body);
}

function utf8(value: string): Uint8Array {
  return tlv(0x0c, new TextEncoder().encode(value));
}

function utcTime(date: Date): Uint8Array {
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  const text =
    pad(date.getUTCFullYear() % 100) +
    pad(date.getUTCMonth() + 1) +
    pad(date.getUTCDate()) +
    pad(date.getUTCHours()) +
    pad(date.getUTCMinutes()) +
    pad(date.getUTCSeconds()) +
    "Z";
  return tlv(0x17, new TextEncoder().encode(text));
}

function bitString(bytes: Uint8Array): Uint8Array {
  // 0 unused bits, then the payload.
  return tlv(0x03, concatBytes(Uint8Array.from([0]), bytes));
}

function boolean(value: boolean): Uint8Array {
  return tlv(0x01, Uint8Array.from([value ? 0xff : 0x00]));
}

function concatBytes(...chunks: (Uint8Array | number[])[]): Uint8Array {
  const arrays = chunks.map((chunk) => (chunk instanceof Uint8Array ? chunk : Uint8Array.from(chunk)));
  const total = arrays.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of arrays) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

// --- OIDs ------------------------------------------------------------------

const OID_EC_PUBLIC_KEY = "1.2.840.10045.2.1";
const OID_PRIME256V1 = "1.2.840.10045.3.1.7";
const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_COMMON_NAME = "2.5.4.3";
const OID_ORGANIZATION = "2.5.4.10";
const OID_BASIC_CONSTRAINTS = "2.5.29.19";
const OID_KEY_USAGE = "2.5.29.15";
const OID_EXT_KEY_USAGE = "2.5.29.37";
const OID_SUBJECT_ALT_NAME = "2.5.29.17";
const OID_SERVER_AUTH = "1.3.6.1.5.5.7.3.1";

export interface CertificateOptions {
  commonName?: string;
  organization?: string;
  days?: number;
  dnsNames?: string[];
  ipAddresses?: string[];
}

export interface GeneratedCertificate {
  certPem: string;
  keyPem: string;
  certDer: Uint8Array;
  privateKey: KeyObject;
  publicKey: KeyObject;
}

function nameAttribute(oidDotted: string, value: string): Uint8Array {
  return setOf(seq(oid(oidDotted), utf8(value)));
}

function x509Name(options: CertificateOptions): Uint8Array {
  return seq(
    nameAttribute(OID_ORGANIZATION, options.organization ?? "Karu"),
    nameAttribute(OID_COMMON_NAME, options.commonName ?? "Karu Cast Receiver")
  );
}

function extension(oidDotted: string, critical: boolean, value: Uint8Array): Uint8Array {
  return seq(critical ? concatBytes(oid(oidDotted), boolean(true), tlv(0x04, value)) : concatBytes(oid(oidDotted), tlv(0x04, value)));
}

function subjectAltName(options: CertificateOptions): Uint8Array {
  const parts: Uint8Array[] = [];
  for (const dns of options.dnsNames ?? ["localhost"]) {
    parts.push(tlv(0x82, new TextEncoder().encode(dns))); // [2] dNSName
  }
  for (const ip of options.ipAddresses ?? ["127.0.0.1"]) {
    parts.push(tlv(0x87, Uint8Array.from(ip.split(".").map((part) => Number(part) & 0xff)))); // [7] iPAddress
  }
  return seq(...parts);
}

function base64UrlToBytes(value: string): Uint8Array {
  return Uint8Array.from(Buffer.from(value, "base64url"));
}

function pemFromDer(der: Uint8Array, label: string): string {
  const base64 = Buffer.from(der).toString("base64");
  const lines = base64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

/**
 * Generate a self-signed X.509 v3 certificate for ECDSA P-256.
 *
 * Used as the Cast receiver's TLS identity *and* as the device-auth
 * certificate (`deviceauth` responses sign the sender's 32-byte challenge with
 * this key and hand back this certificate in `client_ca`).
 */
export function generateSelfSignedCertificate(options: CertificateOptions = {}): GeneratedCertificate {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwk = publicKey.export({ format: "jwk" }) as { x?: string; y?: string };
  if (!jwk.x || !jwk.y) throw new Error("tls: could not export the public key");
  const point = concatBytes(Uint8Array.from([0x04]), base64UrlToBytes(jwk.x), base64UrlToBytes(jwk.y));

  const notBefore = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const notAfter = new Date(Date.now() + (options.days ?? 3650) * 24 * 60 * 60 * 1000);

  const serial = new Uint8Array(8);
  for (let i = 0; i < serial.length; i++) serial[i] = Math.floor(Math.random() * 256);
  serial[0] = (serial[0]! & 0x7f) || 1;

  const spki = seq(seq(oid(OID_EC_PUBLIC_KEY), oid(OID_PRIME256V1)), bitString(point));
  const extensions = seq(
    extension(OID_BASIC_CONSTRAINTS, true, seq(boolean(false))),
    extension(OID_KEY_USAGE, true, tlv(0x03, Uint8Array.from([0x07, 0x80]))), // digitalSignature|keyEncipherment|keyAgreement
    extension(OID_EXT_KEY_USAGE, false, seq(oid(OID_SERVER_AUTH))),
    extension(OID_SUBJECT_ALT_NAME, false, subjectAltName(options))
  );

  const tbs = seq(
    tlv(0xa0, integer(Uint8Array.from([2]))), // [0] version = v3
    integer(serial),
    seq(oid(OID_ECDSA_SHA256)), // signature algorithm
    x509Name(options), // issuer (self-signed)
    seq(utcTime(notBefore), utcTime(notAfter)),
    x509Name(options), // subject
    spki,
    tlv(0xa3, extensions) // [3] explicit extensions
  );

  const signature = signWith("sha256", tbs, { key: privateKey, dsaEncoding: "der" });
  const certDer = seq(tbs, seq(oid(OID_ECDSA_SHA256)), bitString(Uint8Array.from(signature)));

  return {
    certPem: pemFromDer(certDer, "CERTIFICATE"),
    keyPem: privateKey.export({ type: "pkcs8", format: "pem" }) as string,
    certDer,
    privateKey,
    publicKey,
  };
}

/** ECDSA-SHA256 signature over an arbitrary challenge (device-auth response). */
export function signChallenge(privateKey: KeyObject, challenge: Uint8Array): Uint8Array {
  return Uint8Array.from(signWith("sha256", challenge, { key: privateKey, dsaEncoding: "der" }));
}

export function verifyChallenge(publicKey: KeyObject, challenge: Uint8Array, signature: Uint8Array): boolean {
  return verifyWith("sha256", challenge, { key: publicKey, dsaEncoding: "der" }, signature);
}

export function publicKeyFromPem(pem: string): KeyObject {
  return createPublicKey(pem);
}

export function privateKeyFromPem(pem: string): KeyObject {
  return createPrivateKey(pem);
}

export interface CertificateFiles {
  certPem: string;
  keyPem: string;
  certDer: Uint8Array;
  privateKey: KeyObject;
  /** true when the files had to be created. */
  created: boolean;
}

/**
 * Load `karu-cert.pem` / `karu-key.pem` from `dir`, generating them on first
 * run. This is what the receiver does at startup.
 */
export function loadOrCreateCertificate(dir: string, options: CertificateOptions = {}): CertificateFiles {
  const certPath = join(dir, "karu-cert.pem");
  const keyPath = join(dir, "karu-key.pem");
  if (existsSync(certPath) && existsSync(keyPath)) {
    try {
      const certPem = readFileSync(certPath, "utf8");
      const keyPem = readFileSync(keyPath, "utf8");
      const privateKey = privateKeyFromPem(keyPem);
      const certDer = new Uint8Array(Buffer.from(certPem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64"));
      return { certPem, keyPem, certDer, privateKey, created: false };
    } catch {
      // fall through and regenerate
    }
  }
  const generated = generateSelfSignedCertificate(options);
  mkdirSync(dirname(certPath), { recursive: true });
  writeFileSync(certPath, generated.certPem, { mode: 0o644 });
  writeFileSync(keyPath, generated.keyPem, { mode: 0o600 });
  return {
    certPem: generated.certPem,
    keyPem: generated.keyPem,
    certDer: generated.certDer,
    privateKey: generated.privateKey,
    created: true,
  };
}

/** TLS versions senders use; the receiver accepts 1.2 and 1.3. */
export const TLS_MIN_VERSION = "TLSv1.2";
