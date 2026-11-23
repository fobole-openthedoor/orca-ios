import Foundation

/// A past agent conversation the desktop found on disk (`aiVault.listSessions` row).
public struct AgentHistorySession: Sendable, Equatable, Identifiable {
  public struct Message: Sendable, Equatable {
    /// `user`, `assistant`, `system`, `tool` or `unknown`.
    public var role: String
    public var text: String
    public var timestamp: String?
  }

  public var id: String
  /// The agent's id (`claude`, `codex`…).
  public var agent: String
  /// The agent's own resume id; empty when the transcript has none.
  public var sessionId: String
  public var title: String
  public var cwd: String?
  public var cwdAliases: [String]
  public var branch: String?
  public var model: String?
  /// ISO 8601.
  public var createdAt: String?
  public var updatedAt: String?
  public var modifiedAt: String
  public var messageCount: Int
  public var totalTokens: Int
  public var previewMessages: [Message]
  public var queuedMessageCount: Int
  public var subagentTranscriptCount: Int
  /// The shell command that continues this conversation in a terminal.
  public var resumeCommand: String
  public var isSubagent: Bool
  public var forked: Bool
  /// Present when a native chat in a workspace holds this conversation: that chat's session and workspace.
  public var structuredSessionId: String?
  public var structuredWorkspaceId: String?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let agent = json["agent"]?.stringValue else { return nil }
    self.id = id
    self.agent = agent
    sessionId = json["sessionId"]?.stringValue ?? ""
    title = json["title"]?.stringValue ?? ""
    cwd = json["cwd"]?.stringValue
    cwdAliases = (json["cwdAliases"]?.arrayValue ?? []).compactMap(\.stringValue)
    branch = json["branch"]?.stringValue
    model = json["model"]?.stringValue
    createdAt = json["createdAt"]?.stringValue
    updatedAt = json["updatedAt"]?.stringValue
    modifiedAt = json["modifiedAt"]?.stringValue ?? ""
    messageCount = json["messageCount"]?.intValue ?? 0
    totalTokens = json["totalTokens"]?.intValue ?? 0
    previewMessages = (json["previewMessages"]?.arrayValue ?? []).compactMap { message in
      guard let text = message["text"]?.stringValue else { return nil }
      return Message(
        role: message["role"]?.stringValue ?? "unknown", text: text, timestamp: message["timestamp"]?.stringValue)
    }
    queuedMessageCount = json["queuedMessageCount"]?.intValue ?? 0
    subagentTranscriptCount = json["subagentTranscriptCount"]?.intValue ?? 0
    resumeCommand = json["resumeCommand"]?.stringValue ?? ""
    isSubagent = json["subagent"].map { !$0.isNull } ?? false
    forked = json["forked"]?.boolValue ?? false
    structuredSessionId = json["structuredSession"]?["sessionId"]?.stringValue
    structuredWorkspaceId = json["structuredSession"]?["workspaceId"]?.stringValue
  }

  /// When the conversation last changed, else when its file did.
  public var updatedDate: Date? { Self.date(updatedAt) ?? Self.date(modifiedAt) }
  public var createdDate: Date? { Self.date(createdAt) ?? updatedDate }

  /// The newest user or assistant turn, for the row's preview line.
  public var latestTurn: Message? {
    previewMessages.last { ($0.role == "user" || $0.role == "assistant") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  /// A conversation with nothing in it: hidden, as the official list hides it.
  public var isEmpty: Bool {
    messageCount == 0 && latestTurn == nil && queuedMessageCount == 0 && subagentTranscriptCount == 0
  }

  /// The agent's name as the desktop shows it.
  public var agentLabel: String { Self.agentLabels[agent] ?? agent.capitalized }

  public static let agentLabels: [String: String] = [
    "claude": "Claude", "codebuddy": "CodeBuddy", "qoder": "Qoder", "codex": "Codex", "hermes": "Hermes", "pi": "Pi",
    "omp": "OMP", "prime-agent": "Prime Agent", "cursor": "Cursor", "gemini": "Gemini", "antigravity": "Antigravity",
    "rovo": "Rovo Dev", "copilot": "GitHub Copilot", "opencode": "OpenCode", "opencode2": "OpenCode 2",
    "zcode": "ZCode", "grok": "Grok", "openclaw": "OpenClaw", "devin": "Devin", "droid": "Droid", "cline": "Cline",
    "kimi": "Kimi", "muse": "Muse", "jcode": "Jcode", "kiro": "Kiro",
  ]

  private static func date(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}

public struct AgentHistoryListing: Sendable, Equatable {
  public var sessions: [AgentHistorySession]
  /// Transcripts the scan couldn't read.
  public var skippedCount: Int
}

extension HostAPI {
  /// The capability a host advertises in `status.get` when it can list agent history.
  public static let agentHistoryCapability = "aiVault.v1"

  /// Past agent sessions, newest first (`aiVault.listSessions`). `scopePaths` (at most 64) keeps older sessions
  /// in those folders; with `scopeOnly` the host returns only them.
  public func agentHistory(scopePaths: [String] = [], scopeOnly: Bool = false, force: Bool = false) async throws
    -> AgentHistoryListing
  {
    var params: [String: JSONValue] = [
      "limit": 500, "includeAntigravityIdeSessions": true, "force": .bool(force),
    ]
    if !scopePaths.isEmpty {
      params["scopePaths"] = .array(scopePaths.prefix(64).map(JSONValue.string))
      if scopeOnly, scopePaths.count <= 64 { params["scopeOnly"] = true }
    }
    let reply = try await connection.request("aiVault.listSessions", .object(params), timeout: .seconds(60))
    return AgentHistoryListing(
      sessions: (reply["sessions"]?.arrayValue ?? []).compactMap(AgentHistorySession.init),
      skippedCount: reply["issues"]?.arrayValue?.count ?? 0)
  }
}
