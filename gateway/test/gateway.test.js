// End-to-end over HTTP: ported desktop handshake, registration, and the APNs
// requests each notification kind produces (against a local HTTP/2 stub).
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { answerPushHostChallenge, createHostKeypair, deriveRelayHostId } from './helpers/desktop-proof.js'
import { startHarness } from './helpers/harness.js'
import { verifyProviderJwt } from './helpers/fake-apns.js'
import { encodeDeviceTokenBlob } from '../src/token-blob.js'

const GATEWAY_PORT = 18431
const APNS_PORT = 18432
const DEVICE = 'aa'.repeat(32)
const DEAD_DEVICE = 'dd'.repeat(32)
const START = 'bb'.repeat(40)
const ACTIVITY = 'cc'.repeat(40)
const APPLE_EPOCH = 978_307_200

let h
before(async () => {
  h = await startHarness({
    gatewayPort: GATEWAY_PORT,
    apnsPort: APNS_PORT,
    respond: (request) =>
      request.path === `/3/device/${DEAD_DEVICE}` ? { status: 410, body: { reason: 'Unregistered' } } : undefined
  })
})
after(async () => {
  await h?.close()
})

async function post(path, body, token) {
  const response = await fetch(`${h.origin}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })
  const text = await response.text()
  return { status: response.status, json: text ? JSON.parse(text) : null }
}

async function signIn(host = createHostKeypair()) {
  const challenge = await post('/v1/host/challenge', { v: 1, hostPublicKeyB64: host.publicKeyB64 })
  assert.equal(challenge.status, 200)
  const hostFingerprint = deriveRelayHostId(host.publicKey)
  const proofB64 = answerPushHostChallenge(challenge.json, {
    gatewayOrigin: h.origin,
    hostFingerprint,
    hostPublicKey: host.publicKey,
    hostSecretKey: host.secretKey
  })
  assert.ok(proofB64, 'desktop logic accepts the gateway challenge')
  const session = await post('/v1/host/session', { v: 1, challengeId: challenge.json.challengeId, proofB64 })
  assert.equal(session.status, 200)
  assert.deepEqual(Object.keys(session.json).sort(), ['expiresAt', 'hostFingerprint', 'sessionToken'])
  assert.equal(session.json.hostFingerprint, hostFingerprint)
  assert.match(session.json.sessionToken, /^[A-Za-z0-9_-]{43}$/)
  // Milliseconds, as the desktop compares against Date.now().
  assert.ok(session.json.expiresAt > Date.now() + 60_000)
  return { host, hostFingerprint, token: session.json.sessionToken }
}

function blob(extra = {}) {
  return encodeDeviceTokenBlob({ d: DEVICE, t: 'com.thm.orcaios', h: 'My Mac', k: 'mac-1', ...extra })
}

function notification(extra = {}) {
  return {
    notificationId: 'n-1',
    notificationSeq: 1,
    notificationEpoch: 'epoch-1',
    source: 'agent-task-complete',
    agentState: null,
    title: 'repo / feature-x',
    body: 'Claude needs your input\nsecond line',
    worktreeId: 'wt-1',
    paneKey: 'pane-1',
    expiresAt: Date.now() + 300_000,
    ...extra
  }
}

const sent = () => h.fakeApns.requests.splice(0)

test('handshake, registration and plain alert', async () => {
  const { token, hostFingerprint } = await signIn()
  const reg = await post('/v1/devices', { v: 1, deviceId: 'phone-1', platform: 'ios', token: blob(), apnsEnvironment: 'sandbox' }, token)
  assert.equal(reg.status, 200)
  assert.deepEqual(Object.keys(reg.json), ['registrationId'])

  // Re-registration keeps the id.
  const again = await post('/v1/devices', { v: 1, deviceId: 'phone-1', platform: 'ios', token: blob(), apnsEnvironment: 'sandbox' }, token)
  assert.equal(again.json.registrationId, reg.json.registrationId)

  sent()
  const result = await post('/v1/send', { v: 1, registrationIds: [reg.json.registrationId], notification: notification() }, token)
  assert.equal(result.status, 200)
  assert.deepEqual(result.json, { results: [{ registrationId: reg.json.registrationId, status: 'queued' }] })
  const [alert, ...rest] = sent()
  assert.equal(rest.length, 0, 'agentState null: no Live Activity push')
  assert.equal(alert.path, `/3/device/${DEVICE}`)
  assert.equal(alert.headers['apns-push-type'], 'alert')
  assert.equal(alert.headers['apns-topic'], 'com.thm.orcaios')
  assert.equal(alert.headers['apns-priority'], '10')
  assert.match(alert.headers['apns-collapse-id'], /^[0-9a-f]{64}$/)
  assert.match(alert.headers['apns-expiration'], /^\d+$/)
  const jwt = verifyProviderJwt(alert.headers.authorization.replace(/^bearer /, ''), h.apnsKey.publicKey)
  assert.ok(jwt.ok)
  assert.deepEqual(jwt.header, { alg: 'ES256', kid: 'TESTKEY123' })
  assert.equal(jwt.payload.iss, 'TEAM123456')
  assert.deepEqual(alert.body.aps, {
    alert: { title: 'repo / feature-x', body: 'Claude needs your input\nsecond line' },
    sound: 'default',
    'thread-id': 'wt-1'
  })
  assert.equal(alert.body.orca.host, 'mac-1')
  assert.equal(alert.body.orca.worktreeId, 'wt-1')
  assert.equal(alert.body.orca.paneKey, 'pane-1')
  assert.equal(alert.body.orca.notificationId, 'n-1')
  assert.equal(alert.body.orca.hostFingerprint, hostFingerprint)

  // State survived to disk, with the blob decoded.
  const state = JSON.parse(readFileSync(join(h.dataDir, 'state.json'), 'utf8'))
  assert.equal(state.registrations[reg.json.registrationId].device.deviceToken, DEVICE)
})

test('Live Activity: only ends, never starts', async () => {
  const { token } = await signIn()
  const register = (extra) =>
    post('/v1/devices', { v: 1, deviceId: 'phone-la', platform: 'ios', token: blob(extra), apnsEnvironment: 'production' }, token)
  const { json: { registrationId } } = await register({ s: START })
  sent()

  // needs-input without an activity: alert only, nothing push-started.
  let result = await post('/v1/send', { v: 1, registrationIds: [registrationId], notification: notification({ agentState: 'needs-input' }) }, token)
  assert.equal(result.json.results[0].status, 'queued')
  assert.deepEqual(sent().map((r) => r.path), [`/3/device/${DEVICE}`])

  // The app reported a working activity's token: needs-input ends it at once.
  await register({ s: START, a: { 'wt-1': ACTIVITY } })
  await post('/v1/send', { v: 1, registrationIds: [registrationId], notification: notification({ agentState: 'needs-input' }) }, token)
  let requests = sent()
  let end = requests.find((r) => r.path === `/3/device/${ACTIVITY}`)
  assert.equal(end.headers['apns-push-type'], 'liveactivity')
  assert.equal(end.headers['apns-topic'], 'com.thm.orcaios.push-type.liveactivity')
  assert.equal(end.body.aps.event, 'end')
  assert.equal(end.body.aps['content-state'].phase, 'needsYou')
  assert.equal(end.body.aps['content-state'].detail, 'Claude needs your input second line')
  assert.ok(Math.abs(end.body.aps['dismissal-date'] - Date.now() / 1000) < 5)
  assert.ok(!requests.some((r) => r.path === `/3/device/${START}`))
  assert.equal(h.gateway.store.state.registrations[registrationId].device.activityTokens['wt-1'], undefined)

  // finished -> end, dismissed now.
  await register({ s: START, a: { 'wt-1': ACTIVITY } })
  await post('/v1/send', { v: 1, registrationIds: [registrationId], notification: notification({ agentState: 'finished', body: 'Done' }) }, token)
  end = sent().find((r) => r.path === `/3/device/${ACTIVITY}`)
  assert.equal(end.body.aps.event, 'end')
  assert.equal(end.body.aps['content-state'].phase, 'done')
  assert.equal(end.body.aps['content-state'].detail, 'Done')

  // finished with no activity token: alert only.
  await post('/v1/send', { v: 1, registrationIds: [registrationId], notification: notification({ agentState: 'finished' }) }, token)
  assert.deepEqual(sent().map((r) => r.path), [`/3/device/${DEVICE}`])
})

test('badge sums hosts, dismiss sends nothing', async () => {
  const a = await signIn()
  const b = await signIn()
  const regA = (await post('/v1/devices', { v: 1, deviceId: 'phone-b', platform: 'ios', token: DEVICE, apnsEnvironment: 'sandbox' }, a.token)).json.registrationId
  const regB = (await post('/v1/devices', { v: 1, deviceId: 'phone-b', platform: 'ios', token: blob(), apnsEnvironment: 'sandbox' }, b.token)).json.registrationId
  sent()
  await post('/v1/send', { v: 1, registrationIds: [regA], notification: notification({ kind: 'badge', badge: 2 }) }, a.token)
  const r = await post('/v1/send', { v: 1, registrationIds: [regB], notification: notification({ kind: 'badge', badge: 3 }) }, b.token)
  assert.equal(r.json.results[0].status, 'queued')
  const requests = sent()
  assert.deepEqual(requests.map((x) => x.body), [{ aps: { badge: 2 } }, { aps: { badge: 5 } }])
  assert.equal(requests[1].headers['apns-expiration'], '0')

  const dismiss = await post('/v1/send', { v: 1, registrationIds: [regA], notification: notification({ kind: 'dismiss', title: 'Orca', body: '' }) }, a.token)
  assert.deepEqual(dismiss.json.results, [{ registrationId: regA, status: 'queued' }])
  assert.equal(sent().length, 0)
})

test('hosts are isolated; dead tokens are reported and removed', async () => {
  const a = await signIn()
  const b = await signIn()
  const regA = (await post('/v1/devices', { v: 1, deviceId: 'p', platform: 'ios', token: blob({ d: DEAD_DEVICE }), apnsEnvironment: 'sandbox' }, a.token)).json.registrationId

  // Host B can neither send to nor delete host A's registration.
  const foreign = await post('/v1/send', { v: 1, registrationIds: [regA], notification: notification() }, b.token)
  assert.deepEqual(foreign.json.results, [{ registrationId: regA, status: 'error' }])
  const del = await fetch(`${h.origin}/v1/devices/${regA}`, { method: 'DELETE', headers: { authorization: `Bearer ${b.token}` } })
  assert.equal(del.status, 404)

  sent()
  const dead = await post('/v1/send', { v: 1, registrationIds: [regA], notification: notification() }, a.token)
  assert.deepEqual(dead.json.results, [{ registrationId: regA, status: 'dead' }])
  assert.equal(h.gateway.store.state.registrations[regA], undefined)
  const gone = await fetch(`${h.origin}/v1/devices/${regA}`, { method: 'DELETE', headers: { authorization: `Bearer ${a.token}` } })
  assert.equal(gone.status, 404)

  const regA2 = (await post('/v1/devices', { v: 1, deviceId: 'p2', platform: 'ios', token: DEVICE, apnsEnvironment: 'sandbox' }, a.token)).json.registrationId
  const ok = await fetch(`${h.origin}/v1/devices/${encodeURIComponent(regA2)}`, { method: 'DELETE', headers: { authorization: `Bearer ${a.token}` } })
  assert.equal(ok.status, 204)
})

test('refusals: bad token, bad blob, foreign topic, bad proof, oversize body', async () => {
  const { token } = await signIn()
  assert.equal((await post('/v1/send', { v: 1, registrationIds: ['x'], notification: notification() }, 'nope')).status, 401)
  assert.equal((await post('/v1/devices', { v: 1, deviceId: 'p', platform: 'ios', token: 'orcaios1.!!!', apnsEnvironment: 'sandbox' }, token)).status, 400)
  assert.equal((await post('/v1/devices', { v: 1, deviceId: 'p', platform: 'ios', token: blob({ t: 'com.other.app' }), apnsEnvironment: 'sandbox' }, token)).status, 400)
  assert.equal((await post('/v1/devices', { v: 1, deviceId: 'p', platform: 'android', token: 'x'.repeat(40) }, token)).status, 400)
  assert.equal((await post('/v1/devices', { v: 1, deviceId: 'p', platform: 'ios', token: DEVICE }, token)).status, 400)

  const host = createHostKeypair()
  const challenge = await post('/v1/host/challenge', { v: 1, hostPublicKeyB64: host.publicKeyB64 })
  const bad = await post('/v1/host/session', { v: 1, challengeId: challenge.json.challengeId, proofB64: Buffer.alloc(32).toString('base64') })
  assert.equal(bad.status, 401)
  const unknown = await post('/v1/host/session', { v: 1, challengeId: 'nope', proofB64: Buffer.alloc(32).toString('base64') })
  assert.equal(unknown.status, 401)

  const big = await post('/v1/send', { v: 1, pad: 'x'.repeat(20_000) }, token)
  assert.equal(big.status, 413)
})

test('ALLOWED_HOST_FINGERPRINTS refuses other desktops with 403', async () => {
  const allowed = createHostKeypair()
  const other = await startHarness({
    gatewayPort: 18433,
    apnsPort: 18434,
    env: { ALLOWED_HOST_FINGERPRINTS: deriveRelayHostId(allowed.publicKey) }
  })
  try {
    const call = (host) =>
      fetch(`${other.origin}/v1/host/challenge`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ v: 1, hostPublicKeyB64: host.publicKeyB64 })
      }).then((response) => response.status)
    assert.equal(await call(allowed), 200)
    assert.equal(await call(createHostKeypair()), 403)
  } finally {
    await other.close()
  }
})
