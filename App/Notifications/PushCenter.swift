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

  /// The user's choices, kept on this phone and sent with every registration. A missing value takes the
  /// official default (notification-delivery-preferences.ts): only when away, with sound, every alert type.
  struct Settings: Equatable {
    var enabled = true
    var filter = PushFilter(onlyWhenDesktopAway: true, onlyWhenAgentNeedsInput: false, sound: true)
    /// Skip a foreground alert for the workspace on screen. Only this phone reads it; desktops never see it.
    var suppressWhileViewing = true

    private static let defaults = UserDefaults.standard

    @MainActor static var current: Settings {
      get {
        var settings = Settings()
        func read(_ key: String, into value: inout Bool) {
          if defaults.object(forKey: key) != nil { value = defaults.bool(forKey: key) }
        }
        read("orca.push.enabled", into: &settings.enabled)
        read("orca.push.onlyAway", into: &settings.filter.onlyWhenDesktopAway)
        read("orca.push.onlyNeedsInput", into: &settings.filter.onlyWhenAgentNeedsInput)
        read("orca.push.sound", into: &settings.filter.sound)
        read("orca.push.suppressWhileViewing", into: &settings.suppressWhileViewing)
        return settings
      }
      set {
        let old = current
        defaults.set(newValue.enabled, forKey: "orca.push.enabled")
        defaults.set(newValue.filter.onlyWhenDesktopAway, forKey: "orca.push.onlyAway")
        defaults.set(newValue.filter.onlyWhenAgentNeedsInput, forKey: "orca.push.onlyNeedsInput")
        defaults.set(newValue.filter.sound, forKey: "orca.push.sound")
        defaults.set(newValue.suppressWhileViewing, forKey: "orca.push.suppressWhileViewing")
        // The suppress switch stays on this phone, so changing only it re-registers nowhere.
        if old.enabled != newValue.enabled || old.filter != newValue.filter { PushCenter.shared.settingsChanged() }
      }
    }
  }

  /// The workspace on screen, for "Suppress while focused" (notification-viewing-policy.ts). The session
  /// screen sets it when it appears and clears it (nil) when it goes: `hostKey` is the paired host's id as
  /// the push names it (`PairedHost.ID.uuidString`), `executionHost` the route's server, nil for the
  /// desktop's own workspaces.
  static var viewing: (hostKey: String, worktreeId: String, executionHost: String?)?

  /// Whether a push that arrives while Orca is open is about the workspace being looked at, and the user
  /// asked not to be told about that one.
  static func suppressesWhileViewing(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard Settings.current.suppressWhileViewing, UIApplication.shared.applicationState == .active,
      let viewing, let orca = userInfo["orca"] as? [String: Any],
      let host = orca["host"] as? String, host.caseInsensitiveCompare(viewing.hostKey) == .orderedSame,
      let worktreeId = orca["worktreeId"] as? String, worktreeId == viewing.worktreeId
    else { return false }
    return orca["executionHost"] as? String == viewing.executionHost
  }

  private var model: AppModel?
  private var deviceToken: String?
  private var startToken: String?
  private var activityTokens: [String: String] = [:]
  /// What each desktop was last given, so an unchanged registration isn't sent again.
  private var registered: [UUID: String] = [:]
  /// Desktops that answered the registration with a refusal (no push gateway set up there).
  private(set) var refusedBy: Set<UUID> = []
  /// How many desktops took this phone's registration.
  var registeredDesktops: Int { registered.values.filter { !$0.isEmpty }.count }
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
        if accepted {
          registered[host.id] = token
          refusedBy.remove(host.id)
        } else {
          refusedBy.insert(host.id)
        }
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
    let userInfo = notification.request.content.userInfo
    // userInfo is a plain property list; it is only read on the main actor to compare against the screen.
    nonisolated(unsafe) let info = userInfo
    let suppress = await MainActor.run { PushCenter.suppressesWhileViewing(info) }
    return suppress ? [] : [.banner, .list, .sound]
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
