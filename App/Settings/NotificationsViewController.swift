import OrcaCore
import UIKit
import UserNotifications

/// Settings › Notifications (app/notifications.tsx): whether this phone gets pushes, which ones, and a
/// test with a way into Troubleshooting. Every delivery change re-registers with each connected desktop.
final class NotificationsViewController: SettingsPageViewController {
  private var blocked = false
  private var sending = false
  /// What the last test found, shown under the test group (the official SettingsNote).
  private var testMessage: String?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.notificationSettingsScreen.title", defaultValue: "Notifications")
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermission() } }
    rebuild()
    refreshPermission()
  }

  private func refreshPermission() {
    Task {
      let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
      blocked = status == .denied
      rebuild()
    }
  }

  private func rebuild() {
    let settings = PushCenter.Settings.current
    // As the official screen: the switch reads off while the system blocks notifications.
    let on = settings.enabled && !blocked
    var first: [Row] = [
      .toggle(
        title: String(localized: "settings.notificationSettingsScreen.enableNotifications", defaultValue: "Enable notifications"),
        isOn: on, enabled: !blocked
      ) { [weak self] isOn in self?.change { $0.enabled = isOn } }
    ]
    if blocked {
      first.append(
        .value(title: String(localized: "settings.notificationSettingsScreen.openSettings", defaultValue: "Open Settings")) {
          if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        })
    }
    let header = Section(
      footer: blocked
        ? String(
          localized: "settings.notificationSettingsScreen.notificationsBlocked", defaultValue: "Notifications are disabled in system settings.")
        : String(
          localized: "app.notifications.description",
          defaultValue: "Get agent alerts even when the app is closed. Delivered through Orca’s push service and Apple or Google."),
      rows: first)

    func row(_ title: String, _ hint: String?, _ isOn: Bool, _ set: @escaping (inout PushCenter.Settings, Bool) -> Void) -> Row {
      .toggle(title: title, subtitle: hint, isOn: isOn, enabled: on) { [weak self] value in self?.change { set(&$0, value) } }
    }
    let delivery = Section(
      footer: String(
        localized: "notifications.notificationDeliverySection.footer",
        defaultValue:
          "Alert types follow each paired desktop’s notification settings. Notifications pause after 7 days without using this app; open it and reconnect to resume."
      ),
      rows: [
        row(
          String(localized: "notifications.notificationDeliverySection.onlyWhenAway", defaultValue: "Only when away from desktop"),
          String(
            localized: "notifications.notificationDeliverySection.onlyWhenAwayHint",
            defaultValue: "After 3 minutes without keyboard or mouse activity, or when locked."),
          settings.filter.onlyWhenDesktopAway
        ) { $0.filter.onlyWhenDesktopAway = $1 },
        row(
          String(localized: "notifications.notificationDeliverySection.onlyWhenAgentNeedsInput", defaultValue: "Only when an agent needs me"),
          String(
            localized: "notifications.notificationDeliverySection.onlyWhenAgentNeedsInputHint",
            defaultValue: "Permission requests and questions. Skips finished agents."),
          settings.filter.onlyWhenAgentNeedsInput
        ) { $0.filter.onlyWhenAgentNeedsInput = $1 },
        row(
          String(localized: "notifications.notificationDeliverySection.sound", defaultValue: "Notification sound"), nil,
          settings.filter.sound
        ) { $0.filter.sound = $1 },
        row(
          String(localized: "notifications.notificationDeliverySection.suppressWhileFocused", defaultValue: "Suppress while focused"),
          String(
            localized: "notifications.notificationDeliverySection.suppressWhileFocusedHint",
            defaultValue: "Skip alerts for the workspace open on this phone."),
          settings.suppressWhileViewing
        ) { $0.suppressWhileViewing = $1 },
      ])

    // Shown whatever the switch says: the test itself explains what is off.
    let sendTitle = String(localized: "settings.notificationDisplayTest.sendButton", defaultValue: "Send test notification")
    let notes = [
      String(
        localized: "settings.notificationDisplayTest.description",
        defaultValue: "Test push delivery, or a local notification when push is unavailable."),
      String(localized: "orcaios.push.gatewayFooter", defaultValue: ""),
      PushCenter.shared.statusLine,
      testMessage,
    ]
    let trouble = Section(
      header: String(localized: "settings.notificationDisplayTest.troubleReceivingAlerts", defaultValue: "Having trouble receiving alerts?"),
      footer: notes.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
      rows: [
        .value(
          title: sendTitle,
          value: sending ? String(localized: "settings.notificationDisplayTest.sending", defaultValue: "Sending…") : nil,
          enabled: !sending
        ) { [weak self] in self?.sendTest() },
        .value(
          title: String(localized: "settings.notificationDisplayTest.troubleshooting", defaultValue: "Troubleshooting"),
          navigates: true
        ) { [weak self] in self?.navigationController?.pushViewController(TroubleshootingViewController(), animated: true) },
      ])
    sections = [header, delivery, trouble]
  }

  private func change(_ edit: (inout PushCenter.Settings) -> Void) {
    var settings = PushCenter.Settings.current
    edit(&settings)
    PushCenter.Settings.current = settings
    rebuild()
  }

  // MARK: Test

  private struct TestFailure: Error {
    let message: String
  }

  /// notification-display-test.tsx: the same checks in the same order, then a push through each connected
  /// desktop until one is accepted; when none can push, a local notification checks display.
  private func sendTest() {
    guard !sending else { return }
    sending = true
    testMessage = nil
    rebuild()
    Task {
      let message: String
      do {
        message = try await runTest()
      } catch let failure as TestFailure {
        message = failure.message
      } catch {
        message = String(localized: "settings.notificationDisplayTest.sendFailed", defaultValue: "Could not send push test.")
      }
      sending = false
      testMessage = message
      rebuild()
      UIAccessibility.post(notification: .announcement, argument: message)
    }
  }

  private func runTest() async throws -> String {
    guard PushCenter.Settings.current.enabled else {
      throw TestFailure(
        message: String(
          localized: "settings.notificationDisplayTest.disabled",
          defaultValue: "Notifications are turned off in Orca. Enable notifications and try again."))
    }
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    guard status == .authorized || status == .provisional || status == .ephemeral else {
      throw TestFailure(
        message: String(
          localized: "settings.notificationDisplayTest.osDisabled",
          defaultValue: "Notifications are turned off in system settings. Allow notifications and try again."))
    }
    let model = AppModel.shared
    guard !model.hosts.isEmpty else {
      throw TestFailure(message: String(localized: "settings.notificationDisplayTest.pairDesktop", defaultValue: "Pair a desktop and try again."))
    }
    let connected = model.orderedHosts.compactMap { model.session(for: $0.id) }.filter { $0.connectionState == .connected }
    guard !connected.isEmpty else {
      throw TestFailure(
        message: String(localized: "settings.notificationDisplayTest.connectDesktop", defaultValue: "Connect a desktop and try again."))
    }
    var unavailable = String(
      localized: "settings.notificationDisplayTest.unsupportedHost",
      defaultValue: "This desktop does not support push notifications. Update it to receive push.")
    var liveFallback = true
    for session in connected {
      let result: (accepted: Bool, reason: String?)
      do {
        result = try await session.api.testPush()
      } catch let error as RPCError where error.code == "forbidden" || error.code == "method_not_found" {
        continue
      } catch {
        throw TestFailure(
          message: String(localized: "settings.notificationDisplayTest.desktopUnreachable", defaultValue: "Could not reach the desktop. Try again."))
      }
      if result.accepted {
        return String(
          localized: "settings.notificationDisplayTest.accepted", defaultValue: "Accepted by Orca’s push service. Check for the notification.")
      }
      switch result.reason {
      case "not_registered":
        // Another desktop may still deliver; this one only says why none did.
        unavailable = String(
          localized: "settings.notificationDisplayTest.registrationPending",
          defaultValue: "Push registration is not ready on this desktop. Try again shortly.")
        liveFallback = false
      case "rate_limited":
        throw TestFailure(
          message: String(localized: "settings.notificationDisplayTest.rateLimited", defaultValue: "Too many notifications. Try again later."))
      default:
        throw TestFailure(
          message: String(
            localized: "settings.notificationDisplayTest.pushServiceFailed", defaultValue: "Could not send through Orca’s push service. Try again."))
      }
    }
    return try await localTest(reason: unavailable, liveFallback: liveFallback)
  }

  private func localTest(reason: String, liveFallback: Bool) async throws -> String {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "settings.notificationDisplayTest.localTitle", defaultValue: "Test notification")
    content.body = String(localized: "settings.notificationDisplayTest.localBody", defaultValue: "Local notification test from this phone.")
    if PushCenter.Settings.current.filter.sound { content.sound = .default }
    let request = UNNotificationRequest(
      identifier: "orca.test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
    try await UNUserNotificationCenter.current().add(request)
    let format =
      liveFallback
      ? String(
        localized: "settings.notificationDisplayTest.liveFallbackScheduled",
        defaultValue: "%1$@ Local test scheduled. Check for the notification. Live alerts are available while Orca is running and connected.")
      : String(
        localized: "settings.notificationDisplayTest.localScheduled",
        defaultValue:
          "%1$@ Local test scheduled. Check for the notification. This checks display only; it does not verify agent alert delivery.")
    return String(format: format, reason)
  }
}
