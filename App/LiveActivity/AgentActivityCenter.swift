import ActivityKit
import Foundation
import Observation
import OrcaCore

/// Keeps one Live Activity per workspace whose agent is working, from what the paired desktops report.
/// Only work in progress is shown: when the agent stops (finished, failed or waiting for you) the activity
/// goes away at once.
///
/// Activities are keyed by workspace id alone, so the same workspace reached through two pairings of one
/// desktop, or an activity left over from an earlier launch, never shows twice. The app updates activities
/// while it runs; after that the desktop's pushes, through the gateway in this repo, end them (see
/// PushCenter). Each local update sets a stale date, so an activity nothing reaches greys out instead of
/// claiming the agent is still working.
@MainActor
final class AgentActivityCenter {
  static let shared = AgentActivityCenter()

  /// How long an update stays current without another.
  private static let staleAfter: TimeInterval = 10 * 60

  private var activities: [String: Activity<AgentActivityAttributes>] = [:]
  private var lastStates: [String: AgentActivityAttributes.ContentState] = [:]
  private var observing = false

  private init() {}

  /// Starts following every paired desktop; safe to call more than once.
  func start(model: AppModel) {
    guard !observing else { return }
    observing = true
    // Adopt activities that outlived the last launch, so they are updated or ended instead of orphaned.
    for activity in Activity<AgentActivityAttributes>.activities { adopt(activity) }
    Task { [weak self] in
      for await activity in Activity<AgentActivityAttributes>.activityUpdates {
        self?.adopt(activity)
      }
    }
    observe(model)
  }

  /// Takes an activity this center didn't start in this run; a second one for the same workspace ends.
  private func adopt(_ activity: Activity<AgentActivityAttributes>) {
    guard activity.activityState == .active || activity.activityState == .stale else { return }
    guard let key = Self.key(from: activity.attributes.deepLink) else { return }
    if let current = activities[key] {
      if current.id != activity.id { dismiss(activity) }
      return
    }
    activities[key] = activity
  }

  private func observe(_ model: AppModel) {
    withObservationTracking {
      sync(model)
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe(model) }
    }
  }

  private func sync(_ model: AppModel) {
    var working = Set<String>()
    var known = Set<String>()
    var everyHostConnected = true
    for host in model.hosts {
      guard let session = model.session(for: host.id), session.connectionState == .connected else {
        everyHostConnected = false
        continue
      }
      for worktree in session.worktrees where !worktree.isArchived {
        known.insert(worktree.id)
        guard !working.contains(worktree.id),
          let agent = worktree.agents.first(where: { Self.isWorking($0.state) })
        else { continue }
        working.insert(worktree.id)
        update(key: worktree.id, host: session.name, hostId: host.id, worktree: worktree, agent: agent)
      }
    }
    // A workspace a connected desktop lists as not working ends now; one no desktop can see right now
    // keeps its activity until the stale date greys it out.
    for (key, activity) in activities where !working.contains(key) && (known.contains(key) || everyHostConnected) {
      end(activity, key: key)
    }
  }

  private static func isWorking(_ state: String) -> Bool { state == "working" || state == "monitoring" }

  private func update(key: String, host: String, hostId: UUID, worktree: Worktree, agent: Worktree.Agent) {
    // What it is working on: this turn's prompt or task; the last reply belongs to the turn before, and
    // the agent's title is often just the workspace's name.
    let detail = [agent.prompt, agent.taskTitle ?? "", agent.lastAssistantMessage ?? ""]
      .map { $0.replacingOccurrences(of: "\n", with: " ") }.first { !$0.isEmpty } ?? worktree.displayName
    let since = lastStates[key]?.since
      ?? Date(timeIntervalSince1970: (agent.updatedAt ?? Date().timeIntervalSince1970 * 1000) / 1000)
    let state = AgentActivityAttributes.ContentState(phase: .working, detail: String(detail.prefix(160)), since: since)

    if let activity = activities[key] {
      guard state != lastStates[key] else { return }
      lastStates[key] = state
      Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))) }
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let attributes = AgentActivityAttributes(
      hostName: host, workspaceName: worktree.displayName.isEmpty ? worktree.repo : worktree.displayName,
      agentName: Self.agentName(agent.agentType),
      deepLink: Self.deepLink(hostId: hostId, worktreeId: worktree.id))
    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    // A token lets the push gateway end it after the app is gone; a build signed without pushes can't
    // have one, so it falls back to local updates alone.
    guard let activity = (try? Activity.request(attributes: attributes, content: content, pushType: .token))
      ?? (try? Activity.request(attributes: attributes, content: content, pushType: nil))
    else { return }  // Activities off in Settings, or too many running: nothing to show.
    activities[key] = activity
    lastStates[key] = state
  }

  private func end(_ activity: Activity<AgentActivityAttributes>, key: String) {
    activities[key] = nil
    lastStates[key] = nil
    dismiss(activity)
  }

  private func dismiss(_ activity: Activity<AgentActivityAttributes>) {
    let final = AgentActivityAttributes.ContentState(phase: .done, detail: activity.content.state.detail, since: Date())
    Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate) }
  }

  /// A chat on screen saw its agent start working, sooner than the workspace list reports it. Stopping is
  /// left to the list, which knows whether another agent in the workspace is still at it.
  func reportChat(
    hostId: UUID, hostName: String, worktree: Worktree, agentType: String?, working: Bool, detail: String?
  ) {
    guard working else { return }
    var agent = Worktree.Agent.placeholder(agentType: agentType)
    agent.state = "working"
    agent.prompt = detail ?? ""
    agent.updatedAt = Date().timeIntervalSince1970 * 1000
    update(key: worktree.id, host: hostName, hostId: hostId, worktree: worktree, agent: agent)
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

  /// The workspace id in an activity's deep link, which keys it.
  private static func key(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "worktree" }?.value
  }
}
