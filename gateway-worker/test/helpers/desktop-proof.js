// Independent JS port of the desktop's answerPushHostChallenge
// (src/main/runtime/push/push-host-proof.ts + hosts/identity/host-challenge-envelope.ts).
// Deliberately does not import the gateway's handshake module.
import { createHash, createHmac, timingSafeEqual } from 'node:crypto'
import nacl from 'tweetnacl'

const PROOF_DOMAIN = 'orca-push-host-proof/v1'
const PLAINTEXT_DOMAIN = 'orca-push-host-challenge/v1'
const CLOCK_SKEW_MS = 30_000
const MAX_WINDOW_MS = 10_000
const FIELD_COUNT = 10
const enc = new TextEncoder()
const dec = new TextDecoder()

export function deriveRelayHostId(publicKey) {
  return createHash('sha256').update(publicKey).digest('base64url').slice(0, 16)
}

function decodeCanonicalBase64(value, expectedBytes) {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) return null
  const decoded = Buffer.from(value, 'base64')
  return decoded.byteLength === expectedBytes && decoded.toString('base64') === value ? decoded : null
}

function equalBytes(left, right) {
  return Boolean(left && left.byteLength === right.byteLength && timingSafeEqual(left, right))
}

function parseTranscript(transcript) {
  const fields = new Map()
  const view = new DataView(transcript.buffer, transcript.byteOffset, transcript.byteLength)
  let offset = 0
  try {
    while (offset < transcript.byteLength) {
      const nameLength = view.getUint32(offset, false)
      offset += 4
      const name = dec.decode(transcript.slice(offset, offset + nameLength))
      offset += nameLength
      const valueLength = view.getUint32(offset, false)
      offset += 4
      if (fields.has(name) || offset + valueLength > transcript.byteLength) return null
      fields.set(name, transcript.slice(offset, offset + valueLength))
      offset += valueLength
    }
  } catch {
    return null
  }
  return offset === transcript.byteLength ? fields : null
}

function readUint64(value) {
  if (!value || value.byteLength !== 8) return null
  const parsed = new DataView(value.buffer, value.byteOffset, 8).getBigUint64(0, false)
  return parsed <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(parsed) : null
}

function openEnvelope(challenge, hostSecretKey, onInvalid) {
  const peerKey = decodeCanonicalBase64(challenge.gatewayEphemeralPublicKeyB64, 32)
  const nonce = decodeCanonicalBase64(challenge.nonceB64, 24)
  const ciphertext = Buffer.from(challenge.ciphertextB64, 'base64')
  if (!peerKey || !nonce || ciphertext.toString('base64') !== challenge.ciphertextB64) return null
  const plaintext = nacl.box.open(ciphertext, nonce, peerKey, hostSecretKey)
  if (!plaintext) {
    onInvalid?.('challenge-box-open')
    return null
  }
  const domain = enc.encode(`${PLAINTEXT_DOMAIN}\0`)
  if (!equalBytes(plaintext.slice(0, domain.byteLength), domain) || plaintext.byteLength < domain.byteLength + 36) {
    return null
  }
  const transcriptLength = new DataView(plaintext.buffer, plaintext.byteOffset + domain.byteLength, 4).getUint32(0, false)
  const start = domain.byteLength + 4
  const secretStart = start + transcriptLength
  if (secretStart + 32 !== plaintext.byteLength) return null
  return {
    transcript: plaintext.slice(start, secretStart),
    secret: plaintext.slice(secretStart),
    peerKey,
    nonce
  }
}

/** Returns the base64 HMAC proof, or null (with reasons via onInvalid). */
export function answerPushHostChallenge(challenge, context) {
  const envelope = openEnvelope(challenge, context.hostSecretKey, context.onInvalid)
  if (!envelope) return null
  const fields = parseTranscript(envelope.transcript)
  if (!fields || fields.size !== FIELD_COUNT) {
    context.onInvalid?.('transcript-structure')
    return null
  }
  const now = (context.now ?? Date.now)()
  const issuedAt = readUint64(fields.get('issuedAt'))
  const expiresAt = readUint64(fields.get('expiresAt'))
  const checks = [
    ['issuedAt-readable', issuedAt !== null],
    ['issuedAt-not-future', issuedAt === null || issuedAt - CLOCK_SKEW_MS <= now],
    ['not-expired', now - CLOCK_SKEW_MS <= challenge.expiresAt],
    ['issuedAt-before-expiry', issuedAt === null || issuedAt <= challenge.expiresAt],
    ['window', issuedAt === null || challenge.expiresAt - issuedAt <= MAX_WINDOW_MS],
    ['expiry-consistent', expiresAt === challenge.expiresAt],
    ['protocol', equalBytes(fields.get('protocol'), enc.encode(PROOF_DOMAIN))],
    ['version', equalBytes(fields.get('version'), new Uint8Array([1]))],
    ['gatewayOrigin', equalBytes(fields.get('gatewayOrigin'), enc.encode(context.gatewayOrigin))],
    ['gatewayEphemeralPublicKey', equalBytes(fields.get('gatewayEphemeralPublicKey'), envelope.peerKey)],
    ['challengeNonce', equalBytes(fields.get('challengeNonce'), envelope.nonce)],
    ['challengeId', equalBytes(fields.get('challengeId'), enc.encode(challenge.challengeId))],
    ['hostFingerprint', equalBytes(fields.get('hostFingerprint'), enc.encode(context.hostFingerprint))],
    ['hostPublicKey', equalBytes(fields.get('hostPublicKey'), context.hostPublicKey)]
  ]
  const failed = checks.filter(([, ok]) => !ok).map(([name]) => name)
  if (failed.length > 0) {
    context.onInvalid?.(`transcript:${failed.join('+')}`)
    return null
  }
  return createHmac('sha256', envelope.secret)
    .update(enc.encode(`${PROOF_DOMAIN}\0ack\0`))
    .update(envelope.transcript)
    .digest('base64')
}

export function createHostKeypair() {
  const keys = nacl.box.keyPair()
  return {
    publicKey: keys.publicKey,
    secretKey: keys.secretKey,
    publicKeyB64: Buffer.from(keys.publicKey).toString('base64')
  }
}
