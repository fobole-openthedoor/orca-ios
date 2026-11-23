// Token-based APNs over HTTP/2: one cached ES256 provider token, one HTTP/2
// session per APNs host, dropped and rebuilt on GOAWAY, error or close.
import { connect, constants } from 'node:http2'
import { createPrivateKey, sign } from 'node:crypto'

export const APNS_HOSTS = {
  production: 'api.push.apple.com',
  sandbox: 'api.sandbox.push.apple.com'
}

// Apple rejects provider tokens older than an hour and throttles refreshes
// more often than every 20 minutes.
const TOKEN_ROTATION_MS = 50 * 60 * 1000
const REQUEST_TIMEOUT_MS = 10_000

function base64UrlJson(value) {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url')
}

export class ApnsProviderToken {
  constructor({ keyPem, keyId, teamId }, now = Date.now) {
    this.privateKey = createPrivateKey(keyPem)
    this.keyId = keyId
    this.teamId = teamId
    this.now = now
    this.cached = null
  }

  value() {
    const nowMs = this.now()
    if (this.cached && nowMs - this.cached.issuedAtMs < TOKEN_ROTATION_MS) return this.cached.token
    const signingInput = `${base64UrlJson({ alg: 'ES256', kid: this.keyId })}.${base64UrlJson({
      iss: this.teamId,
      iat: Math.floor(nowMs / 1000)
    })}`
    // JWS wants raw r||s, not the DER that Node emits by default.
    const signature = sign('sha256', Buffer.from(signingInput), {
      key: this.privateKey,
      dsaEncoding: 'ieee-p1363'
    }).toString('base64url')
    this.cached = { token: `${signingInput}.${signature}`, issuedAtMs: nowMs }
    return this.cached.token
  }

  /** Apple answered ExpiredProviderToken / InvalidProviderToken: mint a new one next time. */
  invalidate() {
    this.cached = null
  }
}

export class Http2Transport {
  constructor({ hostOverride = null } = {}) {
    // e.g. "http://127.0.0.1:18443" for a local h2c stub in tests.
    this.override = hostOverride ? new URL(hostOverride) : null
    this.sessions = new Map()
  }

  sessionFor(host) {
    const existing = this.sessions.get(host)
    if (existing && !existing.closed && !existing.destroyed) return existing
    const target = this.override ? this.override.origin : `https://${host}`
    const session = connect(target)
    const forget = () => {
      if (this.sessions.get(host) === session) this.sessions.delete(host)
    }
    session.on('error', forget)
    session.on('close', forget)
    // After GOAWAY the session finishes in-flight streams but takes no new ones.
    session.on('goaway', () => {
      forget()
      session.close()
    })
    session.setTimeout(60 * 60 * 1000, () => session.close())
    this.sessions.set(host, session)
    return session
  }

  /** @returns {Promise<{status: number, body: string, headers: object}>} */
  request({ host, path, headers, body }) {
    return new Promise((resolve, reject) => {
      let stream
      try {
        stream = this.sessionFor(host).request({
          ...headers,
          [constants.HTTP2_HEADER_METHOD]: 'POST',
          [constants.HTTP2_HEADER_PATH]: path,
          [constants.HTTP2_HEADER_AUTHORITY]: this.override ? this.override.host : host,
          'content-type': 'application/json',
          'content-length': String(Buffer.byteLength(body))
        })
      } catch (error) {
        // Session died between the cache check and the request.
        this.sessions.delete(host)
        reject(error)
        return
      }
      let settled = false
      const settle = (fn) => {
        if (!settled) {
          settled = true
          fn()
        }
      }
      let status = 0
      let responseHeaders = {}
      const chunks = []
      stream.setTimeout(REQUEST_TIMEOUT_MS, () => stream.destroy(new Error('apns_timeout')))
      stream.on('response', (h) => {
        responseHeaders = h
        status = Number(h[constants.HTTP2_HEADER_STATUS] ?? 0)
      })
      stream.on('data', (chunk) => chunks.push(chunk))
      stream.on('error', (error) => settle(() => reject(error)))
      stream.on('end', () =>
        settle(() => resolve({ status, body: Buffer.concat(chunks).toString('utf8'), headers: responseHeaders }))
      )
      // A reset with NO_ERROR emits neither end nor error.
      stream.on('close', () => settle(() => reject(new Error('apns_stream_closed'))))
      stream.end(body)
    })
  }

  close() {
    for (const session of this.sessions.values()) session.close()
    this.sessions.clear()
  }
}

function readReason(body) {
  try {
    const parsed = JSON.parse(body)
    return typeof parsed?.reason === 'string' ? parsed.reason : 'unknown'
  } catch {
    return body ? 'unparseable' : 'none'
  }
}

const DEAD_400_REASONS = new Set(['BadDeviceToken', 'DeviceTokenNotForTopic'])
const PROVIDER_TOKEN_REASONS = new Set(['ExpiredProviderToken', 'InvalidProviderToken'])

export class ApnsClient {
  constructor({ credentials, transport, now = Date.now, log = () => {} }) {
    this.providerToken = credentials ? new ApnsProviderToken(credentials, now) : null
    this.transport = transport
    this.log = log
  }

  get configured() {
    return this.providerToken !== null
  }

  /**
   * @param {{environment: 'sandbox'|'production', deviceToken: string, headers: object, payload: object}} push
   * @returns {Promise<{outcome: 'sent'|'dead'|'rate_limited'|'error', status?: number, reason: string}>}
   */
  async send({ environment, deviceToken, headers, payload }) {
    if (!this.providerToken) return { outcome: 'error', reason: 'apns_not_configured' }
    const host = APNS_HOSTS[environment] ?? APNS_HOSTS.production
    let response
    try {
      response = await this.transport.request({
        host,
        path: `/3/device/${deviceToken}`,
        headers: { authorization: `bearer ${this.providerToken.value()}`, ...headers },
        body: JSON.stringify(payload)
      })
    } catch (error) {
      return { outcome: 'error', reason: error?.message || 'transport_failed' }
    }
    if (response.status === 200) return { outcome: 'sent', status: 200, reason: 'ok' }
    const reason = readReason(response.body)
    if (response.status === 403 && PROVIDER_TOKEN_REASONS.has(reason)) this.providerToken.invalidate()
    if (response.status === 410) return { outcome: 'dead', status: 410, reason }
    if (response.status === 400 && DEAD_400_REASONS.has(reason)) {
      return { outcome: 'dead', status: 400, reason }
    }
    if (response.status === 429) return { outcome: 'rate_limited', status: 429, reason }
    return { outcome: 'error', status: response.status, reason }
  }
}
