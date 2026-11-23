import Foundation

/// One workspace row of `worktree.ps`. Hosts add fields over time and older ones omit most of them,
/// so only the identity is required and every enum is read as an open string.
public struct Worktree: Sendable, Equatable, Identifiable {
  public struct LinkedPR: Sendable, Equatable {
    public var number: Int
    public var state: String
    public var title: String?
    public var url: String?
  }

  /// An agent running in the workspace, as the list shows it.
  public struct Agent: Sendable, Equatable, Identifiable {
    public var paneKey: String
    /// `working`, `blocked`, `waiting`, `done`, or a value a newer host added.
    public var state: String
    public var agentType: String?
    public var prompt: String
    public var taskTitle: String?
    public var displayName: String?
    public var conversationName: String?
    public var lastAssistantMessage: String?
    public var toolName: String?
    public var orcaSessionId: String?
    public var updatedAt: Double?

    public var id: String { paneKey }

    /// The best one-line name for the row.
    public var title: String {
      for candidate in [conversationName, taskTitle, displayName] {
        if let candidate, !candidate.isEmpty {
          return candidate
        }
      }
      return prompt.isEmpty ? (agentType ?? "Agent") : prompt
    }

    /// An agent the client reports itself (a chat it is showing), before the host lists it.
    public static func placeholder(agentType: String?) -> Agent {
      Agent(paneKey: "client", state: "idle", agentType: agentType, prompt: "")
    }

    init(paneKey: String, state: String, agentType: String?, prompt: String) {
      self.paneKey = paneKey
      self.state = state
      self.agentType = agentType
      self.prompt = prompt
    }

    init?(_ json: JSONValue) {
      guard let paneKey = json["paneKey"]?.stringValue else {
        return nil
      }
      self.paneKey = paneKey
      state = json["state"]?.stringValue ?? "done"
      agentType = json["agentType"]?.stringValue
      prompt = json["prompt"]?.stringValue ?? ""
      taskTitle = json["taskTitle"]?.stringValue
      displayName = json["displayName"]?.stringValue
      conversationName = json["conversationName"]?.stringValue
      lastAssistantMessage = json["lastAssistantMessage"]?.stringValue
      toolName = json["toolName"]?.stringValue
      orcaSessionId = json["orcaSessionId"]?.stringValue
      updatedAt = json["updatedAt"]?.doubleValue
    }
  }

  public var id: String
  public var repoId: String
  public var repo: String
  public var path: String
  public var branch: String
  public var displayName: String
  public var isPinned: Bool
  public var isArchived: Bool
  public var isMainWorktree: Bool
  public var unread: Bool
  /// `active`, `working`, `permission`, `done`, `inactive`, or a value a newer host added.
  public var status: String
  /// The desktop sidebar's finer verdict, when the host sends one.
  public var sidebarStatus: String?
  public var preview: String
  public var comment: String
  public var liveTerminalCount: Int
  public var lastActivityAt: Double?
  public var sortOrder: Double
  public var linkedPR: LinkedPR?
  public var agents: [Agent]
  /// A plain folder rather than a git worktree.
  public var isFolderWorkspace: Bool
  /// Facts the host stamps for Workspace options filters; nil on hosts that predate them.
  public var defaultBranch: Bool?
  public var automationCreated: Bool
  public var cliCreated: Bool
  public var detachedHead: Bool
  public var hasHostSidebarActivity: Bool?
  public var otherClient: Bool
  private var statusMissing = false
  /// Sort stamps from a host that orders rows itself: `needs-you`, `done`, `working`, else rest.
  public var smartTier: String?
  public var smartAt: Double?
  public var sortedByStamps: Bool
  public var manualOrder: Double?
  public var createdAt: Double?
  /// The workspace's board status id (`todo`, `in-progress`…), from the host's own list.
  public var workspaceStatus: String?

  /// No live terminal, unread, or status other than inactive (workspace-row-filtering.ts isWorktreeActive).
  public var isSleeping: Bool {
    if let hasHostSidebarActivity { return !hasHostSidebarActivity }
    return !(unread || (statusMissing ? liveTerminalCount > 0 : status != "inactive"))
  }

  /// The project's default-branch checkout, guessed from the branch on hosts without the flag.
  public var isDefaultBranch: Bool {
    if let defaultBranch { return defaultBranch }
    if isMainWorktree { return !branch.trimmingCharacters(in: .whitespaces).isEmpty }
    let name = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : branch
    return name == "main" || name == "master"
  }

  /// `id:<worktreeId>`, the selector every worktree-scoped call takes.
  public var selector: String { "id:\(id)" }

  /// Activity as the desktop sidebar sees it (getWorktreeStatus): retained terminals alone don't count.
  public var activityStatus: String {
    if hasHostSidebarActivity == false { return "inactive" }
    if status != "inactive" { return status }
    if hasHostSidebarActivity == true { return "active" }
    return liveTerminalCount > 0 && statusMissing ? "active" : status
  }

  /// What the row's status dot shows: the host's agent verdict when it has one, else activity (getWorktreeDotStatus).
  public var displayStatus: String {
    let verdicts: Set<String> = ["permission", "failed", "working", "monitoring", "unconfirmed", "interrupted", "done"]
    if let sidebarStatus, verdicts.contains(sidebarStatus) { return sidebarStatus }
    return activityStatus
  }

  public var needsAttention: Bool {
    displayStatus == "permission" || agents.contains { $0.state == "blocked" || $0.state == "waiting" }
  }

  public var isWorking: Bool {
    displayStatus == "working" || agents.contains { $0.state == "working" }
  }

  public init?(_ json: JSONValue) {
    guard
      let id = json["worktreeId"]?.stringValue,
      let repoId = json["repoId"]?.stringValue
    else {
      return nil
    }
    self.id = id
    self.repoId = repoId
    repo = json["repo"]?.stringValue ?? ""
    path = json["path"]?.stringValue ?? ""
    branch = json["branch"]?.stringValue ?? ""
    displayName = json["displayName"]?.stringValue ?? ""
    isPinned = json["isPinned"]?.boolValue ?? false
    isArchived = json["isArchived"]?.boolValue ?? false
    isMainWorktree = json["isMainWorktree"]?.boolValue ?? false
    unread = json["unread"]?.boolValue ?? false
    status = json["status"]?.stringValue ?? "inactive"
    statusMissing = json["status"]?.stringValue == nil
    sidebarStatus = json["sidebarStatus"]?.stringValue
    preview = json["preview"]?.stringValue ?? ""
    comment = json["comment"]?.stringValue ?? ""
    liveTerminalCount = json["liveTerminalCount"]?.intValue ?? 0
    lastActivityAt = json["lastActivityAt"]?.doubleValue ?? json["lastOutputAt"]?.doubleValue
    sortOrder = json["sortOrder"]?.doubleValue ?? 0
    isFolderWorkspace = json["workspaceKind"]?.stringValue == "folder-workspace"
    defaultBranch = json["defaultBranch"]?.boolValue
    automationCreated = json["automationCreated"]?.boolValue ?? false
    cliCreated = json["cliCreated"]?.boolValue ?? false
    detachedHead = json["detachedHead"]?.boolValue ?? false
    hasHostSidebarActivity = json["hasHostSidebarActivity"]?.boolValue
    otherClient = json["desktopOtherClient"]?.boolValue ?? false
    smartTier = json["smartTier"]?.stringValue
    smartAt = json["smartAt"]?.doubleValue
    sortedByStamps = json["sortedByStamps"]?.boolValue ?? false
    manualOrder = json["manualOrder"]?.doubleValue
    createdAt = json["createdAt"]?.doubleValue
    workspaceStatus = json["workspaceStatus"]?.stringValue
    if let pr = json["linkedPR"], let number = pr["number"]?.intValue {
      linkedPR = LinkedPR(
        number: number, state: pr["state"]?.stringValue ?? "", title: pr["title"]?.stringValue, url: pr["url"]?.stringValue)
    }
    agents = (json["agents"]?.arrayValue ?? []).compactMap(Agent.init)
  }

  public var title: String {
    displayName.isEmpty ? (branch.isEmpty ? path : branch) : displayName
  }
}

/// A project (`repo.list` row). Rows without an id or name are dropped, as the official client does.
public struct Repo: Sendable, Equatable, Identifiable {
  public var id: String
  public var displayName: String
  public var path: String?
  public var badgeColor: String?
  /// The SSH connection of a remote project; nil for a local one.
  public var connectionId: String?

  public init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let displayName = json["displayName"]?.stringValue else {
      return nil
    }
    self.id = id
    self.displayName = displayName
    path = json["path"]?.stringValue
    badgeColor = json["badgeColor"]?.stringValue
    connectionId = json["connectionId"]?.stringValue
  }
}

/// The workspace list held between reads. `worktree.ps` answers in full, as "unchanged", or as a delta
/// of indexes into the rows of the snapshot the request named.
public struct WorktreeCatalog: Sendable, Equatable {
  public private(set) var worktrees: [Worktree] = []
  /// The rows as the host sent them, kept so the list can be cached and read back.
  public private(set) var rawRows: [JSONValue] = []
  /// Sent as `afterSnapshotId`. Never persisted: it only means something to the host that issued it.
  public private(set) var snapshotId: String?

  public enum Outcome: Sendable, Equatable {
    case replaced
    case unchanged
    /// The reply did not fit what is held; the snapshot id is dropped and the caller reads in full.
    case needsFullRead
  }

  public init() {}

  /// The params for the next read.
  public var requestParams: JSONValue {
    var params: [String: JSONValue] = [
      // The host default silently truncates at 200 rows.
      "limit": 10_000,
      "supportsWorktreeVisibilitySourceDefaults": true,
    ]
    if let snapshotId {
      params["afterSnapshotId"] = .string(snapshotId)
      params["acceptRowDelta"] = true
    }
    return .object(params)
  }

  public mutating func apply(_ reply: JSONValue) -> Outcome {
    let nextSnapshotId = reply["snapshotId"]?.stringValue
    // Presence of `worktrees` always wins.
    if let rows = reply["worktrees"]?.arrayValue {
      let parsed = rows.compactMap(Worktree.init)
      // One unreadable row would shift every later delta index, so the whole reply is refused.
      guard parsed.count == rows.count else {
        return invalidate()
      }
      worktrees = parsed
      rawRows = rows
      snapshotId = nextSnapshotId
      return .replaced
    }
    if reply["unchanged"]?.boolValue == true {
      return nextSnapshotId != nil && nextSnapshotId == snapshotId ? .unchanged : invalidate()
    }
    if let rows = reply["rowsFromBase"]?.arrayValue {
      guard snapshotId != nil, reply["baseSnapshotId"]?.stringValue == snapshotId, let nextSnapshotId else {
        return invalidate()
      }
      var next: [Worktree] = []
      var nextRaw: [JSONValue] = []
      next.reserveCapacity(rows.count)
      for row in rows {
        if let index = row.intValue {
          guard worktrees.indices.contains(index) else {
            return invalidate()
          }
          next.append(worktrees[index])
          nextRaw.append(rawRows.indices.contains(index) ? rawRows[index] : .null)
        } else if let worktree = Worktree(row) {
          next.append(worktree)
          nextRaw.append(row)
        } else {
          return invalidate()
        }
      }
      worktrees = next
      rawRows = nextRaw
      snapshotId = nextSnapshotId
      return .replaced
    }
    return invalidate()
  }

  /// A catalog from cached rows: the list as last seen, with no snapshot id, so the next read is a full one.
  public static func restored(rows: [JSONValue]) -> WorktreeCatalog? {
    var catalog = WorktreeCatalog()
    guard !rows.isEmpty, catalog.apply(["worktrees": .array(rows)]) == .replaced else { return nil }
    catalog.snapshotId = nil
    return catalog
  }

  private mutating func invalidate() -> Outcome {
    snapshotId = nil
    return .needsFullRead
  }
}

extension HostAPI {
  /// Marks agents read or unread (`agentActivity.setRead`), at most 500 pane keys a request.
  public func setAgentsRead(_ paneKeys: [String], read: Bool) async throws {
    for start in stride(from: 0, to: paneKeys.count, by: 500) {
      let chunk = paneKeys[start..<min(start + 500, paneKeys.count)].map { JSONValue.string($0) }
      _ = try await connection.request("agentActivity.setRead", ["paneKeys": .array(chunk), "read": .bool(read)])
    }
  }

  /// Takes finished agents off the list (`agentActivity.clear`).
  public func clearAgents(_ paneKeys: [String]) async throws {
    for start in stride(from: 0, to: paneKeys.count, by: 500) {
      let chunk = paneKeys[start..<min(start + 500, paneKeys.count)].map { JSONValue.string($0) }
      _ = try await connection.request("agentActivity.clear", ["paneKeys": .array(chunk)])
    }
  }
}
