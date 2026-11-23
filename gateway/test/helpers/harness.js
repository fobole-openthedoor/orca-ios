// Starts a gateway plus fake APNs on fixed test ports (18000-18999 only).
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createGateway } from '../../src/app.js'
import { loadConfig } from '../../src/config.js'
import { createApnsKey, startFakeApns } from './fake-apns.js'

export async function startHarness({ gatewayPort, apnsPort, respond, env = {} }) {
  const apnsKey = createApnsKey()
  const fakeApns = await startFakeApns(apnsPort, respond)
  const dataDir = mkdtempSync(join(tmpdir(), 'orca-push-gateway-test-'))
  const publicOrigin = `http://127.0.0.1:${gatewayPort}`
  const config = loadConfig({
    PUBLIC_ORIGIN: publicOrigin,
    PORT: String(gatewayPort),
    HOST: '127.0.0.1',
    DATA_DIR: dataDir,
    APNS_KEY: apnsKey.pem,
    APNS_KEY_ID: 'TESTKEY123',
    APNS_TEAM_ID: 'TEAM123456',
    APNS_HOST_OVERRIDE: fakeApns.origin,
    LOG_LEVEL: 'error',
    ...env
  })
  const gateway = createGateway(config)
  await new Promise((resolve) => gateway.server.listen(gatewayPort, '127.0.0.1', resolve))
  return {
    origin: publicOrigin,
    config,
    gateway,
    fakeApns,
    apnsKey,
    dataDir,
    async close() {
      await gateway.close()
      await fakeApns.close()
      rmSync(dataDir, { recursive: true, force: true })
    }
  }
}
