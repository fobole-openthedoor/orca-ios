// Request validation. Mirrors the official contract's limits
// (cloud/packages/push-contract) but ignores unknown notification fields so a
// newer desktop that adds one keeps working.

const OPAQUE_ID_MAX = 128
const MAX_REGISTRATION_IDS = 20
const MAX_BADGE = 99_999
const PRINTABLE_ASCII = /^[\x20-\x7e]+$/

const isObject = (value) => Boolean(value) && typeof value === 'object' && !Array.isArray(value)
const isOpaqueId = (value) => typeof value === 'string' && value.length >= 1 && value.length <= OPAQUE_ID_MAX
const isNonNegInt = (value) => Number.isSafeInteger(value) && value >= 0
const optionalString = (value, max) =>
  value === undefined || (typeof value === 'string' && value.length >= 1 && value.length <= max)

export function parseChallengeRequest(body) {
  if (!isObject(body) || body.v !== 1 || typeof body.hostPublicKeyB64 !== 'string') return null
  return { hostPublicKeyB64: body.hostPublicKeyB64 }
}

export function parseSessionRequest(body) {
  if (!isObject(body) || body.v !== 1 || !isOpaqueId(body.challengeId) || typeof body.proofB64 !== 'string') {
    return null
  }
  return { challengeId: body.challengeId, proofB64: body.proofB64 }
}

/** @returns {{ok: true, value: object} | {ok: false, reason: string}} */
export function parseRegisterRequest(body) {
  if (!isObject(body) || body.v !== 1) return { ok: false, reason: 'version' }
  if (!isOpaqueId(body.deviceId)) return { ok: false, reason: 'deviceId' }
  // This gateway only speaks APNs; an Android phone needs the official gateway.
  if (body.platform !== 'ios') return { ok: false, reason: 'platform' }
  if (body.apnsEnvironment !== 'sandbox' && body.apnsEnvironment !== 'production') {
    return { ok: false, reason: 'apnsEnvironment' }
  }
  if (typeof body.token !== 'string' || body.token.length < 1 || body.token.length > 4096) {
    return { ok: false, reason: 'token' }
  }
  return {
    ok: true,
    value: { deviceId: body.deviceId, apnsEnvironment: body.apnsEnvironment, token: body.token }
  }
}

/** @returns {{ok: true, value: {registrationIds: string[], notification: object}} | {ok: false, reason: string}} */
export function parseSendRequest(body) {
  if (!isObject(body) || body.v !== 1) return { ok: false, reason: 'version' }
  const ids = body.registrationIds
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > MAX_REGISTRATION_IDS || !ids.every(isOpaqueId)) {
    return { ok: false, reason: 'registrationIds' }
  }
  const n = body.notification
  if (!isObject(n)) return { ok: false, reason: 'notification' }
  const kind = n.kind
  if (kind !== undefined && kind !== 'alert' && kind !== 'dismiss' && kind !== 'badge') {
    return { ok: false, reason: 'kind' }
  }
  if (n.badge !== undefined && !(isNonNegInt(n.badge) && n.badge <= MAX_BADGE)) return { ok: false, reason: 'badge' }
  if (kind === 'badge' && n.badge === undefined) return { ok: false, reason: 'badge' }
  if (typeof n.title !== 'string' || n.title.length < 1 || n.title.length > 256) return { ok: false, reason: 'title' }
  if (typeof n.body !== 'string' || n.body.length > 1024) return { ok: false, reason: 'body' }
  if (n.sound !== undefined && typeof n.sound !== 'boolean') return { ok: false, reason: 'sound' }
  if (n.expiresAt !== undefined && !(Number.isSafeInteger(n.expiresAt) && n.expiresAt > 0)) {
    return { ok: false, reason: 'expiresAt' }
  }
  if (n.notificationId !== undefined && !(optionalString(n.notificationId, 2048) && PRINTABLE_ASCII.test(n.notificationId))) {
    return { ok: false, reason: 'notificationId' }
  }
  if (kind === 'dismiss' && n.notificationId === undefined) return { ok: false, reason: 'notificationId' }
  if (!isNonNegInt(n.notificationSeq)) return { ok: false, reason: 'notificationSeq' }
  if (!isOpaqueId(n.notificationEpoch)) return { ok: false, reason: 'notificationEpoch' }
  if (typeof n.source !== 'string' || n.source.length > 64) return { ok: false, reason: 'source' }
  const agentState = n.agentState ?? null
  if (agentState !== null && agentState !== 'needs-input' && agentState !== 'finished') {
    return { ok: false, reason: 'agentState' }
  }
  if (!optionalString(n.worktreeId, 2048) || !optionalString(n.paneKey, 2048) || !optionalString(n.executionHost, 2048)) {
    return { ok: false, reason: 'ids' }
  }
  const notification = {
    ...(kind === undefined ? {} : { kind }),
    ...(n.badge === undefined ? {} : { badge: n.badge }),
    ...(n.expiresAt === undefined ? {} : { expiresAt: n.expiresAt }),
    ...(n.sound === undefined ? {} : { sound: n.sound }),
    ...(n.notificationId === undefined ? {} : { notificationId: n.notificationId }),
    notificationSeq: n.notificationSeq,
    notificationEpoch: n.notificationEpoch,
    source: n.source,
    agentState,
    title: n.title,
    body: n.body,
    ...(n.worktreeId === undefined ? {} : { worktreeId: n.worktreeId }),
    ...(n.paneKey === undefined ? {} : { paneKey: n.paneKey }),
    ...(n.executionHost === undefined ? {} : { executionHost: n.executionHost })
  }
  return { ok: true, value: { registrationIds: [...new Set(ids)], notification } }
}
