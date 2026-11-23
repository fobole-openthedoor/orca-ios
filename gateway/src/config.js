// Reads gateway configuration from the environment. Fails fast on values the
// handshake depends on (PUBLIC_ORIGIN), and degrades softly on APNs credentials
// so the handshake can be tested before an Apple key is available.
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const DAY_MS = 24 * 60 * 60 * 1000

function intEnv(env, name, fallback) {
  const raw = env[name]
  if (raw === undefined || raw.trim() === '') return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`)
  return value
}

function listEnv(env, name) {
  return (env[name] ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
}

/** The desktop compares against `new URL(gatewayUrl).origin`, so only a bare origin can match. */
export function normalizePublicOrigin(value) {
  if (!value || !value.trim()) throw new Error('PUBLIC_ORIGIN is required (e.g. https://push.example.com)')
  const url = new URL(value.trim())
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new Error('PUBLIC_ORIGIN must be an http(s) origin')
  }
  if ((url.pathname !== '/' && url.pathname !== '') || url.search || url.hash) {
    throw new Error('PUBLIC_ORIGIN must be an origin without a path, e.g. https://push.example.com')
  }
  return url.origin
}

function readApnsKey(env) {
  if (env.APNS_KEY && env.APNS_KEY.trim()) {
    // .env files often carry the PEM on one line with literal "\n" escapes.
    return env.APNS_KEY.includes('\\n') ? env.APNS_KEY.replace(/\\n/g, '\n') : env.APNS_KEY
  }
  if (env.APNS_KEY_PATH && env.APNS_KEY_PATH.trim()) {
    return readFileSync(resolve(env.APNS_KEY_PATH.trim()), 'utf8')
  }
  return null
}

export function loadConfig(env = process.env) {
  const keyPem = readApnsKey(env)
  const keyId = env.APNS_KEY_ID?.trim() || null
  const teamId = env.APNS_TEAM_ID?.trim() || null
  const apns =
    keyPem && keyId && teamId
      ? { keyPem, keyId, teamId }
      : null
  const defaultTopic = env.APNS_DEFAULT_TOPIC?.trim() || 'com.thm.orcaios'
  const allowedTopics = listEnv(env, 'APNS_ALLOWED_TOPICS')
  return {
    host: env.HOST?.trim() || '0.0.0.0',
    port: intEnv(env, 'PORT', 8787),
    publicOrigin: normalizePublicOrigin(env.PUBLIC_ORIGIN),
    dataDir: resolve(env.DATA_DIR?.trim() || './data'),
    sessionTtlMs: intEnv(env, 'SESSION_TTL_MS', DAY_MS),
    trustProxy: env.TRUST_PROXY === '1' || env.TRUST_PROXY === 'true',
    // Empty list: any desktop that proves its key may use the gateway.
    allowedHostFingerprints: new Set(listEnv(env, 'ALLOWED_HOST_FINGERPRINTS')),
    apns,
    defaultTopic,
    // A blob may only name these topics, so a registered token cannot aim the
    // team-wide APNs key at some other app of the same team.
    allowedTopics: new Set(allowedTopics.length > 0 ? allowedTopics : [defaultTopic]),
    // Test hook: send every APNs request to this origin instead of Apple.
    apnsHostOverride: env.APNS_HOST_OVERRIDE?.trim() || null,
    logLevel: env.LOG_LEVEL?.trim() || 'info'
  }
}
