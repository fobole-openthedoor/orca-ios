// Worker entry. Every /v1/* request goes to one SQLite-backed Durable Object
// ("global"), which plays the role of the Node gateway's single process: it
// owns the challenges, sessions, registrations, badges and rate limits.
// /health is answered here without waking the object.
import { DurableObject } from 'cloudflare:workers'
import { loadConfig } from './config.js'
import { createGateway, createLogger, jsonResponse } from './gateway.js'

const GATEWAY_OBJECT_NAME = 'global'

export class GatewayDurableObject extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env)
    this.gateway = null
    this.configError = null
    try {
      const config = loadConfig(env)
      this.gateway = createGateway(config, {
        sql: ctx.storage.sql,
        transactionSync: (fn) => ctx.storage.transactionSync(fn)
      })
      for (const environment of ['sandbox', 'production']) {
        if (config.apns?.[environment]) continue
        createLogger(config.logLevel)('warn', 'apns_not_configured', {
          environment,
          hint: `set APNS_${environment.toUpperCase()}_KEY (secret) + APNS_${environment.toUpperCase()}_KEY_ID, or APNS_KEY + APNS_KEY_ID for both, and APNS_TEAM_ID; ${environment} sends report "error" until then`
        })
      }
    } catch (error) {
      this.configError = error
    }
  }

  async fetch(request) {
    if (!this.gateway) {
      console.error(JSON.stringify({ level: 'error', event: 'configuration_error', message: this.configError?.message }))
      return jsonResponse(500, { error: 'internal' })
    }
    return await this.gateway.handle(request)
  }

  /** Read-only view for tests and `wrangler` debugging; reachable only through the binding. */
  snapshot() {
    if (!this.gateway) return null
    const { store } = this.gateway
    return {
      sessions: store.listSessions(),
      registrations: store.rows(`SELECT registration_id FROM registrations ORDER BY rowid`).map((row) =>
        store.getRegistration(row.registration_id)
      )
    }
  }
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url)
    if (pathname.startsWith('/v1/')) {
      const stub = env.GATEWAY.get(env.GATEWAY.idFromName(GATEWAY_OBJECT_NAME))
      return await stub.fetch(request)
    }
    if (request.method === 'GET' && pathname === '/health') {
      let config
      try {
        config = loadConfig(env)
      } catch (error) {
        console.error(JSON.stringify({ level: 'error', event: 'configuration_error', message: error.message }))
        return jsonResponse(500, { error: 'internal' })
      }
      return jsonResponse(200, { ok: true, pushProtocol: 1, apnsConfigured: config.apns !== null })
    }
    return jsonResponse(404, { error: 'not_found' })
  }
}
