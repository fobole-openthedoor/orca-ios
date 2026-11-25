import Foundation

/// The parent and its descendants, in catalog order.
public struct LineageBranch<Value: Sendable>: Sendable {
  public let entry: Value
  public let children: [LineageBranch<Value>]

  static func build<Key: Hashable>(_ rows: [Value], id: (Value) -> Key, parent: (Value) -> Key?) -> [Self] {
    var seen = Set<Key>()
    let unique = rows.filter { seen.insert(id($0)).inserted }
    let parentIDs = seen
    var roots: [Value] = []
    var children: [Key: [Value]] = [:]
    for row in unique {
      if let owner = parent(row), owner != id(row), parentIDs.contains(owner) {
        children[owner, default: []].append(row)
      } else {
        roots.append(row)
      }
    }

    seen.removeAll()
    func branch(_ row: Value) -> Self? {
      let key = id(row)
      guard seen.insert(key).inserted else { return nil }
      return Self(entry: row, children: (children[key] ?? []).compactMap(branch))
    }
    var result = roots.compactMap(branch)
    // A cyclic component has no valid root. Keep each of its rows available.
    result += unique.filter { !seen.contains(id($0)) }.map { Self(entry: $0, children: []) }
    return result
  }
}

public typealias AgentBranch<Value: Sendable> = LineageBranch<Value>

extension Worktree.Agent {
  /// A provider subagent lives in its owning pane and has no tab of its own.
  public struct Child: Sendable, Equatable, Identifiable {
    public let id: String
    public let parentId: String?
    public let label: String?
    public let state: String
    public let agentType: String?
    let providerId: String?
    public let detail: String?
    public let updatedAt: Double?
    let settled: Bool

    init?(_ json: JSONValue, legacy: Bool, unverifiable: Bool) {
      guard legacy || json["kind"]?.stringValue == "agent",
        let id = json["id"]?.stringValue, !id.isEmpty
      else { return nil }
      self.id = id
      parentId = json["parentChildWorkId"]?.stringValue
      label = [json["description"]?.stringValue, json["name"]?.stringValue, json["agentType"]?.stringValue]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
      agentType = json["agentType"]?.stringValue
      providerId = json["providerId"]?.stringValue
      settled = json["membership"]?.stringValue == "settled"
      let reported = json["state"]?.stringValue ?? "unverifiable"
      switch (settled, json["outcome"]?.stringValue) {
      case (true, "succeeded"): state = "done"
      case (true, "failed"): state = "failed"
      case (true, "cancelled"): state = "interrupted"
      case (true, _): state = "unconfirmed"
      case (false, _) where unverifiable && reported != "idle": state = "unverifiable"
      default: state = reported
      }
      let operation = json["operation"]
      if state == "working", let tool = operation?["toolName"]?.stringValue {
        detail = [tool, operation?["input"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
      } else {
        detail = json["lastMessage"]?.stringValue
      }
      updatedAt = json["observedAt"]?.doubleValue ?? json["startedAt"]?.doubleValue
    }
  }

  /// Workspace cards use the catalog's pane relationships. The Agents tab uses the desktop list's verdict
  /// and can pass every workspace on one host, so it also finds workers that live in another workspace.
  public static func lineage(_ rows: [Self], forAgentsTab: Bool = false) -> [AgentBranch<Self>] {
    AgentBranch.build(rows, id: \.paneKey) { forAgentsTab ? $0.listParentPaneKey : $0.parentPaneKey }
  }

  public var childLineage: [AgentBranch<Child>] {
    func runningBranch(_ branch: AgentBranch<Child>) -> AgentBranch<Child>? {
      let children = branch.children.compactMap(runningBranch)
      guard !branch.entry.settled || !children.isEmpty else { return nil }
      return AgentBranch(entry: branch.entry, children: children)
    }
    return AgentBranch.build(children, id: \.id, parent: \.parentId).compactMap(runningBranch)
  }
}
