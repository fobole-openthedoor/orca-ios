// Host sessions and device registrations, persisted to one JSON file.
// Writes go to a temp file that is fsynced and renamed over the old one, so a
// crash leaves either the previous or the next state, never a torn file.
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeSync } from 'node:fs'
import { join } from 'node:path'

export const MAX_DEVICES_PER_HOST = 64
const STATE_VERSION = 1

function hashToken(token) {
  return createHash('sha256').update(token).digest('base64url')
}

function emptyState() {
  return { version: STATE_VERSION, sessions: {}, registrations: {}, badges: {} }
}

export class GatewayStore {
  constructor({ dataDir, sessionTtlMs, now = Date.now, log = () => {} }) {
    this.dataDir = dataDir
    this.file = join(dataDir, 'state.json')
    this.sessionTtlMs = sessionTtlMs
    this.now = now
    this.log = log
    mkdirSync(dataDir, { recursive: true, mode: 0o700 })
    this.state = this.load()
    this.pruneSessions()
  }

  load() {
    let raw
    try {
      raw = readFileSync(this.file, 'utf8')
    } catch (error) {
      if (error.code === 'ENOENT') return emptyState()
      throw error
    }
    const parsed = JSON.parse(raw)
    if (!parsed || parsed.version !== STATE_VERSION) {
      throw new Error(`Unsupported state file version in ${this.file}`)
    }
    return {
      ...emptyState(),
      ...parsed,
      sessions: parsed.sessions ?? {},
      registrations: parsed.registrations ?? {},
      badges: parsed.badges ?? {}
    }
  }

  persist() {
    const tmp = `${this.file}.${process.pid}.tmp`
    const fd = openSync(tmp, 'w', 0o600)
    try {
      writeSync(fd, JSON.stringify(this.state))
      fsyncSync(fd)
    } finally {
      closeSync(fd)
    }
    renameSync(tmp, this.file)
  }

  // ---- sessions ---------------------------------------------------------

  /** One live session per host: a new sign-in replaces the old token. */
  createSession(hostFingerprint) {
    const sessionToken = randomBytes(32).toString('base64url')
    const expiresAt = this.now() + this.sessionTtlMs
    for (const [hash, session] of Object.entries(this.state.sessions)) {
      if (session.hostFingerprint === hostFingerprint) delete this.state.sessions[hash]
    }
    this.pruneSessions()
    this.state.sessions[hashToken(sessionToken)] = { hostFingerprint, expiresAt }
    this.persist()
    return { sessionToken, expiresAt, hostFingerprint }
  }

  resolveSession(sessionToken) {
    const session = this.state.sessions[hashToken(sessionToken)]
    if (!session) return null
    if (this.now() > session.expiresAt) return null
    return session
  }

  pruneSessions() {
    const now = this.now()
    for (const [hash, session] of Object.entries(this.state.sessions)) {
      if (session.expiresAt < now) delete this.state.sessions[hash]
    }
  }

  // ---- registrations ----------------------------------------------------

  /**
   * Stable registrationId per (host, deviceId): the desktop keeps that id and
   * re-registers whenever the phone's token blob changes.
   */
  upsertRegistration({ hostFingerprint, deviceId, apnsEnvironment, token, device }) {
    const now = this.now()
    const existing = Object.values(this.state.registrations).find(
      (entry) => entry.hostFingerprint === hostFingerprint && entry.deviceId === deviceId
    )
    if (existing) {
      Object.assign(existing, { apnsEnvironment, token, device, updatedAt: now })
      this.persist()
      return { ok: true, registrationId: existing.registrationId }
    }
    const owned = Object.values(this.state.registrations).filter(
      (entry) => entry.hostFingerprint === hostFingerprint
    )
    if (owned.length >= MAX_DEVICES_PER_HOST) return { ok: false, reason: 'too_many_devices' }
    const registrationId = randomUUID()
    this.state.registrations[registrationId] = {
      registrationId,
      hostFingerprint,
      deviceId,
      platform: 'ios',
      apnsEnvironment,
      token,
      device,
      createdAt: now,
      updatedAt: now
    }
    this.persist()
    return { ok: true, registrationId }
  }

  findOwned(hostFingerprint, registrationId) {
    const entry = this.state.registrations[registrationId]
    return entry && entry.hostFingerprint === hostFingerprint ? entry : null
  }

  listOwned(hostFingerprint) {
    return Object.values(this.state.registrations).filter(
      (entry) => entry.hostFingerprint === hostFingerprint
    )
  }

  deleteRegistration(registrationId) {
    if (!this.state.registrations[registrationId]) return false
    delete this.state.registrations[registrationId]
    delete this.state.badges[registrationId]
    this.persist()
    return true
  }

  /**
   * Drops one Live Activity token (an ended activity, or one APNs called dead)
   * without touching the rest of the blob. Only if it is still the stored one:
   * a re-registration may already have replaced it.
   */
  forgetLiveActivityToken(registrationId, { worktreeId, token, kind }) {
    const device = this.state.registrations[registrationId]?.device
    if (!device) return
    if (kind === 'start') {
      if (device.pushToStartToken !== token) return
      delete device.pushToStartToken
    } else {
      if (device.activityTokens?.[worktreeId] !== token) return
      delete device.activityTokens[worktreeId]
    }
    this.persist()
  }

  // ---- badges -----------------------------------------------------------

  /** Each host reports its own unread count; the phone's icon shows the sum. */
  recordBadge(registrationId, badge) {
    this.state.badges[registrationId] = badge
    this.persist()
  }

  /** Sum of the last counts of every registration that targets the same phone token; null when none recorded. */
  badgeTotal(deviceToken, apnsEnvironment) {
    let total = null
    for (const entry of Object.values(this.state.registrations)) {
      if (entry.device?.deviceToken !== deviceToken || entry.apnsEnvironment !== apnsEnvironment) continue
      const count = this.state.badges[entry.registrationId]
      if (typeof count === 'number') total = (total ?? 0) + count
    }
    return total
  }
}
