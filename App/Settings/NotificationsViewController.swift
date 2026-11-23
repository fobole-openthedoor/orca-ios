import OrcaCore
import UIKit
import UserNotifications

/// Settings › Notifications (notifications/NotificationSettingsScreen): whether this phone gets pushes,
/// which ones, and a test. Every change re-registers with each connected desktop.
final class NotificationsViewController: UITableViewController {
  private enum Row {
    case enabled, onlyAway, onlyNeedsInput, sound, test, openSettings
  }

  private var sections: [(rows: [Row], footer: String?)] = []
  private var blocked = false
  private var testing = false

  init() { super.init(style: .insetGrouped) }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.notificationSettingsScreen.title", defaultValue: "Notifications")
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermission() } }
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
    var first: [Row] = [.enabled]
    if blocked { first.append(.openSettings) }
    sections = [
      (
        first,
        blocked
          ? String(localized: "settings.notificationSettingsScreen.notificationsBlocked", defaultValue: "Notifications are disabled in system settings.")
          : String(
            localized: "settings.notificationSettingsScreen.description",
            defaultValue: "Get notified on this device when an agent needs your input or finishes a task.")
      )
    ]
    if settings.enabled {
      sections.append(
        (
          [.onlyAway, .onlyNeedsInput, .sound],
          String(
            localized: "notifications.notificationDeliverySection.footer",
            defaultValue: "Alert types follow each paired desktop’s notification settings.")
        ))
      sections.append(([.test], String(localized: "orcaios.push.gatewayFooter", defaultValue: "")))
    }
    tableView.reloadData()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgRaised
    cell.accessoryView = nil
    cell.selectionStyle = .none
    var content = UIListContentConfiguration.subtitleCell()
    content.secondaryTextProperties.color = Palette.textSecondary
    let settings = PushCenter.Settings.current
    func toggle(_ isOn: Bool, _ change: @escaping (inout PushCenter.Settings, Bool) -> Void) {
      let control = UISwitch()
      control.isOn = isOn
      control.addAction(
        UIAction { [weak self, weak control] _ in
          var settings = PushCenter.Settings.current
          change(&settings, control?.isOn ?? false)
          PushCenter.Settings.current = settings
          self?.rebuild()
        }, for: .valueChanged)
      cell.accessoryView = control
    }
    switch sections[indexPath.section].rows[indexPath.row] {
    case .enabled:
      content.text = String(localized: "settings.notificationSettingsScreen.enableNotifications", defaultValue: "Enable notifications")
      toggle(settings.enabled) { $0.enabled = $1 }
    case .onlyAway:
      content.text = String(localized: "notifications.notificationDeliverySection.onlyWhenAway", defaultValue: "Only when away from desktop")
      content.secondaryText = String(
        localized: "notifications.notificationDeliverySection.onlyWhenAwayHint",
        defaultValue: "After 3 minutes without keyboard or mouse activity, or when locked.")
      toggle(settings.filter.onlyWhenDesktopAway) { $0.filter.onlyWhenDesktopAway = $1 }
    case .onlyNeedsInput:
      content.text = String(
        localized: "notifications.notificationDeliverySection.onlyWhenAgentNeedsInput", defaultValue: "Only when an agent needs me")
      content.secondaryText = String(
        localized: "notifications.notificationDeliverySection.onlyWhenAgentNeedsInputHint",
        defaultValue: "Permission requests and questions.")
      toggle(settings.filter.onlyWhenAgentNeedsInput) { $0.filter.onlyWhenAgentNeedsInput = $1 }
    case .sound:
      content.text = String(localized: "notifications.notificationDeliverySection.sound", defaultValue: "Notification sound")
      toggle(settings.filter.sound) { $0.filter.sound = $1 }
    case .test:
      content = UIListContentConfiguration.cell()
      content.text = testing
        ? String(localized: "settings.notificationDisplayTest.sending", defaultValue: "Sending…")
        : String(localized: "settings.notificationDisplayTest.sendButton", defaultValue: "Send test notification")
      content.textProperties.color = testing ? Palette.textMuted : Palette.accentBlue
      cell.selectionStyle = .default
    case .openSettings:
      content = UIListContentConfiguration.cell()
      content.text = String(localized: "settings.notificationSettingsScreen.openSettings", defaultValue: "Open Settings")
      content.textProperties.color = Palette.accentBlue
      cell.selectionStyle = .default
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .openSettings:
      if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    case .test:
      sendTest()
    default:
      break
    }
  }

  /// Asks the first connected desktop to push a test, and says what it answered.
  private func sendTest() {
    guard !testing else { return }
    let model = AppModel.shared
    guard let session = model.orderedHosts.compactMap({ model.session(for: $0.id) }).first(where: { $0.connectionState == .connected })
    else { return say(String(localized: "orcaios.push.noDesktop", defaultValue: "Connect a desktop and try again.")) }
    testing = true
    rebuild()
    Task {
      defer {
        testing = false
        rebuild()
      }
      do {
        let result = try await session.api.testPush()
        if result.accepted {
          say(String(localized: "settings.notificationDisplayTest.accepted", defaultValue: "Orca push service accepted the request. Check for the notification."))
          return
        }
        // As the official test: say why the push didn't go, then check display with a local notification.
        let reason: String
        switch result.reason {
        case "not_registered":
          reason = String(
            localized: "settings.notificationDisplayTest.registrationPending",
            defaultValue: "Push registration for this desktop is not ready yet. Try again shortly.")
        case "rate_limited":
          reason = String(localized: "settings.notificationDisplayTest.rateLimited", defaultValue: "Too many notifications. Try again shortly.")
        default:
          reason = String(
            localized: "settings.notificationDisplayTest.pushServiceFailed", defaultValue: "Couldn't send through Orca push service. Try again.")
        }
        await localTest(reason: reason)
      } catch {
        await localTest(reason: String(localized: "settings.notificationDisplayTest.sendFailed", defaultValue: "Could not send push test."))
      }
    }
  }

  private func localTest(reason: String) async {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "settings.notificationDisplayTest.localTitle", defaultValue: "Test notification")
    content.body = String(localized: "settings.notificationDisplayTest.localBody", defaultValue: "A local notification test from this phone.")
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "orca.test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
    do {
      try await UNUserNotificationCenter.current().add(request)
      say(String(
        format: String(
          localized: "settings.notificationDisplayTest.liveFallbackScheduled",
          defaultValue: "%1$@ Local test scheduled. Check for the notification. Live alerts are available while Orca is running and connected."),
        reason))
    } catch {
      say(reason)
    }
  }

  private func say(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }
}
