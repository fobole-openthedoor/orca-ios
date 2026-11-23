// Runs the built Worker bundle (dist/index.js, the exact output of
// `wrangler deploy --dry-run`) in Miniflare/workerd with the same Durable
// Object binding as wrangler.toml, plus a fake APNs behind the outbound fetch.
// Test ports: 18000-18999 only.
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { convertV4MiniflareOptions, Miniflare } from 'miniflare'
import { createApnsKey, createFakeApns } from './fake-apns.js'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const bundle = join(root, 'dist', 'index.js')
const FAKE_APNS_ORIGIN = 'http://fake-apns.invalid'

function wranglerSettings() {
  const toml = readFileSync(join(root, 'wrangler.toml'), 'utf8')
  const date = /^compatibility_date\s*=\s*"([^"]+)"/m.exec(toml)[1]
  const flags = JSON.parse(/^compatibility_flags\s*=\s*(\[[^\]]*\])/m.exec(toml)[1])
  return { date, flags }
}

export async function startHarness({ gatewayPort, respond, env = {} }) {
  if (!existsSync(bundle)) throw new Error('dist/index.js missing: run `npm run build` first')
  const apnsKey = createApnsKey()
  const fakeApns = createFakeApns(respond)
  const origin = `http://127.0.0.1:${gatewayPort}`
  const { date, flags } = wranglerSettings()
  // Miniflare 5 still accepts the classic single-worker options through this converter.
  const mf = new Miniflare(convertV4MiniflareOptions({
    host: '127.0.0.1',
    port: gatewayPort,
    modules: true,
    scriptPath: bundle,
    compatibilityDate: date,
    compatibilityFlags: flags,
    bindings: {
      PUBLIC_ORIGIN: origin,
      APNS_KEY: apnsKey.pem,
      APNS_KEY_ID: 'TESTKEY123',
      APNS_TEAM_ID: 'TEAM123456',
      APNS_DEFAULT_TOPIC: 'com.thm.orcaios',
      APNS_HOST_OVERRIDE: FAKE_APNS_ORIGIN,
      LOG_LEVEL: 'error',
      ...env
    },
    durableObjects: { GATEWAY: { className: 'GatewayDurableObject', useSQLite: true } },
    outboundService: (request) => fakeApns.handler(request)
  }))
  await mf.ready
  return {
    origin,
    mf,
    fakeApns,
    apnsKey,
    /** {sessions, registrations} straight from the Durable Object's SQLite tables. */
    async snapshot() {
      const ns = await mf.getDurableObjectNamespace('GATEWAY')
      return await ns.get(ns.idFromName('global')).snapshot()
    },
    async close() {
      await mf.dispose()
    }
  }
}
