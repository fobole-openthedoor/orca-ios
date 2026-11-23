// Runs the official desktop's own TypeScript PushGatewayClient (copied read-only
// from the Orca repo into a temp dir) against this gateway and a fake APNs.
//
// The TS is compiled on load with esbuild (a devDependency): the desktop code
// uses parameter properties, which Node's built-in type stripping rejects.
// Skipped when the Orca checkout is missing or Node lacks module.registerHooks.
// ORCA_REPO overrides the checkout location (default: ../../orca from here).
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { startHarness } from './helpers/harness.js'
import { encodeDeviceTokenBlob } from '../src/token-blob.js'

const here = dirname(fileURLToPath(import.meta.url))
const gatewayRoot = resolve(here, '..')
const orcaRepo = resolve(process.env.ORCA_REPO ?? join(gatewayRoot, '../../orca'))
const ENTRY = 'src/main/runtime/push/push-gateway-client.ts'
const GATEWAY_PORT = 18441
const APNS_PORT = 18442

const [major, minor] = process.versions.node.split('.').map(Number)
const nodeCanRun = major > 22 || (major === 22 && minor >= 15) // module.registerHooks
const skip = !existsSync(join(orcaRepo, ENTRY))
  ? `Orca checkout not found at ${orcaRepo}`
  : !nodeCanRun
    ? 'needs Node >= 22.15 for module.registerHooks'
    : false

/** Copies the entry file and every runtime (non `import type`) relative import it reaches. */
function copyClosure(repo, entry, out) {
  const seen = new Set()
  const queue = [entry]
  while (queue.length) {
    const rel = queue.pop()
    if (seen.has(rel)) continue
    seen.add(rel)
    const source = readFileSync(join(repo, rel), 'utf8')
    mkdirSync(dirname(join(out, rel)), { recursive: true })
    copyFileSync(join(repo, rel), join(out, rel))
    const importRe = /^\s*(import|export)\s+(type\s+)?[^'";]*?from\s+['"](\.{1,2}\/[^'"]+)['"]/gm
    for (const match of source.matchAll(importRe)) {
      if (match[2]) continue // type-only, erased at runtime
      const target = resolve(dirname(join(repo, rel)), match[3])
      const candidates = [`${target}.ts`, join(target, 'index.ts'), target]
      const found = candidates.find((candidate) => existsSync(candidate) && candidate.endsWith('.ts'))
      if (!found) throw new Error(`cannot resolve ${match[3]} from ${rel}`)
      queue.push(relative(repo, found))
    }
  }
  return [...seen]
}

const HOOKS = `
import { createRequire, registerHooks } from 'node:module'
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
const depsParent = process.env.DEPS_PARENT_URL
const esbuild = createRequire(depsParent)('esbuild')
registerHooks({
  load(url, context, nextLoad) {
    if (url.startsWith('file:') && url.endsWith('.ts')) {
      const source = readFileSync(fileURLToPath(url), 'utf8')
      const { code } = esbuild.transformSync(source, { loader: 'ts', format: 'esm', target: 'node20', sourcefile: url })
      return { format: 'module', source: code, shortCircuit: true }
    }
    return nextLoad(url, context)
  },
  resolve(specifier, context, nextResolve) {
    if (specifier === 'zod' || specifier === 'tweetnacl') {
      return nextResolve(specifier, { ...context, parentURL: depsParent })
    }
    if ((specifier.startsWith('./') || specifier.startsWith('../')) && context.parentURL?.startsWith('file:')) {
      const base = new URL(specifier, context.parentURL)
      const path = fileURLToPath(base)
      for (const candidate of [path + '.ts', path + '/index.ts']) {
        if (existsSync(candidate)) return nextResolve(pathToFileURL(candidate).href, context)
      }
    }
    return nextResolve(specifier, context)
  }
})
`

const DRIVER = `
import nacl from 'tweetnacl'
import { PushGatewayClient } from './src/main/runtime/push/push-gateway-client.ts'
import { deriveRelayHostId } from './src/main/runtime/mobile-cloud-relay/director/relay-http-client.ts'

const input = JSON.parse(process.env.DRIVER_INPUT)
const keys = nacl.box.keyPair()
const keypair = { publicKey: keys.publicKey, secretKey: keys.secretKey, publicKeyB64: Buffer.from(keys.publicKey).toString('base64') }
const client = new PushGatewayClient({ gatewayUrl: input.gatewayUrl, keypair })
const out = { hostFingerprint: deriveRelayHostId(keys.publicKey) }
out.register = await client.registerDevice({ deviceId: 'phone-1', platform: 'ios', token: input.token, apnsEnvironment: 'sandbox' })
const base = { notificationSeq: 1, notificationEpoch: 'e1', source: 'agent-task-complete', title: 'repo / wt', body: 'Agent needs input', worktreeId: 'wt-1', paneKey: 'p1', notificationId: 'n1', expiresAt: Date.now() + 300000, sound: true }
out.sendAlert = await client.send({ registrationIds: [out.register.registrationId], notification: { ...base, agentState: 'needs-input' } })
out.sendBadge = await client.send({ registrationIds: [out.register.registrationId], notification: { ...base, kind: 'badge', badge: 4, agentState: null } })
out.sendDismiss = await client.send({ registrationIds: [out.register.registrationId], notification: { ...base, kind: 'dismiss', agentState: null } })
out.sendUnknown = await client.send({ registrationIds: ['not-mine'], notification: { ...base, agentState: null } })
out.deleted = await client.deleteDevice(out.register.registrationId)
out.deletedAgain = await client.deleteDevice(out.register.registrationId)
out.skew = await client.currentClockSkewMs()
console.log(JSON.stringify(out))
`

let h
let work
before(async () => {
  if (skip) return
  h = await startHarness({ gatewayPort: GATEWAY_PORT, apnsPort: APNS_PORT })
  work = mkdtempSync(join(tmpdir(), 'orca-desktop-interop-'))
})
after(async () => {
  await h?.close()
  if (work) rmSync(work, { recursive: true, force: true })
})

test('official desktop PushGatewayClient signs in, registers, sends and deletes', { skip }, async () => {
  const files = copyClosure(orcaRepo, ENTRY, work)
  assert.ok(files.includes('src/main/runtime/push/push-host-proof.ts'))
  assert.ok(files.includes('src/main/runtime/hosts/identity/host-challenge-envelope.ts'))
  writeFileSync(join(work, 'package.json'), '{"type":"module"}\n')
  writeFileSync(join(work, 'hooks.mjs'), HOOKS)
  writeFileSync(join(work, 'driver.mjs'), DRIVER)

  const token = encodeDeviceTokenBlob({ d: 'ab'.repeat(32), t: 'com.thm.orcaios', h: 'Mac', k: 'mac-1', s: 'cd'.repeat(40) })
  const args = [
    '--no-warnings',
    '--import',
    pathToFileURL(join(work, 'hooks.mjs')).href,
    join(work, 'driver.mjs')
  ]
  const stdout = await new Promise((resolvePromise, reject) => {
    execFile(
      process.execPath,
      args,
      {
        cwd: work,
        timeout: 60_000,
        env: {
          ...process.env,
          DEPS_PARENT_URL: pathToFileURL(join(gatewayRoot, 'package.json')).href,
          DRIVER_INPUT: JSON.stringify({ gatewayUrl: h.origin, token })
        }
      },
      (error, out, err) => (error ? reject(new Error(`${error.message}\n${err}`)) : resolvePromise(out))
    )
  })
  const out = JSON.parse(stdout.trim().split('\n').pop())
  const registrationId = out.register.registrationId
  assert.equal(out.register.ok, true)
  assert.deepEqual(out.sendAlert, { ok: true, results: [{ registrationId, status: 'queued' }] })
  assert.deepEqual(out.sendBadge, { ok: true, results: [{ registrationId, status: 'queued' }] })
  assert.deepEqual(out.sendDismiss, { ok: true, results: [{ registrationId, status: 'queued' }] })
  assert.deepEqual(out.sendUnknown, { ok: true, results: [{ registrationId: 'not-mine', status: 'error' }] })
  assert.equal(out.deleted, true)
  assert.equal(out.deletedAgain, true, '404 counts as deleted for the desktop')
  assert.equal(out.skew, null)

  const paths = h.fakeApns.requests.map((request) => `${request.headers['apns-push-type']} ${request.path}`)
  assert.deepEqual(paths.sort(), [
    `alert /3/device/${'ab'.repeat(32)}`,
    `alert /3/device/${'ab'.repeat(32)}`
  ])
  // Exactly one session for the whole run: the client reused its token.
  assert.equal(Object.keys(h.gateway.store.state.sessions).length, 1)
  assert.equal(Object.values(h.gateway.store.state.sessions)[0].hostFingerprint, out.hostFingerprint)
})
