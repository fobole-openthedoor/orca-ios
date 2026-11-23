// HTTP routes of the push gateway (protocol v1, as spoken by the Orca desktop),
// ported from the Node gateway's app.js. Runs inside the single Durable Object,
// so the handshake, sessions and registrations all see one consistent state.
import { ApnsClient, FetchTransport } from './apns.js'
import { ChallengeStore } from './handshake.js'
import { Delivery } from './delivery.js'
import { GatewayStore, SqlChallengeTable, SqlMinuteLimiter, SqlTokenCache } from './store.js'
import { parseDeviceToken } from './token-blob.js'
import { parseChallengeRequest, parseRegisterRequest, parseSendRequest, parseSessionRequest } from './validate.js'

export const MAX_BODY_BYTES = 16 * 1024
const UNAUTHENTICATED_PER_MINUTE = 60

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 }

export function createLogger(level = 'info') {
  const threshold = LEVELS[level] ?? LEVELS.info
  return (lvl, event, fields = {}) => {
    if ((LEVELS[lvl] ?? LEVELS.info) < threshold) return
    const line = JSON.stringify({ t: new Date().toISOString(), level: lvl, event, ...fields })
    if (lvl === 'warn' || lvl === 'error') console.warn(line)
    else console.log(line)
  }
}

export class HttpError extends Error {
  constructor(status, code) {
    super(code)
    this.status = status
    this.code = code
  }
}

/** Reads at most MAX_BODY_BYTES; anything longer is a 413 without buffering the rest. */
async function readJson(request) {
  const declared = Number(request.headers.get('content-length') ?? 0)
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, 'request_too_large')
  const chunks = []
  let size = 0
  if (request.body) {
    const reader = request.body.getReader()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > MAX_BODY_BYTES) {
        reader.cancel().catch(() => {})
        throw new HttpError(413, 'request_too_large')
      }
      chunks.push(value)
    }
  }
  const bytes = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes))
  } catch {
    throw new HttpError(400, 'invalid_request')
  }
}

export function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  })
}

function readBearer(header) {
  if (typeof header !== 'string') return null
  const [scheme, ...rest] = header.split(' ')
  const token = rest.join(' ').trim()
  return scheme?.toLowerCase() === 'bearer' && token ? token : null
}

/** Cloudflare sets CF-Connecting-IP on every request and strips any the client sent. */
function clientIp(request) {
  return request.headers.get('cf-connecting-ip')?.trim() || 'unknown'
}

/**
 * @param {object} config from loadConfig
 * @param {{sql: SqlStorage, transactionSync?: Function, now?: () => number, log?: Function, fetcher?: Function}} options
 */
export function createGateway(config, options) {
  const now = options.now ?? Date.now
  const log = options.log ?? createLogger(config.logLevel)
  const { sql } = options
  const store = new GatewayStore({ sql, transactionSync: options.transactionSync, sessionTtlMs: config.sessionTtlMs, now, log })
  const challenges = new ChallengeStore({ gatewayOrigin: config.publicOrigin, now, table: new SqlChallengeTable(sql) })
  const transport = new FetchTransport({ hostOverride: config.apnsHostOverride, fetcher: options.fetcher })
  const apns = new ApnsClient({ credentials: config.apns, transport, now, tokenCache: (keyId) => new SqlTokenCache(sql, keyId), log })
  const delivery = new Delivery({ store, apns, now, log })
  const unauthenticated = new SqlMinuteLimiter(sql, UNAUTHENTICATED_PER_MINUTE, now)
  const blobOptions = { defaultTopic: config.defaultTopic, allowedTopics: config.allowedTopics }

  function authenticate(request) {
    const token = readBearer(request.headers.get('authorization') ?? undefined)
    const session = token ? store.resolveSession(token) : null
    if (!session) throw new HttpError(401, 'invalid_token')
    return session.hostFingerprint
  }

  async function route(request) {
    const url = new URL(request.url)
    const { pathname } = url
    const method = request.method

    if (method === 'GET' && pathname === '/health') {
      return jsonResponse(200, { ok: true, pushProtocol: 1, apnsConfigured: apns.configured })
    }

    if (method === 'POST' && (pathname === '/v1/host/challenge' || pathname === '/v1/host/session')) {
      if (!unauthenticated.allow(clientIp(request))) {
        throw new HttpError(429, 'rate_limited')
      }
    }

    if (method === 'POST' && pathname === '/v1/host/challenge') {
      const body = parseChallengeRequest(await readJson(request))
      if (!body) throw new HttpError(400, 'invalid_request')
      const issued = challenges.issue(body.hostPublicKeyB64)
      if (!issued) throw new HttpError(400, 'invalid_request')
      if (issued.busy) throw new HttpError(503, 'busy')
      if (config.allowedHostFingerprints.size > 0 && !config.allowedHostFingerprints.has(issued.hostFingerprint)) {
        challenges.discard(issued.response.challengeId)
        log('warn', 'host_not_allowed', { hostFingerprint: issued.hostFingerprint })
        throw new HttpError(403, 'host_not_allowed')
      }
      return jsonResponse(200, issued.response)
    }

    if (method === 'POST' && pathname === '/v1/host/session') {
      const body = parseSessionRequest(await readJson(request))
      if (!body) throw new HttpError(400, 'invalid_request')
      const verified = challenges.verify(body.challengeId, body.proofB64)
      if (!verified.ok) {
        log('warn', 'session_refused', { reason: verified.reason })
        throw new HttpError(401, verified.reason === 'unknown_challenge' ? 'invalid_challenge' : 'invalid_proof')
      }
      const session = store.createSession(verified.hostFingerprint)
      log('info', 'host_signed_in', { hostFingerprint: verified.hostFingerprint })
      return jsonResponse(200, session)
    }

    if (pathname === '/v1/devices' && method === 'POST') {
      const hostFingerprint = authenticate(request)
      const body = parseRegisterRequest(await readJson(request))
      if (!body.ok) {
        log('warn', 'register_refused', { reason: body.reason })
        throw new HttpError(400, 'invalid_request')
      }
      const parsed = parseDeviceToken(body.value.token, blobOptions)
      if (!parsed.ok) {
        log('warn', 'register_refused', { reason: parsed.reason })
        throw new HttpError(400, 'invalid_request')
      }
      const result = store.upsertRegistration({
        hostFingerprint,
        deviceId: body.value.deviceId,
        apnsEnvironment: body.value.apnsEnvironment,
        token: body.value.token,
        device: parsed.device
      })
      if (!result.ok) throw new HttpError(409, 'too_many_devices')
      log('info', 'device_registered', {
        hostFingerprint,
        registration: result.registrationId.slice(0, 8),
        environment: body.value.apnsEnvironment,
        liveActivityTokens: Object.keys(parsed.device.activityTokens).length,
        pushToStart: Boolean(parsed.device.pushToStartToken)
      })
      return jsonResponse(200, { registrationId: result.registrationId })
    }

    if (pathname === '/v1/devices' && method === 'GET') {
      const hostFingerprint = authenticate(request)
      return jsonResponse(200, {
        devices: store.listOwned(hostFingerprint).map((entry) => ({
          registrationId: entry.registrationId,
          deviceId: entry.deviceId,
          platform: 'ios',
          dead: false
        }))
      })
    }

    const deviceMatch = /^\/v1\/devices\/([^/]+)$/.exec(pathname)
    if (deviceMatch && method === 'DELETE') {
      const hostFingerprint = authenticate(request)
      let registrationId
      try {
        registrationId = decodeURIComponent(deviceMatch[1])
      } catch {
        throw new HttpError(400, 'invalid_request')
      }
      if (!store.findOwned(hostFingerprint, registrationId)) throw new HttpError(404, 'not_found')
      store.deleteRegistration(registrationId)
      log('info', 'device_deleted', { hostFingerprint, registration: registrationId.slice(0, 8) })
      return new Response(null, { status: 204 })
    }

    if (pathname === '/v1/send' && method === 'POST') {
      const hostFingerprint = authenticate(request)
      const body = parseSendRequest(await readJson(request))
      if (!body.ok) {
        log('warn', 'send_refused', { reason: body.reason })
        throw new HttpError(400, 'invalid_request')
      }
      const results = await delivery.send(hostFingerprint, body.value.registrationIds, body.value.notification)
      return jsonResponse(200, { results })
    }

    throw new HttpError(404, 'not_found')
  }

  async function handle(request) {
    try {
      return await route(request)
    } catch (error) {
      if (error instanceof HttpError) return jsonResponse(error.status, { error: error.code })
      log('error', 'request_failed', { error: error?.name ?? 'unknown', message: error?.message })
      return jsonResponse(500, { error: 'internal' })
    }
  }

  return { handle, store, challenges, apns }
}
