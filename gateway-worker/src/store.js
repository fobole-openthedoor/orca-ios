// Gateway state in the Durable Object's SQLite storage: host sessions, device
// registrations, badge counts, pending handshake challenges, per-IP rate
// limits and the shared APNs provider token. One object holds everything, so
// every read and write is serialised and each statement is atomic; the methods
// mirror the Node gateway's GatewayStore (JSON file) one for one.
import { Buffer } from 'node:buffer'
import { createHash, randomBytes, randomUUID } from 'node:crypto'

export const MAX_DEVICES_PER_HOST = 64
const SCHEMA_VERSION = 1
const MAX_RATE_LIMIT_ROWS = 10_000

function hashToken(token) {
  return createHash('sha256').update(token).digest('base64url')
}

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS sessions (
     token_hash TEXT PRIMARY KEY,
     host_fingerprint TEXT NOT NULL,
     expires_at INTEGER NOT NULL
   )`,
  `CREATE INDEX IF NOT EXISTS sessions_by_host ON sessions (host_fingerprint)`,
  `CREATE TABLE IF NOT EXISTS registrations (
     registration_id TEXT PRIMARY KEY,
     host_fingerprint TEXT NOT NULL,
     device_id TEXT NOT NULL,
     platform TEXT NOT NULL,
     apns_environment TEXT NOT NULL,
     token TEXT NOT NULL,
     device TEXT NOT NULL,
     device_token TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     updated_at INTEGER NOT NULL,
     UNIQUE (host_fingerprint, device_id)
   )`,
  `CREATE INDEX IF NOT EXISTS registrations_by_device_token ON registrations (device_token, apns_environment)`,
  `CREATE TABLE IF NOT EXISTS badges (registration_id TEXT PRIMARY KEY, badge INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS challenges (
     challenge_id TEXT PRIMARY KEY,
     host_fingerprint TEXT NOT NULL,
     proof_digest TEXT NOT NULL,
     expires_at INTEGER NOT NULL,
     consumed INTEGER NOT NULL DEFAULT 0
   )`,
  `CREATE TABLE IF NOT EXISTS rate_limits (key TEXT PRIMARY KEY, minute INTEGER NOT NULL, count INTEGER NOT NULL)`
]

export function migrate(sql) {
  for (const statement of SCHEMA) sql.exec(statement)
  const row = sql.exec(`SELECT value FROM meta WHERE key = 'schema_version'`).toArray()[0]
  if (!row) {
    sql.exec(`INSERT INTO meta (key, value) VALUES ('schema_version', ?)`, String(SCHEMA_VERSION))
  } else if (Number(row.value) !== SCHEMA_VERSION) {
    throw new Error(`Unsupported gateway schema version ${row.value}`)
  }
}

function toRegistration(row) {
  return {
    registrationId: row.registration_id,
    hostFingerprint: row.host_fingerprint,
    deviceId: row.device_id,
    platform: row.platform,
    apnsEnvironment: row.apns_environment,
    token: row.token,
    device: JSON.parse(row.device),
    createdAt: row.created_at,
    updatedAt: row.updated_at
  }
}

export class GatewayStore {
  /** @param {{sql: SqlStorage, transactionSync: (fn: () => any) => any, sessionTtlMs: number, now?: () => number}} options */
  constructor({ sql, transactionSync, sessionTtlMs, now = Date.now, log = () => {} }) {
    this.sql = sql
    this.transaction = transactionSync ?? ((fn) => fn())
    this.sessionTtlMs = sessionTtlMs
    this.now = now
    this.log = log
    migrate(sql)
    this.pruneSessions()
  }

  rows(query, ...bindings) {
    return this.sql.exec(query, ...bindings).toArray()
  }

  // ---- sessions ---------------------------------------------------------

  /** One live session per host: a new sign-in replaces the old token. */
  createSession(hostFingerprint) {
    const sessionToken = randomBytes(32).toString('base64url')
    const expiresAt = this.now() + this.sessionTtlMs
    this.transaction(() => {
      this.sql.exec(`DELETE FROM sessions WHERE host_fingerprint = ?`, hostFingerprint)
      this.pruneSessions()
      this.sql.exec(
        `INSERT INTO sessions (token_hash, host_fingerprint, expires_at) VALUES (?, ?, ?)`,
        hashToken(sessionToken),
        hostFingerprint,
        expiresAt
      )
    })
    return { sessionToken, expiresAt, hostFingerprint }
  }

  resolveSession(sessionToken) {
    const row = this.rows(
      `SELECT host_fingerprint, expires_at FROM sessions WHERE token_hash = ?`,
      hashToken(sessionToken)
    )[0]
    if (!row) return null
    if (this.now() > row.expires_at) return null
    return { hostFingerprint: row.host_fingerprint, expiresAt: row.expires_at }
  }

  pruneSessions() {
    this.sql.exec(`DELETE FROM sessions WHERE expires_at < ?`, this.now())
  }

  /** For tests and diagnostics. */
  listSessions() {
    return this.rows(`SELECT host_fingerprint, expires_at FROM sessions`).map((row) => ({
      hostFingerprint: row.host_fingerprint,
      expiresAt: row.expires_at
    }))
  }

  // ---- registrations ----------------------------------------------------

  /**
   * Stable registrationId per (host, deviceId): the desktop keeps that id and
   * re-registers whenever the phone's token blob changes.
   */
  upsertRegistration({ hostFingerprint, deviceId, apnsEnvironment, token, device }) {
    const now = this.now()
    return this.transaction(() => {
      const existing = this.rows(
        `SELECT registration_id FROM registrations WHERE host_fingerprint = ? AND device_id = ?`,
        hostFingerprint,
        deviceId
      )[0]
      if (existing) {
        this.sql.exec(
          `UPDATE registrations SET apns_environment = ?, token = ?, device = ?, device_token = ?, updated_at = ?
           WHERE registration_id = ?`,
          apnsEnvironment,
          token,
          JSON.stringify(device),
          device.deviceToken,
          now,
          existing.registration_id
        )
        return { ok: true, registrationId: existing.registration_id }
      }
      const owned = this.rows(
        `SELECT COUNT(*) AS n FROM registrations WHERE host_fingerprint = ?`,
        hostFingerprint
      )[0].n
      if (owned >= MAX_DEVICES_PER_HOST) return { ok: false, reason: 'too_many_devices' }
      const registrationId = randomUUID()
      this.sql.exec(
        `INSERT INTO registrations
           (registration_id, host_fingerprint, device_id, platform, apns_environment, token, device, device_token, created_at, updated_at)
         VALUES (?, ?, ?, 'ios', ?, ?, ?, ?, ?, ?)`,
        registrationId,
        hostFingerprint,
        deviceId,
        apnsEnvironment,
        token,
        JSON.stringify(device),
        device.deviceToken,
        now,
        now
      )
      return { ok: true, registrationId }
    })
  }

  getRegistration(registrationId) {
    const row = this.rows(`SELECT * FROM registrations WHERE registration_id = ?`, registrationId)[0]
    return row ? toRegistration(row) : null
  }

  findOwned(hostFingerprint, registrationId) {
    const entry = this.getRegistration(registrationId)
    return entry && entry.hostFingerprint === hostFingerprint ? entry : null
  }

  listOwned(hostFingerprint) {
    return this.rows(
      `SELECT * FROM registrations WHERE host_fingerprint = ? ORDER BY rowid`,
      hostFingerprint
    ).map(toRegistration)
  }

  deleteRegistration(registrationId) {
    return this.transaction(() => {
      const found = this.rows(`SELECT 1 FROM registrations WHERE registration_id = ?`, registrationId).length > 0
      if (!found) return false
      this.sql.exec(`DELETE FROM registrations WHERE registration_id = ?`, registrationId)
      this.sql.exec(`DELETE FROM badges WHERE registration_id = ?`, registrationId)
      return true
    })
  }

  /**
   * Drops one Live Activity token (an ended activity, or one APNs called dead)
   * without touching the rest of the blob. Only if it is still the stored one:
   * a re-registration may already have replaced it.
   */
  forgetLiveActivityToken(registrationId, { worktreeId, token, kind }) {
    this.transaction(() => {
      const device = this.getRegistration(registrationId)?.device
      if (!device) return
      if (kind === 'start') {
        if (device.pushToStartToken !== token) return
        delete device.pushToStartToken
      } else {
        if (device.activityTokens?.[worktreeId] !== token) return
        delete device.activityTokens[worktreeId]
      }
      this.sql.exec(
        `UPDATE registrations SET device = ? WHERE registration_id = ?`,
        JSON.stringify(device),
        registrationId
      )
    })
  }

  // ---- badges -----------------------------------------------------------

  /** Each host reports its own unread count; the phone's icon shows the sum. */
  recordBadge(registrationId, badge) {
    this.sql.exec(
      `INSERT INTO badges (registration_id, badge) VALUES (?, ?)
       ON CONFLICT (registration_id) DO UPDATE SET badge = excluded.badge`,
      registrationId,
      badge
    )
  }

  /** Sum of the last counts of every registration that targets the same phone token; null when none recorded. */
  badgeTotal(deviceToken, apnsEnvironment) {
    const row = this.rows(
      `SELECT COUNT(b.badge) AS n, SUM(b.badge) AS total
       FROM registrations r JOIN badges b ON b.registration_id = r.registration_id
       WHERE r.device_token = ? AND r.apns_environment = ?`,
      deviceToken,
      apnsEnvironment
    )[0]
    return row && row.n > 0 ? Number(row.total) : null
  }
}

/** Pending handshake challenges (see ChallengeStore in handshake.js). */
export class SqlChallengeTable {
  constructor(sql) {
    this.sql = sql
  }

  count() {
    return this.sql.exec(`SELECT COUNT(*) AS n FROM challenges`).one().n
  }

  get(challengeId) {
    const row = this.sql
      .exec(`SELECT host_fingerprint, proof_digest, expires_at, consumed FROM challenges WHERE challenge_id = ?`, challengeId)
      .toArray()[0]
    if (!row) return null
    return {
      hostFingerprint: row.host_fingerprint,
      proofDigest: Buffer.from(row.proof_digest, 'base64'),
      expiresAt: row.expires_at,
      consumed: row.consumed === 1
    }
  }

  put(challengeId, entry) {
    this.sql.exec(
      `INSERT INTO challenges (challenge_id, host_fingerprint, proof_digest, expires_at, consumed) VALUES (?, ?, ?, ?, ?)`,
      challengeId,
      entry.hostFingerprint,
      Buffer.from(entry.proofDigest).toString('base64'),
      entry.expiresAt,
      entry.consumed ? 1 : 0
    )
  }

  markConsumed(challengeId) {
    this.sql.exec(`UPDATE challenges SET consumed = 1 WHERE challenge_id = ?`, challengeId)
  }

  delete(challengeId) {
    this.sql.exec(`DELETE FROM challenges WHERE challenge_id = ?`, challengeId)
  }

  deleteExpiredBefore(cutoff) {
    this.sql.exec(`DELETE FROM challenges WHERE expires_at < ?`, cutoff)
  }
}

/** Fixed one-minute windows per key; enough to stop a loop from burning keys and storage. */
export class SqlMinuteLimiter {
  constructor(sql, capacity, now = Date.now) {
    this.sql = sql
    this.capacity = capacity
    this.now = now
  }

  allow(key) {
    const minute = Math.floor(this.now() / 60_000)
    const row = this.sql.exec(`SELECT minute, count FROM rate_limits WHERE key = ?`, key).toArray()[0]
    if (!row || row.minute !== minute) {
      // Old windows are worthless; drop them rather than let the table grow.
      const rows = this.sql.exec(`SELECT COUNT(*) AS n FROM rate_limits`).one().n
      if (rows > MAX_RATE_LIMIT_ROWS) this.sql.exec(`DELETE FROM rate_limits WHERE minute < ?`, minute)
      this.sql.exec(
        `INSERT INTO rate_limits (key, minute, count) VALUES (?, ?, 1)
         ON CONFLICT (key) DO UPDATE SET minute = excluded.minute, count = 1`,
        key,
        minute
      )
      return true
    }
    const count = row.count + 1
    this.sql.exec(`UPDATE rate_limits SET count = ? WHERE key = ?`, count, key)
    return count <= this.capacity
  }
}

/** Where the shared APNs provider token is kept between requests and restarts. */
export class SqlTokenCache {
  /** One row per APNs key id, so the sandbox and production keys each keep their own token. */
  constructor(sql, keyId) {
    this.sql = sql
    this.key = `apns_provider_token:${keyId}`
  }

  load() {
    const row = this.sql.exec(`SELECT value FROM meta WHERE key = ?`, this.key).toArray()[0]
    if (!row) return null
    try {
      return JSON.parse(row.value)
    } catch {
      return null
    }
  }

  save(entry) {
    this.sql.exec(
      `INSERT INTO meta (key, value) VALUES (?, ?)
       ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
      this.key,
      JSON.stringify(entry)
    )
  }

  clear() {
    this.sql.exec(`DELETE FROM meta WHERE key = ?`, this.key)
  }
}
