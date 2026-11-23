import Foundation

/// Identity metadata suitable for the status-only picture-in-picture display.
public struct WorkingAgent: Equatable, Sendable, Identifiable {
  public struct ID: Hashable, Sendable {
    public let host: UUID
    public let pane: String
    public let child: String?
  }

  public let id: ID
  public let workspace: String
  public let name: String?
  public let agentType: String?
  public let isWorker: Bool
  public let structuredSessionId: String?
  public let journalAgentId: String?
  public var isSubagent: Bool { id.child != nil }

  public static func inCatalog(_ worktrees: [Worktree], host: UUID) -> [Self] {
    var panes = Set<String>()
    var result: [Self] = []
    let relevant = worktrees.filter { !$0.isArchived && !$0.agents.isEmpty }
    for worktree in relevant.sorted(by: { $0.id < $1.id }) {
      // A nameless workspace can keep its path private on an overlay.
      let workspace = worktree.displayName.isEmpty ? worktree.repo : worktree.displayName
      for agent in worktree.agents.sorted(by: { $0.paneKey < $1.paneKey }) where panes.insert(agent.paneKey).inserted {
        guard !agent.restoredUnconfirmed else { continue }
        if agent.isActivelyWorking {
          result.append(Self(
            id: ID(host: host, pane: agent.paneKey, child: nil), workspace: workspace,
            name: agent.displayName.flatMap { $0.isEmpty ? nil : $0 },
            agentType: agent.agentType, isWorker: agent.parentPaneKey != nil || agent.listParentPaneKey != nil,
            structuredSessionId: agent.structuredSessionId, journalAgentId: nil))
        }
        var children = Set<String>()
        for child in agent.children.sorted(by: { $0.id < $1.id }) where child.state == "working" && children.insert(child.id).inserted {
          result.append(Self(
            id: ID(host: host, pane: agent.paneKey, child: child.id), workspace: workspace, name: nil,
            agentType: child.agentType, isWorker: false,
            structuredSessionId: agent.structuredSessionId, journalAgentId: child.providerId))
        }
      }
    }
    return result
  }
}

/// Keeps each two-agent page readable for a full interval even as the roster changes.
public struct WorkingAgentRotation {
  private var selected: WorkingAgent.ID?
  private var shownAt: TimeInterval = 0
  private var lastStart = 0
  public static let pageSize = 2
  private static let interval: TimeInterval = 4

  public init() {}

  public mutating func page(in agents: [WorkingAgent.ID], at time: TimeInterval, rotating: Bool) -> Range<Int> {
    guard !agents.isEmpty else {
      selected = nil
      lastStart = 0
      return 0..<0
    }
    let pageSize = Self.pageSize
    let start: Int
    if let selected, let existing = agents.firstIndex(of: selected) {
      let current = existing - existing % pageSize
      let hasOtherPages = agents.count > pageSize
      if rotating && hasOtherPages && time - shownAt >= Self.interval {
        let next = current + pageSize
        start = next < agents.count ? next : 0
        shownAt = time
      } else {
        start = current
        if !rotating || !hasOtherPages { shownAt = time }
      }
    } else {
      let fallback = min(lastStart, agents.count - 1)
      start = fallback - fallback % pageSize
      shownAt = time
    }
    selected = agents[start]
    lastStart = start
    return start..<min(start + pageSize, agents.count)
  }
}
