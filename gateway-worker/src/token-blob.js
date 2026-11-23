// Decodes the token string the desktop forwards from the phone.
//
// The community iOS app registers `"orcaios1." + base64url(JSON)` where JSON is
//   { d: hex device token, t: topic, h: desktop name, k: app's id for the desktop,
//     s?: hex push-to-start token, a?: { [worktreeId]: hex activity update token } }
// Anything without that prefix is a bare hex APNs device token.
import { Buffer } from 'node:buffer'

export const TOKEN_BLOB_PREFIX = 'orcaios1.'
const HEX = /^(?:[0-9a-fA-F]{2}){8,512}$/
const TOPIC = /^[A-Za-z0-9.-]{1,200}$/
const MAX_ACTIVITY_TOKENS = 64
const MAX_LABEL_CHARS = 256

function hex(value) {
  return typeof value === 'string' && HEX.test(value) ? value.toLowerCase() : null
}

function label(value) {
  if (value === undefined || value === null) return ''
  if (typeof value !== 'string') return null
  return value.slice(0, MAX_LABEL_CHARS)
}

/**
 * @returns {{ok: true, device: object} | {ok: false, reason: string}}
 * device = { deviceToken, topic, hostName, hostKey, pushToStartToken?, activityTokens }
 */
export function parseDeviceToken(token, { defaultTopic, allowedTopics }) {
  if (typeof token !== 'string' || token.length === 0 || token.length > 4096) {
    return { ok: false, reason: 'token_length' }
  }
  if (!token.startsWith(TOKEN_BLOB_PREFIX)) {
    const deviceToken = hex(token)
    if (!deviceToken) return { ok: false, reason: 'token_not_hex' }
    return {
      ok: true,
      device: { deviceToken, topic: defaultTopic, hostName: '', hostKey: '', activityTokens: {} }
    }
  }
  let blob
  try {
    blob = JSON.parse(Buffer.from(token.slice(TOKEN_BLOB_PREFIX.length), 'base64url').toString('utf8'))
  } catch {
    return { ok: false, reason: 'blob_unreadable' }
  }
  if (!blob || typeof blob !== 'object' || Array.isArray(blob)) return { ok: false, reason: 'blob_shape' }
  const deviceToken = hex(blob.d)
  if (!deviceToken) return { ok: false, reason: 'blob_device_token' }
  const topic = blob.t === undefined ? defaultTopic : blob.t
  if (typeof topic !== 'string' || !TOPIC.test(topic)) return { ok: false, reason: 'blob_topic' }
  if (!allowedTopics.has(topic)) return { ok: false, reason: 'blob_topic_not_allowed' }
  const hostName = label(blob.h)
  const hostKey = label(blob.k)
  if (hostName === null || hostKey === null) return { ok: false, reason: 'blob_labels' }
  let pushToStartToken
  if (blob.s !== undefined && blob.s !== null && blob.s !== '') {
    pushToStartToken = hex(blob.s)
    if (!pushToStartToken) return { ok: false, reason: 'blob_start_token' }
  }
  const activityTokens = {}
  if (blob.a !== undefined && blob.a !== null) {
    if (typeof blob.a !== 'object' || Array.isArray(blob.a)) return { ok: false, reason: 'blob_activity_tokens' }
    const entries = Object.entries(blob.a)
    if (entries.length > MAX_ACTIVITY_TOKENS) return { ok: false, reason: 'blob_activity_tokens' }
    for (const [worktreeId, value] of entries) {
      const activityToken = hex(value)
      if (!worktreeId || worktreeId.length > 2048 || !activityToken) {
        return { ok: false, reason: 'blob_activity_tokens' }
      }
      activityTokens[worktreeId] = activityToken
    }
  }
  return {
    ok: true,
    device: {
      deviceToken,
      topic,
      hostName,
      hostKey,
      ...(pushToStartToken ? { pushToStartToken } : {}),
      activityTokens
    }
  }
}

/** Helper for the iOS side and tests: builds the blob exactly as the app should. */
export function encodeDeviceTokenBlob(blob) {
  return TOKEN_BLOB_PREFIX + Buffer.from(JSON.stringify(blob), 'utf8').toString('base64url')
}
