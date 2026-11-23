// Turns one /v1/send request into APNs pushes and per-registration statuses.
import { buildAlertPush, buildBadgePush, buildLiveActivityPush } from './payloads.js'

const STATUS_FOR_OUTCOME = { sent: 'queued', dead: 'dead', rate_limited: 'rate_limited', error: 'error' }

export class Delivery {
  constructor({ store, apns, now = Date.now, log = () => {} }) {
    this.store = store
    this.apns = apns
    this.now = now
    this.log = log
  }

  async send(hostFingerprint, registrationIds, notification) {
    return await Promise.all(
      registrationIds.map(async (registrationId) => ({
        registrationId,
        status: await this.sendOne(hostFingerprint, registrationId, notification)
      }))
    )
  }

  async sendOne(hostFingerprint, registrationId, notification) {
    const registration = this.store.findOwned(hostFingerprint, registrationId)
    // Unknown or another host's id: same answer, so ids cannot be probed.
    if (!registration) return 'error'
    const kind = notification.kind ?? 'alert'
    // Nothing to withdraw remotely in this gateway; the app reconciles on open.
    if (kind === 'dismiss') return 'queued'

    const { device, apnsEnvironment } = registration
    const nowMs = this.now()
    if (notification.expiresAt !== undefined && notification.expiresAt <= nowMs) return 'error'

    if (kind === 'badge') {
      this.store.recordBadge(registrationId, notification.badge)
      const total = this.store.badgeTotal(device.deviceToken, apnsEnvironment) ?? notification.badge
      const push = buildBadgePush({ device, badge: total })
      return await this.deliver(registration, push, 'badge')
    }

    const badge = this.store.badgeTotal(device.deviceToken, apnsEnvironment)
    const alert = buildAlertPush({ hostFingerprint, notification, device, badge, nowMs })
    const liveActivity = buildLiveActivityPush({ notification, device, nowMs })
    const [status] = await Promise.all([
      this.deliver(registration, alert, 'alert'),
      // Never allowed to change the registration's status.
      liveActivity ? this.deliverLiveActivity(registration, notification, liveActivity) : null
    ])
    return status
  }

  async deliver(registration, push, label) {
    const result = await this.apns.send({
      environment: registration.apnsEnvironment,
      deviceToken: registration.device.deviceToken,
      headers: push.headers,
      payload: push.payload
    })
    if (result.outcome !== 'sent') {
      this.log('warn', 'apns_push_failed', {
        push: label,
        registration: registration.registrationId.slice(0, 8),
        status: result.status,
        reason: result.reason
      })
    }
    if (result.outcome === 'dead') {
      this.store.deleteRegistration(registration.registrationId)
    }
    return STATUS_FOR_OUTCOME[result.outcome]
  }

  async deliverLiveActivity(registration, notification, push) {
    try {
      const result = await this.apns.send({
        environment: registration.apnsEnvironment,
        deviceToken: push.token,
        headers: push.headers,
        payload: push.payload
      })
      const forget = () =>
        this.store.forgetLiveActivityToken(registration.registrationId, {
          worktreeId: notification.worktreeId,
          token: push.token,
          kind: push.tokenKind
        })
      if (result.outcome === 'dead') {
        forget()
      } else if (result.outcome === 'sent' && push.tokenKind === 'end') {
        // The activity is over; the next needs-input should start a fresh one.
        forget()
      }
      if (result.outcome !== 'sent') {
        this.log('warn', 'live_activity_push_failed', {
          event: push.tokenKind,
          registration: registration.registrationId.slice(0, 8),
          status: result.status,
          reason: result.reason
        })
      }
    } catch (error) {
      this.log('warn', 'live_activity_push_failed', { event: push.tokenKind, reason: error?.message })
    }
  }
}
