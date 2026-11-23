// Behaviour specific to the Worker port: running without an APNs key, the
// per-IP limit kept in the Durable Object, one provider token shared by all
// sends, and the routes answered outside the Durable Object.
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { answerPushHostChallenge, createHostKeypair, deriveRelayHostId } from './helpers/desktop-proof.js'
import { startHarness } from './helpers/harness.js'

const DEVICE = 'ee'.repeat(32)

let keyless
let keyed
before(async () => {
  keyless = await startHarness({ gatewayPort: 18451, env: { APNS_KEY: '' } })
  keyed = await startHarness({ gatewayPort: 18452 })
})
after(async () => {
  await keyless?.close()
  await keyed?.close()
})

async function post(h, path, body, { token, ip } = {}) {
  const response = await fetch(`${h.origin}${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(ip ? { 'cf-connecting-ip': ip } : {})
    },
    body: JSON.stringify(body)
  })
  const text = await response.text()
  return { status: response.status, json: text ? JSON.parse(text) : null, headers: response.headers }
}

async function signIn(h) {
  const host = createHostKeypair()
  const challenge = await post(h, '/v1/host/challenge', { v: 1, hostPublicKeyB64: host.publicKeyB64 })
  assert.equal(challenge.status, 200)
  const proofB64 = answerPushHostChallenge(challenge.json, {
    gatewayOrigin: h.origin,
    hostFingerprint: deriveRelayHostId(host.publicKey),
    hostPublicKey: host.publicKey,
    hostSecretKey: host.secretKey
  })
  const session = await post(h, '/v1/host/session', { v: 1, challengeId: challenge.json.challengeId, proofB64 })
  assert.equal(session.status, 200)
  return session.json.sessionToken
}

const notification = (extra = {}) => ({
  notificationSeq: 1,
  notificationEpoch: 'e1',
  source: 'agent-task-complete',
  agentState: null,
  title: 't',
  body: 'b',
  ...extra
})

test('without APNS_KEY: health says so, handshake and registration work, sends report error', async () => {
  const health = await fetch(`${keyless.origin}/health`)
  assert.equal(health.status, 200)
  assert.deepEqual(await health.json(), { ok: true, pushProtocol: 1, apnsConfigured: false })

  const token = await signIn(keyless)
  const reg = await post(keyless, '/v1/devices', { v: 1, deviceId: 'p', platform: 'ios', token: DEVICE, apnsEnvironment: 'sandbox' }, { token })
  assert.equal(reg.status, 200)
  const sent = await post(keyless, '/v1/send', { v: 1, registrationIds: [reg.json.registrationId], notification: notification() }, { token })
  assert.deepEqual(sent.json, { results: [{ registrationId: reg.json.registrationId, status: 'error' }] })
  assert.equal(keyless.fakeApns.requests.length, 0)
})

test('health, 404 and response headers match the Node gateway', async () => {
  assert.deepEqual(await (await fetch(`${keyed.origin}/health`)).json(), { ok: true, pushProtocol: 1, apnsConfigured: true })
  for (const [method, path] of [['GET', '/'], ['POST', '/health'], ['GET', '/v1/nope'], ['GET', '/v1/send'], ['PUT', '/v1/devices']]) {
    const response = await fetch(`${keyed.origin}${path}`, { method })
    assert.equal(response.status, 404, `${method} ${path}`)
    assert.deepEqual(await response.json(), { error: 'not_found' })
    assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8')
    assert.equal(response.headers.get('cache-control'), 'no-store')
  }
  const unauthorized = await fetch(`${keyed.origin}/v1/devices`)
  assert.equal(unauthorized.status, 401)
  assert.deepEqual(await unauthorized.json(), { error: 'invalid_token' })
  const malformed = await fetch(`${keyed.origin}/v1/host/challenge`, { method: 'POST', body: '{', headers: { 'cf-connecting-ip': '198.51.100.9' } })
  assert.equal(malformed.status, 400)
  assert.deepEqual(await malformed.json(), { error: 'invalid_request' })
})

test('unauthenticated endpoints: 60 per minute per client IP, kept in the Durable Object', async () => {
  const host = createHostKeypair()
  const statuses = []
  // 121 calls inside a second span at most one minute boundary, so one window sees more than 60.
  for (let i = 0; i < 121; i += 1) {
    statuses.push((await post(keyed, '/v1/host/challenge', { v: 1, hostPublicKeyB64: host.publicKeyB64 }, { ip: '203.0.113.7' })).status)
  }
  assert.ok(statuses.includes(429), 'some calls were limited')
  assert.ok(statuses.filter((s) => s === 200).length <= 120)
  // Another IP is unaffected.
  assert.equal((await post(keyed, '/v1/host/challenge', { v: 1, hostPublicKeyB64: host.publicKeyB64 }, { ip: '203.0.113.8' })).status, 200)
})

test('one provider token is reused across sends', async () => {
  const token = await signIn(keyed)
  const reg = await post(keyed, '/v1/devices', { v: 1, deviceId: 'p', platform: 'ios', token: DEVICE, apnsEnvironment: 'production' }, { token })
  keyed.fakeApns.requests.splice(0)
  for (const seq of [1, 2]) {
    const r = await post(keyed, '/v1/send', { v: 1, registrationIds: [reg.json.registrationId], notification: notification({ notificationSeq: seq }) }, { token })
    assert.equal(r.json.results[0].status, 'queued')
  }
  const [first, second] = keyed.fakeApns.requests
  assert.equal(first.headers.authorization, second.headers.authorization)
  assert.match(first.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/)
})
