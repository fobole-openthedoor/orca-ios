// Replays the official push-contract proof vector
// (orca/cloud/packages/push-contract/src/push-host-proof-vector.json) against
// this gateway's transcript/plaintext/proof builders and the ported desktop answerer.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import nacl from 'tweetnacl'
import {
  buildChallengePlaintext,
  buildTranscript,
  ChallengeStore,
  deriveHostFingerprint,
  expectedProof
} from '../src/handshake.js'
import { answerPushHostChallenge, createHostKeypair, deriveRelayHostId } from './helpers/desktop-proof.js'

const vector = JSON.parse(readFileSync(new URL('./fixtures/push-host-proof-vector.json', import.meta.url), 'utf8'))
const b64 = (value) => Buffer.from(value, 'base64')

test('vector: host key, fingerprint and transcript bytes match', () => {
  const hostSecretKey = b64(vector.hostSecretKeyB64)
  const hostPublicKey = Buffer.from(nacl.box.keyPair.fromSecretKey(hostSecretKey).publicKey)
  assert.equal(hostPublicKey.toString('base64'), vector.hostPublicKeyB64)
  assert.equal(deriveHostFingerprint(hostPublicKey), vector.hostFingerprint)
  assert.equal(deriveRelayHostId(hostPublicKey), vector.hostFingerprint)

  const transcript = buildTranscript({
    gatewayOrigin: vector.gatewayOrigin,
    gatewayEphemeralPublicKey: b64(vector.challenge.gatewayEphemeralPublicKeyB64),
    challengeNonce: b64(vector.challenge.nonceB64),
    challengeId: vector.challenge.challengeId,
    issuedAt: vector.issuedAt,
    expiresAt: vector.challenge.expiresAt,
    hostFingerprint: vector.hostFingerprint,
    hostPublicKey
  })
  assert.equal(transcript.toString('base64'), vector.transcriptB64)
})

test('vector: sealed plaintext layout matches this gateway byte for byte', () => {
  const opened = nacl.box.open(
    b64(vector.challenge.ciphertextB64),
    b64(vector.challenge.nonceB64),
    b64(vector.challenge.gatewayEphemeralPublicKeyB64),
    b64(vector.hostSecretKeyB64)
  )
  assert.ok(opened, 'vector ciphertext opens with the host secret key')
  const ours = buildChallengePlaintext(b64(vector.transcriptB64), b64(vector.challengeSecretB64))
  assert.ok(Buffer.from(opened).equals(ours))
})

test('vector: ported desktop answerer returns the proof this gateway expects', () => {
  const reasons = []
  const proof = answerPushHostChallenge(vector.challenge, {
    gatewayOrigin: vector.gatewayOrigin,
    hostFingerprint: vector.hostFingerprint,
    hostPublicKey: b64(vector.hostPublicKeyB64),
    hostSecretKey: b64(vector.hostSecretKeyB64),
    now: () => vector.issuedAt + 1_000,
    onInvalid: (reason) => reasons.push(reason)
  })
  assert.deepEqual(reasons, [])
  const expected = expectedProof(b64(vector.challengeSecretB64), b64(vector.transcriptB64)).toString('base64')
  assert.equal(proof, expected)
})

test('challenge store: issue -> ported answer -> verify, single use', () => {
  let clock = 1_800_000_000_000
  const store = new ChallengeStore({ gatewayOrigin: 'https://push.example.com', now: () => clock })
  const host = createHostKeypair()
  const issued = store.issue(host.publicKeyB64)
  assert.equal(issued.hostFingerprint, deriveRelayHostId(host.publicKey))
  assert.deepEqual(Object.keys(issued.response).sort(), [
    'challengeId',
    'ciphertextB64',
    'expiresAt',
    'gatewayEphemeralPublicKeyB64',
    'nonceB64'
  ])
  const context = {
    gatewayOrigin: 'https://push.example.com',
    hostFingerprint: issued.hostFingerprint,
    hostPublicKey: host.publicKey,
    hostSecretKey: host.secretKey,
    now: () => clock
  }
  const proof = answerPushHostChallenge(issued.response, context)
  assert.ok(proof)
  assert.deepEqual(store.verify(issued.response.challengeId, proof), { ok: true, hostFingerprint: issued.hostFingerprint })
  assert.equal(store.verify(issued.response.challengeId, proof).reason, 'already_consumed')

  // A desktop configured for a different origin refuses the challenge.
  const other = store.issue(host.publicKeyB64)
  const reasons = []
  assert.equal(
    answerPushHostChallenge(other.response, { ...context, gatewayOrigin: 'https://elsewhere.example', onInvalid: (r) => reasons.push(r) }),
    null
  )
  assert.match(reasons.join(), /gatewayOrigin/)

  // Wrong proof and expired challenge are refused.
  const third = store.issue(host.publicKeyB64)
  assert.equal(store.verify(third.response.challengeId, Buffer.alloc(32).toString('base64')).reason, 'proof_mismatch')
  const late = answerPushHostChallenge(third.response, context)
  clock += 10_001
  assert.equal(store.verify(third.response.challengeId, late).reason, 'expired')
  assert.equal(store.issue('not-a-key'), null)
})
