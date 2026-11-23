// Separate APNs keys per environment (topic-specific keys are limited to one
// environment): each send signs with the key of the device's environment, an
// environment without a key reports "error", and APNS_KEY is the fallback.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { answerPushHostChallenge, createHostKeypair, deriveRelayHostId } from './helpers/desktop-proof.js'
import { createApnsKey, verifyProviderJwt } from './helpers/fake-apns.js'
import { startHarness } from './helpers/harness.js'
import { ApnsClient } from '../src/apns.js'
import { loadApnsCredentials } from '../src/config.js'

const DEVICE = 'ab'.repeat(32)
const sandboxKey = createApnsKey()
const productionKey = createApnsKey()
const fallbackKey = createApnsKey()
const harnesses = []
after(async () => {
  for (const h of harnesses) await h.close()
})

async function post(h, path, body, token) {
  const response = await fetch(`${h.origin}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })
  return { status: response.status, json: await response.json() }
}

async function signIn(h) {
  const host = createHostKeypair()
  const challenge = await post(h, '/v1/host/challenge', { v: 1, hostPublicKeyB64: host.publicKeyB64 })
  const proofB64 = answerPushHostChallenge(challenge.json, {
    gatewayOrigin: h.origin,
    hostFingerprint: deriveRelayHostId(host.publicKey),
    hostPublicKey: host.publicKey,
    hostSecretKey: host.secretKey
  })
  return (await post(h, '/v1/host/session', { v: 1, challengeId: challenge.json.challengeId, proofB64 })).json.sessionToken
}

/** Registers one sandbox and one production phone, sends to both, returns statuses and APNs requests. */
async function sendToBoth(h) {
  const token = await signIn(h)
  const ids = {}
  for (const environment of ['sandbox', 'production']) {
    const reg = await post(h, '/v1/devices', { v: 1, deviceId: `phone-${environment}`, platform: 'ios', token: DEVICE, apnsEnvironment: environment }, token)
    assert.equal(reg.status, 200)
    ids[environment] = reg.json.registrationId
  }
  h.fakeApns.requests.splice(0)
  const notification = { notificationSeq: 1, notificationEpoch: 'e', source: 's', agentState: null, title: 't', body: 'b' }
  const statuses = {}
  for (const environment of ['sandbox', 'production']) {
    const r = await post(h, '/v1/send', { v: 1, registrationIds: [ids[environment]], notification }, token)
    statuses[environment] = r.json.results[0].status
  }
  return { statuses, requests: h.fakeApns.requests.splice(0) }
}

const kidOf = (request) => verifyProviderJwt(request.headers.authorization.replace(/^bearer /, ''), sandboxKey.publicKey).header.kid
const signedBy = (request, key) => verifyProviderJwt(request.headers.authorization.replace(/^bearer /, ''), key.publicKey).ok

test('only a sandbox key: sandbox sends, production reports error and sends nothing', async () => {
  const h = await startHarness({
    gatewayPort: 18461,
    env: { APNS_KEY: '', APNS_KEY_ID: '', APNS_SANDBOX_KEY: sandboxKey.pem, APNS_SANDBOX_KEY_ID: 'SANDBOX001' }
  })
  harnesses.push(h)
  assert.equal((await (await fetch(`${h.origin}/health`)).json()).apnsConfigured, true)
  const { statuses, requests } = await sendToBoth(h)
  assert.deepEqual(statuses, { sandbox: 'queued', production: 'error' })
  assert.equal(requests.length, 1)
  assert.equal(kidOf(requests[0]), 'SANDBOX001')
  assert.ok(signedBy(requests[0], sandboxKey))
})

test('separate keys: each environment signs with its own key', async () => {
  const h = await startHarness({
    gatewayPort: 18462,
    env: {
      APNS_KEY: '',
      APNS_KEY_ID: '',
      APNS_SANDBOX_KEY: sandboxKey.pem,
      APNS_SANDBOX_KEY_ID: 'SANDBOX001',
      APNS_PRODUCTION_KEY: productionKey.pem.replace(/\n/g, '\\n'),
      APNS_PRODUCTION_KEY_ID: 'PRODUCT001'
    }
  })
  harnesses.push(h)
  const { statuses, requests } = await sendToBoth(h)
  assert.deepEqual(statuses, { sandbox: 'queued', production: 'queued' })
  const [sandbox, production] = requests
  assert.equal(kidOf(sandbox), 'SANDBOX001')
  assert.ok(signedBy(sandbox, sandboxKey))
  assert.ok(!signedBy(sandbox, productionKey))
  assert.equal(kidOf(production), 'PRODUCT001')
  assert.ok(signedBy(production, productionKey))
  assert.notEqual(sandbox.headers.authorization, production.headers.authorization)
})

test('APNS_KEY is the fallback for an environment without its own key', async () => {
  const h = await startHarness({
    gatewayPort: 18463,
    env: { APNS_KEY: fallbackKey.pem, APNS_KEY_ID: 'FALLBACK01', APNS_PRODUCTION_KEY: productionKey.pem, APNS_PRODUCTION_KEY_ID: 'PRODUCT001' }
  })
  harnesses.push(h)
  const { statuses, requests } = await sendToBoth(h)
  assert.deepEqual(statuses, { sandbox: 'queued', production: 'queued' })
  assert.equal(kidOf(requests[0]), 'FALLBACK01')
  assert.ok(signedBy(requests[0], fallbackKey))
  assert.equal(kidOf(requests[1]), 'PRODUCT001')
})

test('config: key ids pair with their PEMs; a PEM without an id does not count', () => {
  const base = { APNS_TEAM_ID: 'TEAM123456' }
  assert.equal(loadApnsCredentials(base), null)
  assert.equal(loadApnsCredentials({ ...base, APNS_SANDBOX_KEY: sandboxKey.pem }), null)
  assert.equal(loadApnsCredentials({ APNS_KEY: fallbackKey.pem, APNS_KEY_ID: 'X' }), null, 'team id required')
  const both = loadApnsCredentials({ ...base, APNS_KEY: fallbackKey.pem, APNS_KEY_ID: 'FALLBACK01' })
  assert.equal(both.sandbox.keyId, 'FALLBACK01')
  assert.equal(both.production.keyId, 'FALLBACK01')
  const split = loadApnsCredentials({ ...base, APNS_SANDBOX_KEY: sandboxKey.pem, APNS_SANDBOX_KEY_ID: 'S' })
  assert.equal(split.sandbox.keyId, 'S')
  assert.equal(split.production, null)
})

test('client: host per environment, one cached token per key, invalidation per key', async () => {
  const calls = []
  let status = 200
  const transport = {
    async request({ host, headers }) {
      calls.push({ host, authorization: headers.authorization })
      return { status, body: status === 200 ? '' : JSON.stringify({ reason: 'ExpiredProviderToken' }) }
    }
  }
  let clock = 1_800_000_000_000
  const caches = new Map()
  const client = new ApnsClient({
    credentials: {
      sandbox: { keyPem: sandboxKey.pem, keyId: 'S', teamId: 'T' },
      production: { keyPem: productionKey.pem, keyId: 'P', teamId: 'T' }
    },
    transport,
    now: () => clock,
    tokenCache: (keyId) => {
      let entry = null
      const cache = { load: () => entry, save: (v) => (entry = v), clear: () => (entry = null) }
      caches.set(keyId, cache)
      return cache
    }
  })
  const push = (environment) => client.send({ environment, deviceToken: DEVICE, headers: {}, payload: {} })
  await push('sandbox')
  await push('production')
  await push('sandbox')
  assert.deepEqual(calls.map((c) => c.host), ['api.sandbox.push.apple.com', 'api.push.apple.com', 'api.sandbox.push.apple.com'])
  assert.equal(calls[0].authorization, calls[2].authorization)
  assert.notEqual(calls[0].authorization, calls[1].authorization)
  assert.deepEqual([...caches.keys()].sort(), ['P', 'S'])

  // Apple rejects the sandbox token: only the sandbox key mints a new one.
  status = 403
  clock += 1_000
  await push('sandbox')
  assert.equal(caches.get('S').load(), null)
  assert.ok(caches.get('P').load())
  status = 200
  await push('sandbox')
  await push('production')
  assert.notEqual(calls.at(-2).authorization, calls[0].authorization)
  assert.equal(calls.at(-1).authorization, calls[1].authorization)
})

test('client: an environment without a key is not configured for that device', async () => {
  const client = new ApnsClient({
    credentials: { sandbox: null, production: { keyPem: productionKey.pem, keyId: 'P', teamId: 'T' } },
    transport: { request: async () => ({ status: 200, body: '' }) }
  })
  assert.equal(client.configured, true)
  assert.deepEqual(await client.send({ environment: 'sandbox', deviceToken: DEVICE, headers: {}, payload: {} }), {
    outcome: 'error',
    reason: 'apns_sandbox_not_configured'
  })
  assert.equal((await client.send({ environment: 'production', deviceToken: DEVICE, headers: {}, payload: {} })).outcome, 'sent')
  assert.equal(new ApnsClient({ credentials: null, transport: {} }).configured, false)
})
