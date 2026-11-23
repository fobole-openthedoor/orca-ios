// Token-based APNs from a Worker: the provider JWT is signed with WebCrypto
// (ES256) and every push is a fetch() to api[.sandbox].push.apple.com, which
// Cloudflare speaks HTTP/2 to. One token is shared by the whole gateway and kept
// in Durable Object storage, so an evicted and restarted object reuses it
// instead of minting a new one (Apple throttles refreshes).

export const APNS_HOSTS = {
  production: 'api.push.apple.com',
  sandbox: 'api.sandbox.push.apple.com'
}

// Apple rejects provider tokens older than an hour and throttles refreshes
// more often than every 20 minutes.
const TOKEN_ROTATION_MS = 50 * 60 * 1000
const REQUEST_TIMEOUT_MS = 10_000

const encoder = new TextEncoder()

function base64Url(bytes) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function base64UrlJson(value) {
  return base64Url(encoder.encode(JSON.stringify(value)))
}

/** PKCS#8 PEM (the .p8 file Apple hands out) to DER bytes. */
export function pemToDer(pem) {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s+/g, '')
  const binary = atob(body)
  const der = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) der[i] = binary.charCodeAt(i)
  return der
}

/** No-op cache for callers without storage (tests of the signer). */
export const memoryCache = () => {
  let entry = null
  return { load: () => entry, save: (value) => (entry = value), clear: () => (entry = null) }
}

export class ApnsProviderToken {
  constructor({ keyPem, keyId, teamId }, { now = Date.now, cache = memoryCache() } = {}) {
    this.keyPem = keyPem
    this.keyId = keyId
    this.teamId = teamId
    this.now = now
    this.cache = cache
    this.keyPromise = null
  }

  privateKey() {
    this.keyPromise ??= crypto.subtle
      .importKey('pkcs8', pemToDer(this.keyPem), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
      .catch((error) => {
        this.keyPromise = null
        throw new Error(`apns_key_unreadable: ${error?.message ?? error}`)
      })
    return this.keyPromise
  }

  async value() {
    const nowMs = this.now()
    const cached = this.cache.load()
    if (cached && cached.issuedAtMs <= nowMs && nowMs - cached.issuedAtMs < TOKEN_ROTATION_MS && cached.keyId === this.keyId) {
      return cached.token
    }
    const signingInput = `${base64UrlJson({ alg: 'ES256', kid: this.keyId })}.${base64UrlJson({
      iss: this.teamId,
      iat: Math.floor(nowMs / 1000)
    })}`
    // WebCrypto ECDSA already returns raw r||s, the form JWS wants.
    const signature = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      await this.privateKey(),
      encoder.encode(signingInput)
    )
    const token = `${signingInput}.${base64Url(new Uint8Array(signature))}`
    this.cache.save({ token, issuedAtMs: nowMs, keyId: this.keyId })
    return token
  }

  /** Apple answered ExpiredProviderToken / InvalidProviderToken: mint a new one next time. */
  invalidate() {
    this.cache.clear()
  }
}

/** fetch()-based transport. `hostOverride` (tests) replaces https://<apns host>. */
export class FetchTransport {
  constructor({ hostOverride = null, fetcher = (...args) => fetch(...args) } = {}) {
    this.override = hostOverride ? new URL(hostOverride).origin : null
    this.fetcher = fetcher
  }

  /** @returns {Promise<{status: number, body: string, headers: Headers}>} */
  async request({ host, path, headers, body }) {
    const origin = this.override ?? `https://${host}`
    let response
    try {
      response = await this.fetcher(`${origin}${path}`, {
        method: 'POST',
        headers: { ...headers, 'content-type': 'application/json' },
        body,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
      })
    } catch (error) {
      if (error?.name === 'TimeoutError' || error?.name === 'AbortError') throw new Error('apns_timeout')
      throw error
    }
    return { status: response.status, body: await response.text(), headers: response.headers }
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
  /**
   * @param {{credentials: {sandbox: object|null, production: object|null} | null,
   *   tokenCache?: (keyId: string) => {load, save, clear}}} options
   * One provider token per key: environments that share a key share its token.
   */
  constructor({ credentials, transport, now = Date.now, tokenCache, log = () => {} }) {
    const byKeyId = new Map()
    const tokenFor = (creds) => {
      if (!creds) return null
      if (!byKeyId.has(creds.keyId)) {
        byKeyId.set(creds.keyId, new ApnsProviderToken(creds, { now, cache: tokenCache?.(creds.keyId) }))
      }
      return byKeyId.get(creds.keyId)
    }
    this.providerTokens = {
      sandbox: tokenFor(credentials?.sandbox),
      production: tokenFor(credentials?.production)
    }
    this.transport = transport
    this.log = log
  }

  /** True when at least one environment can send. */
  get configured() {
    return this.providerTokens.sandbox !== null || this.providerTokens.production !== null
  }

  /**
   * @param {{environment: 'sandbox'|'production', deviceToken: string, headers: object, payload: object}} push
   * @returns {Promise<{outcome: 'sent'|'dead'|'rate_limited'|'error', status?: number, reason: string}>}
   */
  async send({ environment, deviceToken, headers, payload }) {
    const env = environment === 'sandbox' ? 'sandbox' : 'production'
    const providerToken = this.providerTokens[env]
    if (!providerToken) return { outcome: 'error', reason: `apns_${env}_not_configured` }
    const host = APNS_HOSTS[env]
    let response
    try {
      response = await this.transport.request({
        host,
        path: `/3/device/${deviceToken}`,
        headers: { authorization: `bearer ${await providerToken.value()}`, ...headers },
        body: JSON.stringify(payload)
      })
    } catch (error) {
      return { outcome: 'error', reason: error?.message || 'transport_failed' }
    }
    if (response.status === 200) return { outcome: 'sent', status: 200, reason: 'ok' }
    const reason = readReason(response.body)
    if (response.status === 403 && PROVIDER_TOKEN_REASONS.has(reason)) providerToken.invalidate()
    if (response.status === 410) return { outcome: 'dead', status: 410, reason }
    if (response.status === 400 && DEAD_400_REASONS.has(reason)) {
      return { outcome: 'dead', status: 400, reason }
    }
    if (response.status === 429) return { outcome: 'rate_limited', status: 429, reason }
    return { outcome: 'error', status: response.status, reason }
  }
}
