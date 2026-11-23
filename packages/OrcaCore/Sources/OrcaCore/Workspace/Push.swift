import Foundation

/// What a desktop pushes this phone (mobile-push-contract.ts MobilePushFilter).
public struct PushFilter: Sendable, Equatable {
  public var onlyWhenDesktopAway: Bool
  public var onlyWhenAgentNeedsInput: Bool
  public var sound: Bool
  public var badge: Bool

  public init(onlyWhenDesktopAway: Bool = false, onlyWhenAgentNeedsInput: Bool = false, sound: Bool = true, badge: Bool = true) {
    self.onlyWhenDesktopAway = onlyWhenDesktopAway
    self.onlyWhenAgentNeedsInput = onlyWhenAgentNeedsInput
    self.sound = sound
    self.badge = badge
  }

  var json: JSONValue {
    [
      "onlyWhenDesktopAway": .bool(onlyWhenDesktopAway), "onlyWhenAgentNeedsInput": .bool(onlyWhenAgentNeedsInput),
      "sound": .bool(sound), "badge": .bool(badge),
    ]
  }
}

extension HostAPI {
  /// Hands the desktop this phone's push token, which it forwards to its push gateway. `sandbox` for a
  /// development-signed build, `production` otherwise: APNs refuses a token sent to the other one.
  /// Returns whether the desktop registered it.
  @discardableResult
  public func registerPush(token: String, sandbox: Bool, filter: PushFilter) async throws -> Bool {
    let result = try await connection.request(
      "notifications.registerPush",
      [
        "platform": "ios", "token": .string(token), "apnsEnvironment": .string(sandbox ? "sandbox" : "production"),
        "filter": filter.json,
      ])
    return result["registered"]?.boolValue ?? false
  }

  /// Asks the desktop to push this phone a test. Returns whether it was sent, else the desktop's reason.
  public func testPush() async throws -> (accepted: Bool, reason: String?) {
    let result = try await connection.request("notifications.testPush", [:])
    return (result["accepted"]?.boolValue ?? false, result["reason"]?.stringValue)
  }

  public func unregisterPush() async throws {
    _ = try await connection.request("notifications.unregisterPush", [:])
  }
}
