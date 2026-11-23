// Stand-in for api.push.apple.com: Miniflare hands every outbound fetch of the
// Worker to `handler`, which records it and answers like APNs would.
import { generateKeyPairSync, verify } from 'node:crypto'

export function createApnsKey() {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
  return { pem: privateKey.export({ type: 'pkcs8', format: 'pem' }), publicKey }
}

/** Verifies an ES256 provider JWT against the test key. */
export function verifyProviderJwt(jwt, publicKey) {
  const [header, payload, signature] = jwt.split('.')
  const ok = verify(
    'sha256',
    Buffer.from(`${header}.${payload}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    Buffer.from(signature, 'base64url')
  )
  return {
    ok,
    header: JSON.parse(Buffer.from(header, 'base64url').toString()),
    payload: JSON.parse(Buffer.from(payload, 'base64url').toString())
  }
}

/**
 * @param {(req: {path, headers, body}) => {status: number, body?: object} | undefined} respond
 */
export function createFakeApns(respond = () => undefined) {
  const requests = []
  return {
    requests,
    async handler(request) {
      const url = new URL(request.url)
      const recorded = {
        path: url.pathname,
        authority: url.host,
        method: request.method,
        headers: Object.fromEntries(request.headers),
        body: JSON.parse(await request.text())
      }
      requests.push(recorded)
      const reply = respond(recorded) ?? { status: 200 }
      return new Response(reply.body ? JSON.stringify(reply.body) : null, {
        status: reply.status,
        headers: { 'apns-id': 'test-id' }
      })
    }
  }
}
