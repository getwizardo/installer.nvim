import { test } from "node:test";
import assert from "node:assert/strict";
import { X509Certificate, createPublicKey } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateSelfSignedCertificate, loadOrCreateCertificate, signChallenge, verifyChallenge } from "../src/net/tls.ts";

test("tls: a hand-built certificate parses as valid X.509 v3", () => {
  const generated = generateSelfSignedCertificate({ commonName: "Karu Cast Receiver", organization: "Karu", days: 365 });
  const cert = new X509Certificate(generated.certPem);
  // OpenSSL (and therefore Node) prints the RDN sequence reversed.
  assert.match(cert.subject, /CN=Karu Cast Receiver/);
  assert.match(cert.subject, /O=Karu/);
  assert.equal(cert.issuer, cert.subject, "self-signed");
  assert.equal(cert.ca, false);
  assert.ok(cert.validFrom && cert.validTo, "validity window present");
  assert.ok(new Date(cert.validTo).getTime() > Date.now(), "still valid");
  assert.match(cert.fingerprint256, /^([0-9A-F]{2}:)+[0-9A-F]{2}$/);
});

test("tls: the SAN covers localhost and 127.0.0.1 (and extra names)", () => {
  const generated = generateSelfSignedCertificate({ dnsNames: ["localhost", "karu.local"], ipAddresses: ["127.0.0.1", "192.168.1.24"] });
  const cert = new X509Certificate(generated.certPem);
  assert.equal(cert.checkHost("localhost"), "localhost");
  assert.equal(cert.checkHost("karu.local"), "karu.local");
  assert.ok(cert.checkIP("127.0.0.1"));
  assert.ok(cert.checkIP("192.168.1.24"));
  assert.equal(cert.checkHost("example.com"), undefined);
});

test("tls: the certificate is signed by its own key (ECDSA-SHA256)", () => {
  const generated = generateSelfSignedCertificate({ commonName: "karu.test" });
  const cert = new X509Certificate(generated.certPem);
  assert.equal(cert.verify(createPublicKey(generated.keyPem)), true);
  // ecdsa-with-SHA256 = 1.2.840.10045.4.3.2 -> 06 08 2A 86 48 CE 3D 04 03 02
  const der = Buffer.from(generated.certDer);
  assert.ok(der.includes(Buffer.from([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])), "signature algorithm OID");
});

test("tls: device-auth challenges round-trip with the certificate key", () => {
  const generated = generateSelfSignedCertificate({ commonName: "auth" });
  const challenge = new Uint8Array(32).fill(7);
  const signature = signChallenge(generated.privateKey, challenge);
  assert.ok(signature.length > 40, "DER-encoded ECDSA signature");
  assert.equal(verifyChallenge(createPublicKey(generated.keyPem), challenge, signature), true);
  const tampered = Uint8Array.from(challenge);
  tampered[0] = 8;
  assert.equal(verifyChallenge(createPublicKey(generated.keyPem), tampered, signature), false);
});

test("tls: loadOrCreateCertificate generates once and reloads afterwards", () => {
  const dir = mkdtempSync(join(tmpdir(), "karu-cert-"));
  try {
    const first = loadOrCreateCertificate(dir, { commonName: "karu-nvim" });
    assert.equal(first.created, true);
    assert.equal(readFileSync(join(dir, "karu-cert.pem"), "utf8"), first.certPem);
    const second = loadOrCreateCertificate(dir, { commonName: "karu-nvim" });
    assert.equal(second.created, false);
    assert.equal(second.certPem, first.certPem, "the same identity is reused");
    assert.ok(second.certDer.length > 100);
    assert.equal(second.certDer.length, first.certDer.length);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
