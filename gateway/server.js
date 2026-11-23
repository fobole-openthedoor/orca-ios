#!/usr/bin/env node
// Entry point: node server.js (reads configuration from the environment).
import { existsSync } from 'node:fs'
import { loadConfig } from './src/config.js'
import { createGateway, createLogger } from './src/app.js'

// Optional .env next to the working directory; real environment variables win.
const envFile = process.env.ENV_FILE ?? '.env'
if (existsSync(envFile) && typeof process.loadEnvFile === 'function') process.loadEnvFile(envFile)

let config
try {
  config = loadConfig()
} catch (error) {
  console.error(`Configuration error: ${error.message}`)
  process.exit(1)
}

const log = createLogger(config.logLevel)
const gateway = createGateway(config, { log })

if (!config.apns) {
  log('warn', 'apns_not_configured', {
    hint: 'set APNS_KEY_PATH (or APNS_KEY), APNS_KEY_ID and APNS_TEAM_ID; sends will report "error" until then'
  })
}
if (!config.publicOrigin.startsWith('https://')) {
  log('warn', 'public_origin_not_https', {
    hint: 'packaged Orca builds only accept an https gateway; http works with dev builds on loopback only'
  })
}

gateway.server.listen(config.port, config.host, () => {
  log('info', 'listening', {
    address: `${config.host}:${config.port}`,
    publicOrigin: config.publicOrigin,
    dataDir: config.dataDir,
    topics: [...config.allowedTopics],
    apnsHostOverride: config.apnsHostOverride ?? undefined
  })
})

let stopping = false
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    if (stopping) process.exit(1)
    stopping = true
    log('info', 'stopping', { signal })
    gateway.close().then(() => process.exit(0))
    setTimeout(() => process.exit(0), 5_000).unref()
  })
}
