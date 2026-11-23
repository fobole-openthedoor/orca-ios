import ActivityKit
import Foundation

/// One agent's run, shown on the Lock Screen and in the Dynamic Island while it works.
/// Compiled into both the app (which starts and updates it) and the widget extension (which draws it).
struct AgentActivityAttributes: ActivityAttributes {
  enum Phase: String, Codable, Hashable {
    case working
    /// Waiting on you: a question, a permission, a plan to approve.
    case needsYou
    case done
    case failed
  }

  struct ContentState: Codable, Hashable {
    var phase: Phase
    /// The agent's latest line, already trimmed to one sentence.
    var detail: String
    /// When this phase began; the Lock Screen counts up from it while working.
    var since: Date
  }

  /// The desktop's display name.
  var hostName: String
  /// The workspace's display name.
  var workspaceName: String
  /// The agent, as the session's tab names it (Claude, Codex…).
  var agentName: String
  /// Opens this workspace's session when the activity is tapped.
  var deepLink: URL
}
