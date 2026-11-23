import ActivityKit
import Foundation
import Observation
import OrcaCore

/// Keeps one Live Activity per workspace whose agent is working, from what the paired desktops report.
///
/// The app updates activities while it runs (including the short time the system gives it after leaving the
/// foreground); after that the desktop's pushes, through the gateway in this repo, update and end them (see
/// PushCenter). Each local update sets a stale date, so an activity nothing reaches greys out instead of
/// claiming the agent is still working.
@MainActor
final class AgentActivityCenter {
  static let shared = AgentActivityCenter()

  /// How long an update stays current without another.
  private static let staleAfter: TimeInterval = 10 * 60
  /// How long a finished activity stays on the Lock Screen.
  private static let dismissAfter: TimeInterval = 10 * 60

  private var activities: [String: Activity<AgentActivityAttributes>] = [:]
  private var lastStates: [String: AgentActivityAttributes.ContentState] = [:]
  private var observing = false

  private init() {}

  /// Starts following every paired desktop; safe to call more than once.
  func start(model: AppModel) {
    guard !observing else { return }
    observing = true
    // Adopt activities that outlived the last launch, so they are updated or ended instead of orphaned.
    for activity in Activity<AgentActivityAttributes>.activities {
      if let key = Self.key(from: activity.attributes.deepLink) { activities[key] = activity }
    }
    observe(model)
  }

  private func observe(_ model: AppModel) {
    withObservationTracking {
      sync(model)
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe(model) }
    }
  }

  private func sync(_ model: AppModel) {
    var seen = Set<String>()
    for host in model.hosts {
      guard let session = model.session(for: host.id) else { continue }
      // Read connection state so a drop re-runs this and lets activities go stale.
      _ = session.connectionState
      for worktree in session.worktrees where !worktree.isArchived {
        guard let agent = Self.primaryAgent(in: worktree) else { continue }
        let key = "\(host.id.uuidString)/\(worktree.id)"
        seen.insert(key)
        update(key: key, host: session.name, hostId: host.id, worktree: worktree, agent: agent)
      }
    }
    for (key, activity) in activities where !seen.contains(key) {
      end(activity, key: key, phase: .done)
    }
  }

  /// The agent worth showing: one that needs you, else one working, else the most recent.
  private static func primaryAgent(in worktree: Worktree) -> Worktree.Agent? {
    let agents = worktree.agents
    return agents.first { phase(for: $0.state) == .needsYou }
      ?? agents.first { phase(for: $0.state) == .working }
      ?? agents.max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }
  }

  private static func phase(for state: String) -> AgentActivityAttributes.Phase? {
    switch state {
    case "working", "monitoring": .working
    case "permission", "waiting", "blocked": .needsYou
    case "failed": .failed
    case "done", "idle", "active": .done
    default: nil
    }
  }

  private func update(key: String, host: String, hostId: UUID, worktree: Worktree, agent: Worktree.Agent) {
    guard let phase = Self.phase(for: agent.state) else { return }
    let detail = [agent.lastAssistantMessage, agent.title].compactMap { $0 }
      .map { $0.replacingOccurrences(of: "\n", with: " ") }.first { !$0.isEmpty } ?? worktree.displayName
    let previous = lastStates[key]
    let since = previous?.phase == phase ? previous!.since : Date(timeIntervalSince1970: (agent.updatedAt ?? Date().timeIntervalSince1970 * 1000) / 1000)
    let state = AgentActivityAttributes.ContentState(phase: phase, detail: String(detail.prefix(160)), since: since)

    if let activity = activities[key] {
      guard state != previous else { return }
      lastStates[key] = state
      if phase == .done || phase == .failed {
        end(activity, key: key, phase: phase, state: state)
      } else {
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))) }
      }
      return
    }
    // A new activity only for work that is happening now; a finished agent never starts one.
    guard phase == .working || phase == .needsYou, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let attributes = AgentActivityAttributes(
      hostName: host, workspaceName: worktree.displayName.isEmpty ? worktree.repo : worktree.displayName,
      agentName: Self.agentName(agent.agentType),
      deepLink: Self.deepLink(hostId: hostId, worktreeId: worktree.id))
    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    // A token lets the push gateway update it after the app is gone; a build signed without pushes can't
    // have one, so it falls back to local updates alone.
    guard let activity = (try? Activity.request(attributes: attributes, content: content, pushType: .token))
      ?? (try? Activity.request(attributes: attributes, content: content, pushType: nil))
    else { return }  // Activities off in Settings, or too many running: nothing to show.
    activities[key] = activity
    lastStates[key] = state
  }

  private func end(
    _ activity: Activity<AgentActivityAttributes>, key: String, phase: AgentActivityAttributes.Phase,
    state: AgentActivityAttributes.ContentState? = nil
  ) {
    activities[key] = nil
    lastStates[key] = nil
    let final = state ?? AgentActivityAttributes.ContentState(
      phase: phase, detail: activity.content.state.detail, since: Date())
    Task {
      await activity.end(
        ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(Self.dismissAfter)))
    }
  }

  /// A chat on screen saw its agent start or stop, faster than the workspace list reports it.
  func reportChat(
    hostId: UUID, hostName: String, worktree: Worktree, agentType: String?, working: Bool, detail: String?
  ) {
    let key = "\(hostId.uuidString)/\(worktree.id)"
    var agent = Worktree.Agent.placeholder(agentType: agentType)
    agent.state = working ? "working" : "done"
    agent.lastAssistantMessage = detail
    agent.updatedAt = Date().timeIntervalSince1970 * 1000
    update(key: key, host: hostName, hostId: hostId, worktree: worktree, agent: agent)
  }

  /// Launch with ORCA_DEBUG_ACTIVITY=1 to show a sample activity, for checking the Lock Screen and Dynamic Island.
  func startSampleIfRequested() {
    guard ProcessInfo.processInfo.environment["ORCA_DEBUG_ACTIVITY"] == "1" else { return }
    let attributes = AgentActivityAttributes(
      hostName: "Mac mini", workspaceName: "explain-greet", agentName: "Claude",
      deepLink: Self.deepLink(hostId: UUID(), worktreeId: "sample"))
    let state = AgentActivityAttributes.ContentState(
      phase: .working, detail: "Reading src/greet.ts to see what an empty name returns", since: Date().addingTimeInterval(-42))
    _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
  }

  private static func agentName(_ type: String?) -> String {
    switch type {
    case "claude", "claude-agent-teams": "Claude"
    case "codex": "Codex"
    case let other?: other.prefix(1).uppercased() + other.dropFirst()
    case nil: "Agent"
    }
  }

  /// orca://open?host=<uuid>&worktree=<id>, which the app routes to the session screen.
  static func deepLink(hostId: UUID, worktreeId: String) -> URL {
    var components = URLComponents()
    components.scheme = "orca"
    components.host = "open"
    components.queryItems = [
      URLQueryItem(name: "host", value: hostId.uuidString), URLQueryItem(name: "worktree", value: worktreeId),
    ]
    return components.url!
  }

  private static func key(from url: URL) -> String? {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let host = items.first(where: { $0.name == "host" })?.value,
      let worktree = items.first(where: { $0.name == "worktree" })?.value
    else { return nil }
    return "\(host)/\(worktree)"
  }
}
