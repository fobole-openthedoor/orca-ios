// Gateway side of the Orca push host handshake (protocol "orca-push-host-proof/v1").
//
// The desktop holds an X25519 key (tweetnacl box). The gateway seals a random
// 32-byte secret plus a transcript to that key with a fresh ephemeral key; only
// the key holder can open it and return HMAC-SHA256(secret, domain||transcript).
// Byte layouts mirror cloud/packages/push-contract/src/push-host-proof-transcript.ts.
import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import nacl from 'tweetnacl'

export const PUSH_HOST_PROOF_TRANSCRIPT_DOMAIN = 'orca-push-host-proof/v1'
export const PUSH_HOST_CHALLENGE_PLAINTEXT_DOMAIN = 'orca-push-host-challenge/v1'
export const CHALLENGE_TTL_MS = 10_000
// Challenges are kept this long past expiry so a late proof reads as expired.
const CHALLENGE_RETENTION_MS = 30_000
const MAX_PENDING_CHALLENGES = 2_000

const encoder = new TextEncoder()

function uint32(value) {
  const bytes = Buffer.alloc(4)
  bytes.writeUInt32BE(value, 0)
  return bytes
}

function uint64(value) {
  const bytes = Buffer.alloc(8)
  bytes.writeBigUInt64BE(BigInt(value), 0)
  return bytes
}

function field(name, value) {
  const encodedName = encoder.encode(name)
  return Buffer.concat([uint32(encodedName.byteLength), encodedName, uint32(value.byteLength), value])
}

/** Same derivation as deriveRelayHostId on the desktop. */
export function deriveHostFingerprint(hostPublicKey) {
  return createHash('sha256').update(hostPublicKey).digest('base64url').slice(0, 16)
}

/** Rejects alternative base64 spellings so the signed transcript always names the same bytes. */
export function decodeCanonicalBase64(value, expectedBytes) {
  if (typeof value !== 'string') return null
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) return null
  const decoded = Buffer.from(value, 'base64')
  return decoded.byteLength === expectedBytes && decoded.toString('base64') === value ? decoded : null
}

export function buildTranscript(input) {
  if (input.gatewayEphemeralPublicKey.byteLength !== 32) throw new Error('gateway key must be 32 bytes')
  if (input.challengeNonce.byteLength !== 24) throw new Error('nonce must be 24 bytes')
  if (input.hostPublicKey.byteLength !== 32) throw new Error('host key must be 32 bytes')
  return Buffer.concat([
    field('protocol', encoder.encode(PUSH_HOST_PROOF_TRANSCRIPT_DOMAIN)),
    field('version', Buffer.from([1])),
    field('gatewayOrigin', encoder.encode(input.gatewayOrigin)),
    field('gatewayEphemeralPublicKey', input.gatewayEphemeralPublicKey),
    field('challengeNonce', input.challengeNonce),
    field('challengeId', encoder.encode(input.challengeId)),
    field('issuedAt', uint64(input.issuedAt)),
    field('expiresAt', uint64(input.expiresAt)),
    field('hostFingerprint', encoder.encode(input.hostFingerprint)),
    field('hostPublicKey', input.hostPublicKey)
  ])
}

export function buildChallengePlaintext(transcript, secret) {
  if (secret.byteLength !== 32) throw new Error('challenge secret must be 32 bytes')
  return Buffer.concat([
    encoder.encode(`${PUSH_HOST_CHALLENGE_PLAINTEXT_DOMAIN}\0`),
    uint32(transcript.byteLength),
    transcript,
    secret
  ])
}

export function expectedProof(secret, transcript) {
  return createHmac('sha256', secret)
    .update(encoder.encode(`${PUSH_HOST_PROOF_TRANSCRIPT_DOMAIN}\0ack\0`))
    .update(transcript)
    .digest()
}

function digest(bytes) {
  return createHash('sha256').update(bytes).digest()
}

/** In-memory, single-use challenges. They live 10 s, so persistence buys nothing. */
export class ChallengeStore {
  constructor({ gatewayOrigin, now = Date.now }) {
    this.gatewayOrigin = gatewayOrigin
    this.now = now
    this.pending = new Map()
  }

  /** Returns the wire response plus the bound fingerprint, or null for a malformed key. */
  issue(hostPublicKeyB64) {
    const hostPublicKey = decodeCanonicalBase64(hostPublicKeyB64, 32)
    if (!hostPublicKey) return null
    this.prune()
    if (this.pending.size >= MAX_PENDING_CHALLENGES) return { busy: true }
    const hostFingerprint = deriveHostFingerprint(hostPublicKey)
    const ephemeral = nacl.box.keyPair()
    const challengeNonce = randomBytes(nacl.box.nonceLength)
    const secret = randomBytes(32)
    const challengeId = randomUUID()
    const issuedAt = this.now()
    const expiresAt = issuedAt + CHALLENGE_TTL_MS
    const transcript = buildTranscript({
      gatewayOrigin: this.gatewayOrigin,
      gatewayEphemeralPublicKey: Buffer.from(ephemeral.publicKey),
      challengeNonce,
      challengeId,
      issuedAt,
      expiresAt,
      hostFingerprint,
      hostPublicKey
    })
    const ciphertext = nacl.box(
      buildChallengePlaintext(transcript, secret),
      challengeNonce,
      hostPublicKey,
      ephemeral.secretKey
    )
    // Keep only a digest of the expected ack, never the secret itself.
    this.pending.set(challengeId, {
      hostFingerprint,
      proofDigest: digest(expectedProof(secret, transcript)),
      expiresAt,
      consumed: false
    })
    return {
      response: {
        challengeId,
        gatewayEphemeralPublicKeyB64: Buffer.from(ephemeral.publicKey).toString('base64'),
        nonceB64: challengeNonce.toString('base64'),
        ciphertextB64: Buffer.from(ciphertext).toString('base64'),
        expiresAt
      },
      hostFingerprint
    }
  }

  /** @returns {{ok: true, hostFingerprint: string} | {ok: false, reason: string}} */
  verify(challengeId, proofB64) {
    const entry = this.pending.get(challengeId)
    if (!entry) return { ok: false, reason: 'unknown_challenge' }
    if (entry.consumed) return { ok: false, reason: 'already_consumed' }
    if (this.now() > entry.expiresAt) return { ok: false, reason: 'expired' }
    const proof = decodeCanonicalBase64(proofB64, 32)
    if (!proof || !timingSafeEqual(digest(proof), entry.proofDigest)) {
      return { ok: false, reason: 'proof_mismatch' }
    }
    entry.consumed = true
    return { ok: true, hostFingerprint: entry.hostFingerprint }
  }

  prune() {
    const cutoff = this.now() - CHALLENGE_RETENTION_MS
    for (const [id, entry] of this.pending) {
      if (entry.expiresAt < cutoff) this.pending.delete(id)
    }
  }
}
