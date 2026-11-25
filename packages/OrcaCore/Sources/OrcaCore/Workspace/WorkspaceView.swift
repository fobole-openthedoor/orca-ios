import Foundation

/// The desktop's Workspace options (`ui.get`'s `ui`), shared by every client of the host.
public struct WorkspaceView: Sendable, Equatable {
  /// `none`, `workspace-status`, `pr-status`, `repo`.
  public var groupBy = "repo"
  /// `name`, `smart`, `recent`, `repo`, `manual`.
  public var sortBy = "smart"
  /// `manual`, `recent`.
  public var projectOrderBy = "manual"
  public var hideSleeping = false
  /// Keeps each project's main checkout out of the Hide sleeping sweep. Absent means on.
  public var alwaysShowDefaultBranch = true
  public var hideDefaultBranch = false
  public var hideAutomationCreated = false
  public var hideCliCreated = false
  public var hideDetachedHead = false
  public var filterRepoIds: [String] = []
  public private(set) var visibleHostIds: Set<String>?
  /// The host's workspace statuses in board order, as named there (workspace-status-defaults.ts).
  public var statuses: [(id: String, label: String)] = WorkspaceView.defaultStatuses

  public static let defaultStatuses: [(id: String, label: String)] = [
    ("todo", "Todo"), ("in-progress", "In progress"), ("in-review", "In review"), ("completed", "Done"),
  ]

  public init() {}

  public static func == (a: WorkspaceView, b: WorkspaceView) -> Bool {
    a.groupBy == b.groupBy && a.sortBy == b.sortBy && a.projectOrderBy == b.projectOrderBy
      && a.hideSleeping == b.hideSleeping && a.alwaysShowDefaultBranch == b.alwaysShowDefaultBranch
      && a.hideDefaultBranch == b.hideDefaultBranch && a.hideAutomationCreated == b.hideAutomationCreated
      && a.hideCliCreated == b.hideCliCreated && a.hideDetachedHead == b.hideDetachedHead
      && a.filterRepoIds == b.filterRepoIds && a.visibleHostIds == b.visibleHostIds && a.statuses.map(\.id) == b.statuses.map(\.id)
      && a.statuses.map(\.label) == b.statuses.map(\.label)
  }

  /// The status a workspace sits under: its own when the host still lists it, else the default.
  public func status(of row: Worktree) -> String {
    if let id = row.workspaceStatus, statuses.contains(where: { $0.id == id }) { return id }
    return statuses.contains { $0.id == "in-progress" } ? "in-progress" : statuses.first?.id ?? "in-progress"
  }

  /// The PR lane a workspace sits in (workspace-pr-groups.ts): `done`, `in-review`, `in-progress`, `closed`.
  public static func prLane(of row: Worktree) -> String {
    guard let pr = row.linkedPR else { return "in-progress" }
    switch pr.state.lowercased() {
    case "draft": return "in-progress"
    case "merged": return "done"
    case "closed": return "closed"
    default: return "in-review"
    }
  }

  init(_ ui: JSONValue) {
    groupBy = ui["groupBy"]?.stringValue ?? groupBy
    sortBy = ui["sortBy"]?.stringValue ?? sortBy
    projectOrderBy = ui["projectOrderBy"]?.stringValue ?? projectOrderBy
    hideSleeping = ui["hideSleepingWorkspaces"]?.boolValue ?? false
    alwaysShowDefaultBranch = ui["alwaysShowDefaultBranchWorkspace"]?.boolValue ?? true
    hideDefaultBranch = ui["hideDefaultBranchWorkspace"]?.boolValue ?? false
    hideAutomationCreated = ui["hideAutomationGeneratedWorkspaces"]?.boolValue ?? false
    hideCliCreated = ui["hideCliCreatedWorkspaces"]?.boolValue ?? false
    hideDetachedHead = ui["hideDetachedHeadWorkspaces"]?.boolValue ?? false
    filterRepoIds = (ui["filterRepoIds"]?.arrayValue ?? []).compactMap(\.stringValue)
    let hosts = (ui["visibleWorkspaceHostIds"]?.arrayValue ?? []).compactMap(\.stringValue)
    if !hosts.isEmpty {
      visibleHostIds = Set(hosts)
    } else if let scope = ui["workspaceHostScope"]?.stringValue, scope == "local" || scope.hasPrefix("runtime:") || scope.hasPrefix("ssh:") {
      visibleHostIds = [scope]
    }
    let listed = (ui["workspaceStatuses"]?.arrayValue ?? []).compactMap { status -> (id: String, label: String)? in
      guard let id = status["id"]?.stringValue, let label = status["label"]?.stringValue else { return nil }
      return (id, label)
    }
    if !listed.isEmpty { statuses = listed }
  }

  /// The `ui.set` fields where `other` differs; only those are sent, so an older host's strict schema and
  /// another client's sibling edits both survive.
  public func changes(to other: WorkspaceView) -> [String: JSONValue] {
    var patch: [String: JSONValue] = [:]
    if groupBy != other.groupBy { patch["groupBy"] = .string(other.groupBy) }
    if sortBy != other.sortBy { patch["sortBy"] = .string(other.sortBy) }
    if projectOrderBy != other.projectOrderBy { patch["projectOrderBy"] = .string(other.projectOrderBy) }
    let flags: [(String, KeyPath<WorkspaceView, Bool>)] = [
      ("hideSleepingWorkspaces", \.hideSleeping),
      ("alwaysShowDefaultBranchWorkspace", \.alwaysShowDefaultBranch),
      ("hideDefaultBranchWorkspace", \.hideDefaultBranch),
      ("hideAutomationGeneratedWorkspaces", \.hideAutomationCreated),
      ("hideCliCreatedWorkspaces", \.hideCliCreated),
      ("hideDetachedHeadWorkspaces", \.hideDetachedHead),
    ]
    for (key, path) in flags where self[keyPath: path] != other[keyPath: path] {
      patch[key] = .bool(other[keyPath: path])
    }
    if filterRepoIds != other.filterRepoIds { patch["filterRepoIds"] = .array(other.filterRepoIds.map { .string($0) }) }
    return patch
  }

  /// This view with every filter off, as the desktop's Clear filters leaves it.
  public var cleared: WorkspaceView {
    var view = self
    view.hideSleeping = false
    view.alwaysShowDefaultBranch = true
    view.hideDefaultBranch = false
    view.hideAutomationCreated = false
    view.hideCliCreated = false
    view.hideDetachedHead = false
    view.filterRepoIds = []
    return view
  }

  public var activeFilterCount: Int {
    [hideSleeping, hideDefaultBranch, hideAutomationCreated, hideCliCreated, hideDetachedHead, !filterRepoIds.isEmpty]
      .filter { $0 }.count
  }

  /// Whether the filters keep `row` (workspace-row-filters.ts). Folder workspaces follow none of them.
  public func keeps(_ row: Worktree, knownRepoIds: Set<String>) -> Bool {
    if row.isArchived { return false }
    if row.isFolderWorkspace { return true }
    if hideDefaultBranch && row.isDefaultBranch { return false }
    if hideAutomationCreated && row.automationCreated { return false }
    if hideCliCreated && row.cliCreated { return false }
    if hideDetachedHead && row.detachedHead { return false }
    let listed = filterRepoIds.filter(knownRepoIds.contains)
    if !listed.isEmpty && !listed.contains(row.repoId) { return false }
    return !hideSleeping || (alwaysShowDefaultBranch && row.isMainWorktree) || !row.isSleeping
  }
}

extension WorkspaceView {
  /// Rows in Sort by order (workspace-list-ordering.ts). A host that stamps its rows decides Agent activity;
  /// an older one is ranked by its saved order, then attention, then Recent.
  public func sorted(_ rows: [Worktree], now: Double = Date().timeIntervalSince1970 * 1000) -> [Worktree] {
    let byStamps = rows.contains(where: \.sortedByStamps)
    func label(_ a: Worktree, _ b: Worktree) -> Bool {
      let order = a.displayName.localizedStandardCompare(b.displayName)
      return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
    // New workspaces keep a five-minute floor so ambient output can't bury them in Recent.
    func recent(_ row: Worktree) -> Double {
      let last = row.lastActivityAt ?? 0
      guard !byStamps, let created = row.createdAt, now < created + 300_000 else { return last }
      return max(last, created + 300_000)
    }
    func tier(_ row: Worktree) -> Int {
      switch row.smartTier {
      case "needs-you": 0
      case "done" where row.unread: 1
      case "working": 2
      default: 3
      }
    }
    let attention = ["permission": 0, "working": 1, "done": 2, "active": 3, "inactive": 4]
    func status(_ row: Worktree) -> String {
      if row.hasHostSidebarActivity == false { return "inactive" }
      return row.status
    }
    // Negative when a sorts first.
    func smart(_ a: Worktree, _ b: Worktree) -> Double {
      if byStamps {
        let (ta, tb) = (tier(a), tier(b))
        if ta != tb { return Double(ta - tb) }
        if ta < 3, (a.smartAt ?? 0) != (b.smartAt ?? 0) { return (b.smartAt ?? 0) - (a.smartAt ?? 0) }
        return recent(b) - recent(a)
      }
      if a.sortOrder != b.sortOrder { return b.sortOrder - a.sortOrder }
      if a.sortOrder != 0 { return 0 }
      let (sa, sb) = (attention[status(a)] ?? 4, attention[status(b)] ?? 4)
      if sa != sb { return Double(sa - sb) }
      return recent(b) - recent(a)
    }
    func manual(_ row: Worktree) -> Double? { row.manualOrder ?? row.sortOrder }
    return rows.sorted { a, b in
      switch sortBy {
      case "name":
        return label(a, b)
      case "recent":
        return recent(a) == recent(b) ? label(a, b) : recent(a) > recent(b)
      case "repo":
        let order = a.repo.localizedStandardCompare(b.repo)
        return order == .orderedSame ? label(a, b) : order == .orderedAscending
      case "manual":
        let (ra, rb) = (manual(a), manual(b))
        if ra != rb { return (ra ?? -.infinity) > (rb ?? -.infinity) }
        return label(a, b)
      default:
        let order = smart(a, b)
        return order == 0 ? label(a, b) : order < 0
      }
    }
  }
}

extension HostAPI {
  public func workspaceView() async throws -> WorkspaceView {
    WorkspaceView(try await connection.request("ui.get", [:])["ui"] ?? [:])
  }

  /// Sends only the fields that changed from `old`.
  public func setWorkspaceView(from old: WorkspaceView, to new: WorkspaceView) async throws {
    let patch = old.changes(to: new)
    guard !patch.isEmpty else { return }
    _ = try await connection.request("ui.set", .object(patch))
  }
}
