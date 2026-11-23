// Reads gateway configuration from the Worker's vars and secrets. Same rules as
// the Node gateway: PUBLIC_ORIGIN must be a bare origin; missing APNs
// credentials degrade softly so the handshake works before a key exists.
// Node-only settings (HOST, PORT, DATA_DIR, APNS_KEY_PATH, TRUST_PROXY, ENV_FILE)
// do not apply: Cloudflare terminates TLS and always sets CF-Connecting-IP.

const DAY_MS = 24 * 60 * 60 * 1000

function str(env, name) {
  const raw = env[name]
  return typeof raw === 'string' ? raw : raw === undefined || raw === null ? undefined : String(raw)
}

function intEnv(env, name, fallback) {
  const raw = str(env, name)
  if (raw === undefined || raw.trim() === '') return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`)
  return value
}

function listEnv(env, name) {
  return (str(env, name) ?? '')
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

function readApnsKey(env, name) {
  const key = str(env, name)
  if (!key || !key.trim()) return null
  // Secrets pasted on one line often carry literal "\n" escapes.
  return key.includes('\\n') ? key.replace(/\\n/g, '\n') : key
}

function credentials(env, prefix, teamId) {
  const keyPem = readApnsKey(env, `${prefix}KEY`)
  const keyId = str(env, `${prefix}KEY_ID`)?.trim() || null
  return keyPem && keyId && teamId ? { keyPem, keyId, teamId } : null
}

/**
 * APNs credentials per environment. Topic-specific keys are limited to one
 * environment, so APNS_SANDBOX_KEY(+_ID) and APNS_PRODUCTION_KEY(+_ID) each
 * cover their own; APNS_KEY(+_ID) is the fallback for whichever has none.
 * Returns null when neither environment has a key.
 */
export function loadApnsCredentials(env) {
  const teamId = str(env, 'APNS_TEAM_ID')?.trim() || null
  const fallback = credentials(env, 'APNS_', teamId)
  const sandbox = credentials(env, 'APNS_SANDBOX_', teamId) ?? fallback
  const production = credentials(env, 'APNS_PRODUCTION_', teamId) ?? fallback
  return sandbox || production ? { sandbox, production } : null
}

export function loadConfig(env) {
  const apns = loadApnsCredentials(env)
  const defaultTopic = str(env, 'APNS_DEFAULT_TOPIC')?.trim() || 'com.thm.orcaios'
  const allowedTopics = listEnv(env, 'APNS_ALLOWED_TOPICS')
  return {
    publicOrigin: normalizePublicOrigin(str(env, 'PUBLIC_ORIGIN')),
    sessionTtlMs: intEnv(env, 'SESSION_TTL_MS', DAY_MS),
    // Empty list: any desktop that proves its key may use the gateway.
    allowedHostFingerprints: new Set(listEnv(env, 'ALLOWED_HOST_FINGERPRINTS')),
    apns,
    defaultTopic,
    // A blob may only name these topics, so a registered token cannot aim the
    // team-wide APNs key at some other app of the same team.
    allowedTopics: new Set(allowedTopics.length > 0 ? allowedTopics : [defaultTopic]),
    // Test hook: send every APNs request to this origin instead of Apple.
    apnsHostOverride: str(env, 'APNS_HOST_OVERRIDE')?.trim() || null,
    logLevel: str(env, 'LOG_LEVEL')?.trim() || 'info'
  }
}
