import ActivityKit
import Foundation
import Observation
import OrcaCore
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "com.thm.orcaios", category: "push")

/// Gets this phone's pushes from every paired desktop.
///
/// The official gateway only serves the official app, so a desktop that should push here is pointed at the
/// gateway in this repo (`gateway/`, `ORCA_PUSH_GATEWAY_URL`). The desktop forwards the token it is given
/// without reading it, so the token carries what the gateway needs besides the APNs device token: the Live
/// Activity push-to-start token, each running activity's update token, and the desktop's name and id here.
@MainActor
final class PushCenter: NSObject {
  static let shared = PushCenter()

  /// The user's choices, kept on this phone and sent with every registration.
  struct Settings: Equatable {
    var enabled = true
    var filter = PushFilter()

    private static let defaults = UserDefaults.standard

    @MainActor static var current: Settings {
      get {
        var settings = Settings()
        if defaults.object(forKey: "orca.push.enabled") != nil { settings.enabled = defaults.bool(forKey: "orca.push.enabled") }
        settings.filter.onlyWhenDesktopAway = defaults.bool(forKey: "orca.push.onlyAway")
        settings.filter.onlyWhenAgentNeedsInput = defaults.bool(forKey: "orca.push.onlyNeedsInput")
        if defaults.object(forKey: "orca.push.sound") != nil { settings.filter.sound = defaults.bool(forKey: "orca.push.sound") }
        return settings
      }
      set {
        defaults.set(newValue.enabled, forKey: "orca.push.enabled")
        defaults.set(newValue.filter.onlyWhenDesktopAway, forKey: "orca.push.onlyAway")
        defaults.set(newValue.filter.onlyWhenAgentNeedsInput, forKey: "orca.push.onlyNeedsInput")
        defaults.set(newValue.filter.sound, forKey: "orca.push.sound")
        PushCenter.shared.settingsChanged()
      }
    }
  }

  private var model: AppModel?
  private var deviceToken: String?
  private var startToken: String?
  private var activityTokens: [String: String] = [:]
  /// What each desktop was last given, so an unchanged registration isn't sent again.
  private var registered: [UUID: String] = [:]
  private var pending: Task<Void, Never>?
  private var started = false

  private override init() {}

  /// Asks for permission once there is a desktop to hear from, then follows tokens and connections.
  func start(model: AppModel) {
    guard !started else { return }
    started = true
    self.model = model
    UNUserNotificationCenter.current().delegate = self
    observe(model)
    followActivityTokens()
  }

  private func observe(_ model: AppModel) {
    withObservationTracking {
      for host in model.hosts { _ = model.session(for: host.id)?.connectionState }
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.scheduleRegistration()
        self?.observe(model)
      }
    }
    scheduleRegistration()
  }

  private func requestPermissionIfNeeded() async -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    case .denied:
      return false
    default:
      return true
    }
  }

  // MARK: Tokens

  func didRegister(deviceToken data: Data) {
    deviceToken = data.map { String(format: "%02x", $0) }.joined()
    log.info("APNs device token received")
    scheduleRegistration()
  }

  /// Activity tokens arrive on their own; each change is a new registration.
  private func followActivityTokens() {
    Task {
      for await data in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
        startToken = data.map { String(format: "%02x", $0) }.joined()
        scheduleRegistration()
      }
    }
    Task {
      for activity in Activity<AgentActivityAttributes>.activities { follow(activity) }
      for await activity in Activity<AgentActivityAttributes>.activityUpdates { follow(activity) }
    }
  }

  private func follow(_ activity: Activity<AgentActivityAttributes>) {
    guard let worktreeId = Self.worktreeId(in: activity.attributes.deepLink) else { return }
    Task {
      for await data in activity.pushTokenUpdates {
        activityTokens[worktreeId] = data.map { String(format: "%02x", $0) }.joined()
        scheduleRegistration()
      }
    }
    Task {
      for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
        activityTokens[worktreeId] = nil
        scheduleRegistration()
      }
    }
  }

  private static func worktreeId(in link: URL) -> String? {
    URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "worktree" }?.value
  }

  // MARK: Registration

  private func settingsChanged() {
    registered = [:]
    scheduleRegistration()
  }

  /// Coalesces bursts (a reconnect and a token at once) into one registration per desktop.
  private func scheduleRegistration() {
    pending?.cancel()
    pending = Task {
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled else { return }
      await registerAll()
    }
  }

  private func registerAll() async {
    guard let model, !model.hosts.isEmpty else { return }
    let settings = Settings.current
    if settings.enabled, deviceToken == nil {
      guard await requestPermissionIfNeeded() else { return }
      UIApplication.shared.registerForRemoteNotifications()
      return
    }
    for host in model.hosts {
      guard let session = model.session(for: host.id), session.connectionState == .connected else { continue }
      if !settings.enabled {
        guard registered[host.id] != "" else { continue }
        try? await session.api.unregisterPush()
        registered[host.id] = ""
        continue
      }
      guard let token = blob(hostId: host.id, hostName: session.name) else { continue }
      guard registered[host.id] != token else { continue }
      do {
        let accepted = try await session.api.registerPush(token: token, sandbox: Self.sandbox, filter: settings.filter)
        log.info("push registration with \(session.name, privacy: .public): \(accepted ? "registered" : "refused", privacy: .public)")
        if accepted { registered[host.id] = token }
      } catch {
        // An older desktop without pushes, or a dropped connection: the next reconnect tries again.
        log.error("push registration failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// The token the gateway reads: `orcaios1.` and base64url JSON.
  private func blob(hostId: UUID, hostName: String) -> String? {
    guard let deviceToken else { return nil }
    var json: [String: Any] = [
      "d": deviceToken, "t": Bundle.main.bundleIdentifier ?? "com.thm.orcaios", "h": hostName, "k": hostId.uuidString,
    ]
    if let startToken { json["s"] = startToken }
    if !activityTokens.isEmpty { json["a"] = activityTokens }
    guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
    let base64 = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "orcaios1.\(base64)"
  }

  /// Development-signed builds get sandbox tokens; the provisioning profile says which this is.
  private static let sandbox: Bool = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
      let key = text.range(of: "<key>aps-environment</key>")
    else {
      #if targetEnvironment(simulator)
        return true
      #else
        // No profile is an App Store or TestFlight build.
        return false
      #endif
    }
    return text[key.upperBound...].prefix(80).contains("development")
  }()
}

extension PushCenter: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  /// A tapped notification opens the workspace it is about.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let orca = response.notification.request.content.userInfo["orca"] as? [String: Any]
    guard let host = orca?["host"] as? String, let worktree = orca?["worktreeId"] as? String,
      var components = URLComponents(string: "orca://open")
    else { return }
    components.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "worktree", value: worktree)]
    guard let url = components.url else { return }
    await MainActor.run { NotificationCenter.default.post(name: .orcaOpenURL, object: url) }
  }
}

extension Notification.Name {
  /// An orca:// link to open from inside the app, such as a tapped notification's workspace.
  static let orcaOpenURL = Notification.Name("orca.openURL")
}
