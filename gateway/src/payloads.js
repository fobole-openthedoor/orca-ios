// Pure builders for the APNs requests one notification turns into.
import { createHash } from 'node:crypto'

// Swift's Date encodes as seconds since 2001-01-01 under JSONDecoder's default strategy.
const APPLE_REFERENCE_EPOCH_S = 978_307_200
const DETAIL_MAX_CHARS = 120
const LIVE_ACTIVITY_DISMISS_AFTER_S = 600
const DEFAULT_TTL_MS = 5 * 60 * 1000

export function collapseIdFor(hostFingerprint, notification) {
  const identity =
    notification.notificationId === undefined
      ? [notification.notificationEpoch, notification.notificationSeq]
      : notification.notificationId
  // 64 hex chars = 64 bytes, exactly the apns-collapse-id limit.
  return createHash('sha256').update(JSON.stringify([hostFingerprint, identity])).digest('hex')
}

export function oneLine(text, max = DETAIL_MAX_CHARS) {
  const flat = String(text ?? '').replace(/\s+/g, ' ').trim()
  return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`
}

function expirationSeconds(notification, nowMs) {
  return Math.floor((notification.expiresAt ?? nowMs + DEFAULT_TTL_MS) / 1000)
}

/** Plain alert (kind alert or absent) to the phone's device token. */
export function buildAlertPush({ hostFingerprint, notification, device, badge, nowMs }) {
  const aps = {
    alert: { title: notification.title, body: notification.body },
    ...(notification.sound === false ? {} : { sound: 'default' }),
    ...(badge === null || badge === undefined ? {} : { badge }),
    'thread-id': notification.worktreeId ?? hostFingerprint
  }
  const orca = {
    hostFingerprint,
    ...(notification.worktreeId === undefined ? {} : { worktreeId: notification.worktreeId }),
    ...(notification.paneKey === undefined ? {} : { paneKey: notification.paneKey }),
    ...(notification.notificationId === undefined ? {} : { notificationId: notification.notificationId }),
    ...(notification.executionHost === undefined ? {} : { executionHost: notification.executionHost }),
    notificationSeq: notification.notificationSeq,
    notificationEpoch: notification.notificationEpoch,
    source: notification.source,
    agentState: notification.agentState ?? null,
    host: device.hostKey
  }
  return {
    headers: {
      'apns-push-type': 'alert',
      'apns-topic': device.topic,
      'apns-priority': '10',
      'apns-collapse-id': collapseIdFor(hostFingerprint, notification),
      'apns-expiration': String(expirationSeconds(notification, nowMs))
    },
    payload: { aps, orca }
  }
}

/** Badge-only push; never stored by APNs, so it cannot displace a pending alert. */
export function buildBadgePush({ device, badge }) {
  return {
    headers: {
      'apns-push-type': 'alert',
      'apns-topic': device.topic,
      'apns-priority': '10',
      'apns-expiration': '0'
    },
    payload: { aps: { badge } }
  }
}

export function deepLinkFor(hostKey, worktreeId) {
  return `orca://open?host=${encodeURIComponent(hostKey)}&worktree=${encodeURIComponent(worktreeId)}`
}

/**
 * Live Activity push for this notification, or null when none applies.
 * Returns the token it targets so a dead token can be forgotten.
 */
export function buildLiveActivityPush({ notification, device, nowMs }) {
  const worktreeId = notification.worktreeId
  if (!worktreeId) return null
  const kind = notification.kind ?? 'alert'
  if (kind !== 'alert') return null
  const nowS = Math.floor(nowMs / 1000)
  const since = nowS - APPLE_REFERENCE_EPOCH_S
  const detail = oneLine(notification.body || notification.title)
  const updateToken = device.activityTokens?.[worktreeId]
  const headers = {
    'apns-push-type': 'liveactivity',
    'apns-topic': `${device.topic}.push-type.liveactivity`,
    'apns-priority': '10',
    'apns-expiration': String(expirationSeconds(notification, nowMs))
  }
  const alert = { title: notification.title, body: notification.body }

  if (notification.agentState === 'needs-input') {
    if (updateToken) {
      return {
        token: updateToken,
        tokenKind: 'update',
        headers,
        payload: {
          aps: {
            timestamp: nowS,
            event: 'update',
            'content-state': { phase: 'needsYou', detail, since },
            alert
          }
        }
      }
    }
    if (device.pushToStartToken) {
      return {
        token: device.pushToStartToken,
        tokenKind: 'start',
        headers,
        payload: {
          aps: {
            timestamp: nowS,
            event: 'start',
            'content-state': { phase: 'needsYou', detail, since },
            'attributes-type': 'AgentActivityAttributes',
            attributes: {
              hostName: device.hostName,
              workspaceName: notification.title,
              agentName: 'Agent',
              deepLink: deepLinkFor(device.hostKey, worktreeId)
            },
            alert
          }
        }
      }
    }
    return null
  }

  if (notification.agentState === 'finished' && updateToken) {
    return {
      token: updateToken,
      tokenKind: 'end',
      headers,
      payload: {
        aps: {
          timestamp: nowS,
          event: 'end',
          'content-state': { phase: 'done', detail, since },
          'dismissal-date': nowS + LIVE_ACTIVITY_DISMISS_AFTER_S
        }
      }
    }
  }
  return null
}
