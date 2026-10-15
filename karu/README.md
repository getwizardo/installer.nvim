# Karu — Google Cast, in TypeScript

Karu is the Cast component of **kaeru.nvim**: it speaks the protocol Google's
Chromecast devices use (CASTV2 over TLS on port 8009, advertised over mDNS as
`_googlecast._tcp`), so Neovim can be on **both** sides of a cast:

```
   phone / browser                          ┌──────────── Neovim ────────────┐
   ┌───────────────┐                        │                                │
   │ YouTube Music │  1. mDNS  _googlecast  │  :Karu receive                 │
   │  Cast button  ├───────────────────────►│   karu receive (this package)  │
   └───────┬───────┘                        │        │                       │
           │ 2. TLS 8009 CASTV2             │        │ LOAD                  │
           └───────────────────────────────►│        ▼                       │
                                            │  Kikru (lua/kaeru/kikru)       │
                                            │  mpv / ffplay / VLC            │
                                            └────────────────────────────────┘

   ┌──────────── Neovim ────────────┐        ┌───────────────┐
   │  :Karu discover / :Karu cast   │  mDNS  │  real Cast    │
   │   karu sender (this package)   ├───────►│  device (TV,  │
   │        LAUNCH CC1AD845         │  TLS   │  speaker, …)  │
   │        LOAD <media url>        ├───────►│               │
   └────────────────────────────────┘        └───────────────┘
```

**Sender** — `karu discover`, `karu cast`, `karu control`, `karu seek`,
`karu volume`, `karu status`: find real Cast devices on the LAN and drive them
(launch the Default Media Receiver, load a media URL, transport control).

**Receiver** — `karu receive`: appear in the Cast device list of the YouTube /
YouTube Music / Chrome / iOS apps and play what they hand over. Every `LOAD`
is bridged into [Kikru](../lua/kaeru/kikru), the Lua player, so casts land in
the Neovim queue with the EQ, the analyzer and the rest of the player. When
Kikru is not running, `--fallback mpv|ffplay` plays locally instead.

Everything is dependency-free: Node's own `crypto`, `tls`, `dgram`, `http`,
`net`. No npm runtime dependencies, no `castv2-client`, no `mdns` package.

```console
$ karu discover
Karu · 2 device(s)
  1. Living room TV (192.168.1.24:8009)
  2. Kitchen speaker (192.168.1.31:8009)

$ karu cast https://music.youtube.com/watch?v=dQw4w9WgXcQ "Living room TV"
karu: casting to Living room TV (192.168.1.24:8009)
karu: LOAD ok · CC1AD845 (Default Media Receiver)
karu: state BUFFERING → PLAYING

$ karu receive --name "Vim TV" --port 8009
karu: receiver ready · "Vim TV" · 192.168.1.10:8009 · id 4f2a9c1b7e30
karu: mDNS: _googlecast._tcp.advertised (Vim TV)
karu: cast from 192.168.1.42 → https://music.youtube.com/…
karu: bridge → Kikru http://127.0.0.1:8722/cast
```

## Contents

| Path | What it is |
| --- | --- |
| `src/protocol/protobuf.ts` | minimal protobuf writer/reader (varint, length-delimited, unknown fields skipped) |
| `src/protocol/castMessage.ts` | the `CastMessage` envelope: 4-byte big-endian length prefix + protobuf |
| `src/protocol/namespaces.ts` | namespace, app id and media-command constants |
| `src/protocol/messages.ts` | typed builders/parsers for `CONNECT`, `PING`, `GET_STATUS`, `LAUNCH`, `SET_VOLUME`, `LOAD`, `PLAY`, `STOP`, `SEEK`, `MEDIA_STATUS`, `RECEIVER_STATUS`, device auth |
| `src/net/dns.ts` | DNS/mDNS packet encode & decode (name compression, PTR/SRV/TXT/A/AAAA) |
| `src/net/mdns.ts` | responder (advertise `_googlecast._tcp`) and browser (find devices) |
| `src/net/cert.ts` | self-signed X.509 generation in pure TS (ECDSA P-256, DER) |
| `src/receiver/core.ts` | the pure Cast state machine (sessions, receiver + media namespaces, device auth) |
| `src/receiver/server.ts` | TLS server on 8009 that feeds `ReceiverCore` |
| `src/receiver/bridge.ts` | hands `LOAD`/transport to Kikru's HTTP cast server, falls back to mpv/ffplay |
| `src/sender/client.ts` | one connection to one device: connect, launch, load, transport, volume, status |
| `src/sender/discovery.ts` | mDNS browse → `{id, name, address, port, model}` |
| `src/cli.ts` | `karu` command line |

## Protocol notes

* **Framing** — every message is `uint32 big-endian length` followed by a
  protobuf `CastMessage`; the receiver refuses frames larger than 1 MiB.
* **`CastMessage`** — `protocol_version=CASTV2_1_0`, `source_id`,
  `destination_id`, `namespace`, `payload_type=STRING`, `payload_utf8`.
  The platform endpoint is `receiver-0`; senders call themselves `sender-<n>`.
* **Namespaces** — `urn:x-cast:com.google.cast.tp.connection` (CONNECT/CLOSE),
  `…tp.heartbeat` (PING/PONG), `…receiver` (GET_STATUS, LAUNCH, STOP,
  SET_VOLUME), `…media` (LOAD, PLAY, PAUSE, STOP, SEEK, GET_STATUS),
  `…tp.deviceauth` (AuthMessage — challenge/response).
* **Launching** — `LAUNCH` with `appId: CC1AD845` (Default Media Receiver)
  returns a `transportId`; the sender has to open a *second* logical channel by
  sending `CONNECT` addressed to that transport before talking media.
* **Media** — `LOAD { media: { contentId, contentType, streamType, metadata },
  autoplay }` answers `MEDIA_STATUS` and the receiver broadcasts new
  `MEDIA_STATUS` frames on every state change (`BUFFERING`, `PLAYING`,
  `PAUSED`, `IDLE` + `idleReason`). `supportedMediaCommands` is the bitmask
  `1|2|4|8|16|32|64|128` (pause, seek, volume…), which is what makes the
  scrub bar in the phone app light up.
* **mDNS** — a query for `_googlecast._tcp.local` PTR; answers carry PTR +
  SRV (port 8009) + TXT + A records. TXT keys: `id` (12 hex), `fn` (friendly
  name), `md` (model), `ca` (2800), `ic`, `ve`, `st`, `rs`.
* **TLS** — CASTV2 runs inside TLS. Real devices present a Google-issued
  certificate; a receiver *we* implement generates a self-signed ECDSA P-256
  certificate (`src/net/cert.ts`, written with no dependencies and verified in
  tests with `crypto.X509Certificate`) and accepts any client certificate
  (`VerifyClientCertIfGiven`).
* **Device auth** — the sender sends a 32-byte challenge; the receiver answers
  with `AuthResponse { signature, client_auth_certificate, client_ca }` where
  the signature is ECDSA-SHA256 over the challenge with the advertised
  certificate's key. Official senders only *require* this for protected
  content; our response is well formed so senders that do check are answered
  correctly.

References used while implementing: the CASTV2 message shapes documented in
[`node-castv2`](https://github.com/thibauts/node-castv2),
[`gcast`](https://github.com/mochaaP/gcast)`PROTOCOL.md`,
[`dnicolson/cast-receiver`](https://github.com/dnicolson/cast-receiver) (Go)
and the mDNS service definition used by Chrome
(`_googlecast._tcp`, TXT keys above).

## Command line

```
karu info                                     protocol + environment report
karu version                                  version
karu discover [--timeout MS] [--address HOST[:PORT]]
karu probe HOST[:PORT]                        reachability + status of one device
karu cast <url|query> [DEVICE] [--device NAME|ID|ADDRESS|INDEX]
          [--autoplay false] [--title T] [--content-type AUDIO|VIDEO] [--json]
karu control play|pause|toggle|stop|quit [DEVICE]
karu seek <seconds> [DEVICE]
karu volume <0-100|+N|-N|mute|unmute|toggle> [DEVICE]
karu status [DEVICE]
karu receive [--name N] [--port P] [--address IP] [--no-mdns]
             [--bridge URL] [--token T] [--fallback mpv|ffplay|none]
             [--cert-dir DIR] [--youtube] [--json]
```

`DEVICE` is a device name, id, or `host[:port]`; only the *second positional*
or `--device` is ever treated as a device, so a URL is never mistaken for one.
`--json` (also honoured by `cast`, `status`, `receive`) prints one JSON object
per line — that is what the Neovim side consumes.

Environment: `KARU_DEVICES` (extra `host[:port]` candidates, comma separated)
and `KIKRU_CAST_URL` (where the receiver hands media over, default
`http://127.0.0.1:8722`; `--bridge`/`--token` override it per run).

`karu receive` is long-running: it prints `{"event":"ready", …}` once the
device is up (with the *real* port when `--port 0` was used), then one JSON
line per event (`cast`, `play`, `pause`, `stop`, `seek`, `volume`) and finally
`{"event":"stopped"}`.

## Neovim integration

`lua/kaeru/karu.lua` is the bridge; `:Karu` (or `:Kaeru karu …` /
`:Kaeru googlecast …`) wraps the CLI:

```vim
:Karu                      " status of the first device
:Karu discover             " who is on the network
:Karu cast <url|query> [dev]
:Karu play | pause | toggle | quit | next | prev [dev]
:Karu seek <seconds> [dev]
:Karu volume 70 | +10 | mute [dev]
:Karu receive [--name N] [--port P] [--no-mdns] [--fallback mpv]
:Karu off                  " stop the receiver
:Karu bridge | probe | info | help
```

Config (`kaeru.yaml` / `setup({ karu = … })`):

```lua
karu = {
  enabled = true,
  path = nil,               -- nil = karu/bin/karu inside the plugin, or $PATH
  node = nil,               -- nil = `node`
  device_name = "Karu · Neovim",
  port = 8009,
  mdns = true,
  bridge = nil,             -- nil = http://127.0.0.1:<kikru.cast.port>
  token = nil,
  fallback = "none",        -- mpv | ffplay | none
  autostart = false,
  notify = true,
  timeout = 2500,
  devices = {},             -- extra host[:port] entries to probe
}
```

## Development

```console
$ npm install          # typescript + @types/node, nothing else
$ npm test             # node --test test/*.test.ts
$ npm run typecheck    # tsc --noEmit
$ npm run build        # tsc → dist/ (imports are rewritten .ts → .js)
$ node src/cli.ts info # no build needed: Node ≥ 22.6 strips the types
```

The tests cover the protobuf codec (round-trip, unknown fields), the
`CastMessage` framing, DNS/mDNS encoding *and* decoding of a captured
`_googlecast._tcp` packet, the X.509 generator (verified with Node's own
`X509Certificate`), the receiver state machine (connect/launch/load/play/
pause/stop/seek/volume/idle), the Kikru bridge against a stub HTTP server, and
a full sender↔receiver session over real TLS sockets on `127.0.0.1`.

## Limits

* `--fallback mpv` needs `mpv` (or `ffplay`) on `$PATH`; the default `none`
  only bridges to Kikru.
* Media *content* is not transcoded: the receiver hands the URL over, Kikru's
  own yt-dlp pipeline resolves YouTube links (that is what makes the YouTube
  app's casts work).
* The receiver signs device-auth challenges with its own self-signed
  certificate, not a Google-issued one, so DRM/protected content will not play.
* IPv4 mDNS is implemented (AAAA records are parsed but not advertised).

MIT, same as kaeru.nvim.
