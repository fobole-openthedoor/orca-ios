// HTTP routes of the push gateway (protocol v1, as spoken by the Orca desktop).
import { createServer } from 'node:http'
import { ApnsClient, Http2Transport } from './apns.js'
import { ChallengeStore } from './handshake.js'
import { Delivery } from './delivery.js'
import { GatewayStore } from './store.js'
import { parseDeviceToken } from './token-blob.js'
import { parseChallengeRequest, parseRegisterRequest, parseSendRequest, parseSessionRequest } from './validate.js'

const MAX_BODY_BYTES = 16 * 1024
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

/** Fixed one-minute windows per key; enough to stop a loop from burning keys and disk. */
class MinuteLimiter {
  constructor(capacity, now) {
    this.capacity = capacity
    this.now = now
    this.windows = new Map()
  }

  allow(key) {
    const minute = Math.floor(this.now() / 60_000)
    const entry = this.windows.get(key)
    if (!entry || entry.minute !== minute) {
      if (this.windows.size > 10_000) this.windows.clear()
      this.windows.set(key, { minute, count: 1 })
      return true
    }
    entry.count += 1
    return entry.count <= this.capacity
  }
}

class HttpError extends Error {
  constructor(status, code) {
    super(code)
    this.status = status
    this.code = code
  }
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    const declared = Number(request.headers['content-length'] ?? 0)
    if (declared > MAX_BODY_BYTES) {
      reject(new HttpError(413, 'request_too_large'))
      request.resume()
      return
    }
    const chunks = []
    let size = 0
    request.on('data', (chunk) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        // Drain without buffering so the 413 can still be written.
        chunks.length = 0
        reject(new HttpError(413, 'request_too_large'))
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')))
      } catch {
        reject(new HttpError(400, 'invalid_request'))
      }
    })
    request.on('error', reject)
  })
}

function sendJson(response, status, body) {
  const payload = JSON.stringify(body)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store'
  })
  response.end(payload)
}

function readBearer(header) {
  if (typeof header !== 'string') return null
  const [scheme, ...rest] = header.split(' ')
  const token = rest.join(' ').trim()
  return scheme?.toLowerCase() === 'bearer' && token ? token : null
}

function clientIp(request, trustProxy) {
  if (trustProxy) {
    const cf = request.headers['cf-connecting-ip']
    if (typeof cf === 'string' && cf) return cf.trim()
    const forwarded = request.headers['x-forwarded-for']
    if (typeof forwarded === 'string' && forwarded) return forwarded.split(',')[0].trim()
  }
  return request.socket.remoteAddress ?? 'unknown'
}

export function createGateway(config, options = {}) {
  const now = options.now ?? Date.now
  const log = options.log ?? createLogger(config.logLevel)
  const store = new GatewayStore({ dataDir: config.dataDir, sessionTtlMs: config.sessionTtlMs, now, log })
  const challenges = new ChallengeStore({ gatewayOrigin: config.publicOrigin, now })
  const transport = options.transport ?? new Http2Transport({ hostOverride: config.apnsHostOverride })
  const apns = new ApnsClient({ credentials: config.apns, transport, now, log })
  const delivery = new Delivery({ store, apns, now, log })
  const unauthenticated = new MinuteLimiter(UNAUTHENTICATED_PER_MINUTE, now)
  const blobOptions = { defaultTopic: config.defaultTopic, allowedTopics: config.allowedTopics }

  function authenticate(request) {
    const token = readBearer(request.headers.authorization)
    const session = token ? store.resolveSession(token) : null
    if (!session) throw new HttpError(401, 'invalid_token')
    return session.hostFingerprint
  }

  async function route(request, response) {
    const url = new URL(request.url ?? '/', 'http://gateway.invalid')
    const { pathname } = url
    const method = request.method ?? 'GET'

    if (method === 'GET' && pathname === '/health') {
      return sendJson(response, 200, { ok: true, pushProtocol: 1, apnsConfigured: apns.configured })
    }

    if (method === 'POST' && (pathname === '/v1/host/challenge' || pathname === '/v1/host/session')) {
      if (!unauthenticated.allow(clientIp(request, config.trustProxy))) {
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
        challenges.pending.delete(issued.response.challengeId)
        log('warn', 'host_not_allowed', { hostFingerprint: issued.hostFingerprint })
        throw new HttpError(403, 'host_not_allowed')
      }
      return sendJson(response, 200, issued.response)
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
      return sendJson(response, 200, session)
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
      return sendJson(response, 200, { registrationId: result.registrationId })
    }

    if (pathname === '/v1/devices' && method === 'GET') {
      const hostFingerprint = authenticate(request)
      return sendJson(response, 200, {
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
      response.writeHead(204)
      return response.end()
    }

    if (pathname === '/v1/send' && method === 'POST') {
      const hostFingerprint = authenticate(request)
      const body = parseSendRequest(await readJson(request))
      if (!body.ok) {
        log('warn', 'send_refused', { reason: body.reason })
        throw new HttpError(400, 'invalid_request')
      }
      const results = await delivery.send(hostFingerprint, body.value.registrationIds, body.value.notification)
      return sendJson(response, 200, { results })
    }

    throw new HttpError(404, 'not_found')
  }

  const server = createServer((request, response) => {
    route(request, response).catch((error) => {
      if (response.headersSent) {
        response.destroy()
        return
      }
      if (error instanceof HttpError) {
        sendJson(response, error.status, { error: error.code })
        return
      }
      log('error', 'request_failed', { error: error?.name ?? 'unknown', message: error?.message })
      sendJson(response, 500, { error: 'internal' })
    })
  })
  server.requestTimeout = 30_000
  server.headersTimeout = 15_000

  return {
    server,
    store,
    challenges,
    apns,
    close: () =>
      new Promise((resolve) => {
        transport.close?.()
        server.close(() => resolve())
        server.closeAllConnections?.()
      })
  }
}
