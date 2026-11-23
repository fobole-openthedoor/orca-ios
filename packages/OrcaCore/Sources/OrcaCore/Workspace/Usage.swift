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
  public var monthly: UsageWindow?
  /// Named pools (Antigravity's models), in the host's order.
  public var buckets: [(name: String, window: UsageWindow)]
  /// Epoch milliseconds.
  public var updatedAt: Double?
  /// `idle`, `fetching`, `ok`, `error`, `unavailable`.
  public var status: String
  public var error: String?

  /// Any window to draw (usage-provider-windows.ts hasUsageData).
  public var hasUsageData: Bool {
    session != nil || weekly != nil || fableWeekly != nil || monthly != nil || !buckets.isEmpty
  }

  init?(_ json: JSONValue?) {
    guard let json, let provider = json["provider"]?.stringValue else { return nil }
    self.provider = provider
    session = UsageWindow(json["session"])
    weekly = UsageWindow(json["weekly"])
    fableWeekly = UsageWindow(json["fableWeekly"])
    monthly = UsageWindow(json["monthly"])
    buckets = (json["buckets"]?.arrayValue ?? []).compactMap { bucket in
      guard let name = bucket["name"]?.stringValue, !name.isEmpty, let window = UsageWindow(bucket) else { return nil }
      return (name, window)
    }
    updatedAt = json["updatedAt"]?.doubleValue
    status = json["status"]?.stringValue ?? "idle"
    error = json["error"]?.stringValue
  }

  public static func == (lhs: ProviderUsage, rhs: ProviderUsage) -> Bool {
    lhs.provider == rhs.provider && lhs.session == rhs.session && lhs.weekly == rhs.weekly
      && lhs.fableWeekly == rhs.fableWeekly && lhs.monthly == rhs.monthly && lhs.updatedAt == rhs.updatedAt
      && lhs.status == rhs.status && lhs.error == rhs.error && lhs.buckets.map(\.name) == rhs.buckets.map(\.name)
      && lhs.buckets.map(\.window) == rhs.buckets.map(\.window)
  }
}

/// A managed agent account the desktop can switch to.
public struct AgentAccount: Sendable, Equatable, Identifiable {
  public var id: String
  public var email: String
  public var displayName: String?
  /// Codex: the ChatGPT workspace it signs in to.
  public var workspaceLabel: String?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let email = json["email"]?.stringValue else { return nil }
    self.id = id
    self.email = email
    displayName = json["displayName"]?.stringValue
    workspaceLabel = json["workspaceLabel"]?.stringValue
  }

  /// The row's name: the user's own for it, else the sign-in email (getManagedAccountPrimaryLabel).
  public var primaryLabel: String {
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? email : name
  }
}

/// An account that isn't selected, with the limits the desktop last read for it.
public struct InactiveAccountUsage: Sendable, Equatable {
  public var accountId: String
  public var usage: ProviderUsage?
  public var isFetching: Bool
}

/// The runtime a provider's selection and limits are for: the host, or a WSL distro on it.
public struct RateLimitTarget: Sendable, Equatable {
  /// `host` or `wsl`.
  public var runtime: String
  public var wslDistro: String?

  init(_ json: JSONValue?) {
    runtime = json?["runtime"]?.stringValue ?? "host"
    wslDistro = json?["wslDistro"]?.stringValue
  }

  var json: JSONValue { ["runtime": .string(runtime), "wslDistro": wslDistro.map(JSONValue.string) ?? .null] }
}

/// One provider's accounts: the managed ones, which is active (nil is the system default), and the limits.
public struct ProviderAccounts: Sendable, Equatable {
  public var accounts: [AgentAccount]
  public var activeAccountId: String?
  public var usage: ProviderUsage?
  /// Unselected accounts' limits, by account id (and Claude's system default under its own key).
  public var inactive: [InactiveAccountUsage] = []
  public var target = RateLimitTarget(nil)
  /// Codex's selection per runtime (`{ host, wsl: { distro: id } }`), from a host that keeps one per runtime.
  public var activeByRuntime: JSONValue?

  /// The selected account for the runtime the limits are read for; nil is the system default.
  public var selectedAccountId: String? {
    guard let activeByRuntime else { return activeAccountId }
    // codex-reset-credit-scope.ts getActiveCodexAccountIdForRateLimitTarget.
    if target.runtime == "host" { return target.wslDistro == nil ? activeByRuntime["host"]?.stringValue : nil }
    guard let distro = target.wslDistro?.trimmingCharacters(in: .whitespaces), !distro.isEmpty else { return nil }
    return activeByRuntime["wsl"]?[distro]?.stringValue
  }

  public func inactiveUsage(_ accountId: String) -> InactiveAccountUsage? {
    inactive.first { $0.accountId == accountId }
  }
}

/// `accounts.list`: Claude's and Codex's accounts and limits, and other agents' limits.
public struct AccountsSnapshot: Sendable, Equatable {
  public var claude: ProviderAccounts
  public var codex: ProviderAccounts
  /// Every other provider with limits to show, by provider id (getOtherUsageProviders).
  public var others: [ProviderUsage]

  /// Claude's system default login, read while another account is selected.
  public static let claudeSystemDefaultUsageId = "claude-system-default"

  public init(_ json: JSONValue) {
    let limits = json["rateLimits"]
    func provider(_ key: String, inactive: String, target: String) -> ProviderAccounts {
      ProviderAccounts(
        accounts: (json[key]?["accounts"]?.arrayValue ?? []).compactMap(AgentAccount.init),
        activeAccountId: json[key]?["activeAccountId"]?.stringValue,
        usage: ProviderUsage(limits?[key]),
        inactive: (limits?[inactive]?.arrayValue ?? []).compactMap { entry in
          guard let id = entry["accountId"]?.stringValue else { return nil }
          return InactiveAccountUsage(
            accountId: id, usage: ProviderUsage(entry["rateLimits"]), isFetching: entry["isFetching"]?.boolValue ?? false)
        },
        target: RateLimitTarget(limits?[target]),
        activeByRuntime: json[key]?["activeAccountIdsByRuntime"])
    }
    claude = provider("claude", inactive: "inactiveClaudeAccounts", target: "claudeTarget")
    codex = provider("codex", inactive: "inactiveCodexAccounts", target: "codexTarget")
    let own: Set = ["claude", "codex", "claudeTarget", "codexTarget", "inactiveClaudeAccounts", "inactiveCodexAccounts"]
    // Hidden or signed-out providers come back idle or unavailable with no windows.
    others = (limits?.objectValue ?? [:]).filter { !own.contains($0.key) }.sorted { $0.key < $1.key }
      .compactMap { ProviderUsage($0.value) }
      .filter { $0.hasUsageData || $0.status == "error" }
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

  /// Switches the agent's account; nil goes back to the system default. A Codex selection for a WSL runtime names
  /// it through its own method, so an old host that would drop the target refuses instead.
  public func selectAccount(provider: String, accountId: String?, in accounts: ProviderAccounts) async throws {
    let id: JSONValue = accountId.map(JSONValue.string) ?? .null
    if provider == "claude" {
      _ = try await connection.request("accounts.selectClaude", ["accountId": id])
    } else if accounts.target.runtime == "wsl" {
      _ = try await connection.request("accounts.selectCodexForTarget", ["accountId": id, "target": accounts.target.json])
    } else {
      _ = try await connection.request("accounts.selectCodex", ["accountId": id])
    }
  }

  public func stats() async throws -> StatsSummary {
    StatsSummary(try await connection.request("stats.summary", [:]))
  }
}
