// Cleartext HTTP/2 stand-in for api.push.apple.com, recording every request.
import { createServer } from 'node:http2'
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
export async function startFakeApns(port, respond = () => undefined) {
  const requests = []
  const server = createServer()
  const sessions = new Set()
  server.on('session', (session) => {
    sessions.add(session)
    session.on('close', () => sessions.delete(session))
  })
  server.on('stream', (stream, headers) => {
    const chunks = []
    stream.on('data', (chunk) => chunks.push(chunk))
    stream.on('end', () => {
      const request = {
        path: headers[':path'],
        authority: headers[':authority'],
        headers: { ...headers },
        body: JSON.parse(Buffer.concat(chunks).toString('utf8'))
      }
      requests.push(request)
      const reply = respond(request) ?? { status: 200 }
      stream.respond({ ':status': reply.status, 'apns-id': 'test-id' })
      stream.end(reply.body ? JSON.stringify(reply.body) : undefined)
    })
  })
  await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve))
  return {
    requests,
    origin: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise((resolve) => {
        server.close(() => resolve())
        // Drop the gateway's idle HTTP/2 session too.
        for (const session of sessions) session.destroy()
      })
  }
}
