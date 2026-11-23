import Foundation

/// One rate-limit window (`session` is the 5-hour one, `weekly` the 7-day one).
public struct UsageWindow: Sendable, Equatable {
  public var usedPercent: Double
  public var windowMinutes: Int
  /// Epoch milliseconds.
  public var resetsAt: Double?
  public var resetDescription: String?

  init?(_ json: JSONValue?) {
    guard let json, let used = json["usedPercent"]?.doubleValue else { return nil }
    usedPercent = max(0, min(100, used))
    windowMinutes = json["windowMinutes"]?.intValue ?? 0
    resetsAt = json["resetsAt"]?.doubleValue
    resetDescription = json["resetDescription"]?.stringValue
  }
}

/// A provider's limits as the desktop last polled them.
public struct ProviderUsage: Sendable, Equatable {
  public var provider: String
  public var session: UsageWindow?
  public var weekly: UsageWindow?
  /// Claude's separate 7-day window for Fable.
  public var fableWeekly: UsageWindow?
  /// Epoch milliseconds.
  public var updatedAt: Double?
  /// `idle`, `fetching`, `ok`, `error`, `unavailable`.
  public var status: String
  public var error: String?

  init?(_ json: JSONValue?) {
    guard let json, let provider = json["provider"]?.stringValue else { return nil }
    self.provider = provider
    session = UsageWindow(json["session"])
    weekly = UsageWindow(json["weekly"])
    fableWeekly = UsageWindow(json["fableWeekly"])
    updatedAt = json["updatedAt"]?.doubleValue
    status = json["status"]?.stringValue ?? "idle"
    error = json["error"]?.stringValue
  }
}

/// A managed agent account the desktop can switch to.
public struct AgentAccount: Sendable, Equatable, Identifiable {
  public var id: String
  public var email: String
  public var displayName: String?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let email = json["email"]?.stringValue else { return nil }
    self.id = id
    self.email = email
    displayName = json["displayName"]?.stringValue
  }
}

/// One provider's accounts: the managed ones, which is active (nil is the system default), and the limits.
public struct ProviderAccounts: Sendable, Equatable {
  public var accounts: [AgentAccount]
  public var activeAccountId: String?
  public var usage: ProviderUsage?
}

/// `accounts.list`: Claude's and Codex's accounts and limits.
public struct AccountsSnapshot: Sendable, Equatable {
  public var claude: ProviderAccounts
  public var codex: ProviderAccounts

  public init(_ json: JSONValue) {
    func provider(_ key: String) -> ProviderAccounts {
      ProviderAccounts(
        accounts: (json[key]?["accounts"]?.arrayValue ?? []).compactMap(AgentAccount.init),
        activeAccountId: json[key]?["activeAccountId"]?.stringValue,
        usage: ProviderUsage(json["rateLimits"]?[key]))
    }
    claude = provider("claude")
    codex = provider("codex")
  }
}

/// `stats.summary`: the desktop's running totals.
public struct StatsSummary: Sendable, Equatable {
  public var agentsSpawned: Int
  public var prsCreated: Int
  public var agentTimeMs: Double

  init(_ json: JSONValue) {
    agentsSpawned = json["totalAgentsSpawned"]?.intValue ?? 0
    prsCreated = json["totalPRsCreated"]?.intValue ?? 0
    agentTimeMs = json["totalAgentTimeMs"]?.doubleValue ?? 0
  }
}

extension HostAPI {
  public func accounts() async throws -> AccountsSnapshot {
    let result = try await connection.request("accounts.list", [:])
    // Some hosts wrap the snapshot; older ones return it bare.
    return AccountsSnapshot(result["snapshot"] ?? result)
  }

  public func stats() async throws -> StatsSummary {
    StatsSummary(try await connection.request("stats.summary", [:]))
  }
}
