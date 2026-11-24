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

/// Advances one line at a time and gives a changed pair a full interval to read.
public struct WorkingAgentRotation {
  public struct Page: Equatable {
    public let indices: [Int]
    public let nextIndex: Int?
    public let didAdvance: Bool
  }

  private var visible: [WorkingAgent.ID] = []
  private var shownAt: TimeInterval = 0
  private var lastStart = 0
  private static let pageSize = 2
  private static let interval: TimeInterval = 3

  public init() {}

  public mutating func page(in agents: [WorkingAgent.ID], at time: TimeInterval, rotating: Bool) -> Page {
    guard agents.count > Self.pageSize else {
      visible = agents
      shownAt = time
      lastStart = 0
      return Page(indices: Array(agents.indices), nextIndex: nil, didAdvance: false)
    }

    let count = agents.count
    let anchor = visible.lazy.compactMap { agents.firstIndex(of: $0) }.first ?? min(lastStart, count - 1)
    let current = [agents[anchor], agents[(anchor + 1) % count]]
    let samePair = visible == current
    let advance = rotating && samePair && time - shownAt >= Self.interval
    let start = advance ? (anchor + 1) % count : anchor
    let indices = [start, (start + 1) % count]
    if advance || !rotating || !samePair { shownAt = time }
    visible = indices.map { agents[$0] }
    lastStart = start
    return Page(indices: indices, nextIndex: (start + Self.pageSize) % count, didAdvance: advance)
  }
}
