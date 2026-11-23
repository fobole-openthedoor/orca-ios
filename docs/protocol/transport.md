# Transport: pairing, encryption, RPC

How this client reaches a desktop. Everything here is implemented in `packages/OrcaCore` and
mirrors the TypeScript in [stablyai/orca](https://github.com/stablyai/orca); each section names
its source of truth there. For the application-level methods carried over this transport, see
[rpc-surface.md](rpc-surface.md).

## Pairing offer

Source: `src/shared/remote-runtime/pairing/mobile-relay-pairing-offer.ts`, `mobile/src/pairing/pairing.ts`.
Swift: `Pairing/PairingOffer.swift`.

The desktop shows a QR code holding `orca://pair#<code>` (also accepted: `orca://pair?code=<code>`
and the bare code). `<code>` is base64url JSON, padding optional:

```json
{
  "v": 2,
  "endpoint": "ws://192.168.1.20:6768",
  "deviceToken": "…",
  "publicKeyB64": "<host Curve25519 public key, 32 bytes>",
  "pairedDeviceId": "…",
  "scope": "mobile",
  "relay": { "v": 1, "directorUrl": "https://…", "cellUrl": "https://…", "assignmentEpoch": 0,
             "relayHostId": "<16 base64url>", "inviteToken": "<43 base64url>",
             "inviteExpiresAt": 0, "e2eeFraming": 2 }
}
```

`pairedDeviceId`, `scope` and `relay` are optional. The public key is pinned: every later
connection must prove it. The relay route is parsed and validated but **not yet dialed** — this
client connects to `endpoint` only, so phone and desktop must share a network (LAN, Tailscale).

After the first connection, a host advertising `pairing.ticket-exchange.v1` accepts
`pairing.exchangeTicket { deviceToken }` with a phone-generated token (24 random bytes, hex), which
retires the scanned code.

## E2EE v2

Source: `src/shared/remote-runtime/e2ee/*`. Swift: `E2EE/*`, `Crypto/*`.

1. Phone → host, plaintext text frame:
   `{"type":"e2ee_hello","v":2,"clientPublicKeyB64","clientNonceB64","capabilities":{"framing":[2],"payloadKinds":["text","binary"]},"context":{"protocol":"orca-mobile-e2ee","initiator":"mobile","responder":"desktop","transport":"direct"}}`
   with a fresh X25519 key pair and a 32-byte nonce per socket.
2. Host → phone, plaintext: `{"type":"e2ee_ready","v":2,"desktopPublicKeyB64","clientNonceB64","desktopNonceB64","selection":{"framing":2,"payloadKinds":["text","binary"]},"context":{…same…}}`.
   The phone accepts only exactly these keys, its own nonce echoed, and the pinned public key.
3. Both derive keys:
   - `shared = HSalsa20(X25519(clientSecret, hostPublic), 0¹⁶)` (`nacl.box.before`)
   - `transcript` = the length-prefixed field list in `E2EEV2Transcript.encode`
   - `salt = SHA256("orca-mobile-e2ee/v2/salt\0" ‖ clientNonce ‖ desktopNonce)`
   - `okm = HKDF-SHA256(shared, salt, "orca-mobile-e2ee/v2/session\0" ‖ SHA256(transcript), 96)`
   - `mobileToDesktopKey = okm[0..32]`, `desktopToMobileKey = okm[32..64]`, `sessionId = okm[64..96]`
4. Phone → host, sealed: `{"type":"e2ee_auth","v":2,"transcriptHashB64","deviceToken"}`.
5. Host → phone, sealed: `{"type":"e2ee_authenticated","v":2,"transcriptHashB64"}`, or
   `{"type":"e2ee_error",…}` for a token it no longer accepts.

A sealed frame is `nonce(24) ‖ secretbox(header ‖ payload)`:

- `header = sessionId(32) ‖ direction(1) ‖ kind(1) ‖ counter(8, big endian)`
- `nonce = sessionId[0..12] ‖ 0x02 ‖ direction ‖ kind ‖ 0x00 ‖ counter(8, big endian)`
- direction: 0 phone→host, 1 host→phone; kind: 0 text, 1 binary
- one counter per direction, shared by both kinds, starting at 0

Text frames travel as canonical base64 in a WebSocket text message; binary frames as WebSocket
binary. A frame that is not the next expected one does not open. `secretbox` is NaCl's
XSalsa20-Poly1305, implemented in Swift here and checked against libsodium vectors.

The legacy (pre-v2) framing is not implemented; a host too old for v2 cannot be reached.

## RPC

Source: `mobile/src/transport/rpc/*`. Swift: `RPC/OrcaConnection.swift`.

Request: `{"id":"rpc-<n>-<ms>","deviceToken":"…","method":"…","params":…}`.
Reply: `{"id","ok":true,"result":…}` or `{"id","ok":false,"error":{"code","message","data"}}`.
A streaming request keeps answering under the same `id` until a result of `{"type":"end"}`.

Right after auth the client sends `runtime.clientCapabilities.update { clientCapabilities: [...] }`
and treats the socket as connected once that settles (a refusal or timeout is not fatal).

Liveness: after 20 s without inbound frames the client sends `status.get { probe: true }` with an
id prefixed `mobile-liveness-`; three unanswered probes (8 s each) close the socket. A closed socket
is redialed with backoff, and open subscriptions are sent again under their original ids.

Compressed frames (`transport.compressed-frames.v1`, always advertised): a binary frame starting
`0x7a`, then payload kind (1 text, 2 binary), a little-endian uint32 inflated length, and one gzip
member. A text payload is handled as if it had arrived as a text frame.
