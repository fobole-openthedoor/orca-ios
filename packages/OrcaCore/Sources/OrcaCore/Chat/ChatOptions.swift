import Foundation

/// What a chat's agent can be switched to, and what it runs with now (`agentSession.options`).
public struct ChatOptions: Sendable, Equatable {
  public struct Choice: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?
  }

  public struct Model: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?
    public var isDefault: Bool
    public var efforts: [Choice]
    public var defaultEffort: String?
    public var supportsFastMode: Bool
    /// Codex's speeds besides Standard (`default`); a model with them shows Speed in place of Fast mode.
    public var serviceTiers: [Choice] = []

    /// The lone tier Codex calls Fast, which toggles like Claude's Fast mode (native-chat-session-speed-tiers.ts).
    public var loneFastTier: Choice? {
      guard serviceTiers.count == 1, let tier = serviceTiers.first,
        tier.label.lowercased() == "fast" || tier.id.lowercased() == "fast"
      else { return nil }
      return tier
    }
  }

  public var models: [Model]
  public var model: String?
  public var effort: String?
  public var fastMode: Bool?
  /// The chosen speed tier, `default` for Standard.
  public var serviceTier: String?
  /// `default` or `plan`.
  public var interactionMode: String?
  public var acceptsImages: Bool
  public var fastModeSupported: Bool
  public var planModeSupported: Bool
  /// The thread's goal, when the agent keeps one (`/goal`).
  public var goal: Goal?
  /// The host changes goals itself (pause, resume, clear); otherwise only the agent's `/goal clear` does.
  public var goalsChangeable = false
  /// How full the context window is, as last learned (agent-session-context-usage.ts).
  public var contextUsage: ContextUsage?

  public struct ContextUsage: Sendable, Equatable {
    public struct Category: Sendable, Equatable {
      public var name: String
      public var tokens: Int
      /// Loaded on demand, so outside the used count.
      public var deferred: Bool
    }

    public var usedTokens: Int
    public var windowTokens: Int
    /// Rounded and unclamped: an over-limit session reads above 100.
    public var percentage: Double
    /// From the last response's token counts rather than the provider's own report.
    public var estimated: Bool
    /// The provider's breakdown, largest first; empty for an estimate.
    public var categories: [Category]

    init?(_ json: JSONValue?) {
      guard let used = json?["used"] else { return nil }
      switch used["kind"]?.stringValue {
      case "report":
        usedTokens = used["usedTokens"]?.intValue ?? 0
        windowTokens = used["windowTokens"]?.intValue ?? 0
        percentage = used["percentage"]?.doubleValue ?? 0
        estimated = false
        categories = (used["categories"]?.arrayValue ?? []).compactMap { row in
          guard let name = row["name"]?.stringValue, let tokens = row["tokens"]?.intValue, tokens > 0 else { return nil }
          return Category(name: name, tokens: tokens, deferred: row["deferred"]?.boolValue ?? false)
        }.sorted { $0.tokens > $1.tokens }
      case "estimate":
        let usage = used["usage"]
        guard let window = json?["window"]?["tokens"]?.intValue, window > 0 else { return nil }
        usedTokens = ["inputTokens", "cacheCreationInputTokens", "cacheReadInputTokens"]
          .compactMap { usage?[$0]?.intValue }.reduce(0, +)
        windowTokens = window
        percentage = (Double(usedTokens) / Double(window) * 100).rounded()
        estimated = true
        categories = []
      default:
        return nil
      }
    }
  }

  public struct Goal: Sendable, Equatable {
    public var objective: String
    /// `active`, `paused`, `blocked`, `limited`, `complete`…
    public var status: String
    public var timeUsedSeconds: Double
    public var tokensUsed: Int
    /// The host changes it (agentSession.threadGoal: pause, resume, clear); otherwise only the agent's own
    /// `/goal clear` reaches it, and there is no pause (agent-session-thread-goal-report.ts).
    public var hostChanges: Bool = false

    public init(objective: String, status: String, timeUsedSeconds: Double, tokensUsed: Int, hostChanges: Bool = false) {
      self.objective = objective
      self.status = status
      self.timeUsedSeconds = timeUsedSeconds
      self.tokensUsed = tokensUsed
      self.hostChanges = hostChanges
    }
  }

  public init(_ json: JSONValue) {
    func choice(_ value: JSONValue) -> Choice? {
      guard let id = value["value"]?.stringValue ?? value["id"]?.stringValue else {
        return nil
      }
      return Choice(id: id, label: value["label"]?.stringValue ?? id, description: value["description"]?.stringValue)
    }
    models = (json["models"]?.arrayValue ?? []).compactMap { model in
      guard let id = model["id"]?.stringValue, !id.isEmpty else {
        return nil
      }
      return Model(
        id: id, label: model["label"]?.stringValue ?? id, description: model["description"]?.stringValue,
        isDefault: model["isDefault"]?.boolValue ?? false,
        efforts: (model["efforts"]?.arrayValue ?? []).compactMap(choice),
        defaultEffort: model["defaultEffort"]?.stringValue,
        supportsFastMode: model["supportsFastMode"]?.boolValue ?? false,
        serviceTiers: (model["serviceTiers"]?.arrayValue ?? []).compactMap(choice))
    }
    let current = json["current"]
    model = current?["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? current?["reportedModel"]?.stringValue
    effort = current?["effort"]?.stringValue ?? current?["reportedEffort"]?.stringValue
    fastMode = current?["fastMode"]?.boolValue
    serviceTier = current?["serviceTier"]?.stringValue
    interactionMode = current?["interactionMode"]?.stringValue
    acceptsImages = json["acceptsImages"]?.boolValue ?? true
    fastModeSupported = json["fastModeSupport"]?["supported"]?.boolValue ?? false
    planModeSupported = current?["interactionMode"] != nil
    contextUsage = ContextUsage(json["contextUsage"]?["current"])
    goalsChangeable = json["threadGoal"] != nil && json["threadGoal"] != .null
    if let raw = json["threadGoal"]?["current"] ?? json["reportedThreadGoal"]?["current"], let objective = raw["objective"]?.stringValue {
      goal = Goal(
        objective: objective, status: raw["status"]?.stringValue ?? "active",
        timeUsedSeconds: raw["timeUsedSeconds"]?.doubleValue ?? 0, tokensUsed: raw["tokensUsed"]?.intValue ?? 0,
        hostChanges: json["threadGoal"] != nil)
    }
  }

  public var currentModel: Model? {
    models.first { $0.id == model } ?? models.first { $0.isDefault }
  }

  /// The chip's text: the model and, when it has levels, the effort.
  public var summary: String? {
    guard let current = currentModel else {
      return model
    }
    let level = effort.flatMap { effort in current.efforts.first { $0.id == effort }?.label }
    return [current.label, level].compactMap { $0 }.joined(separator: " · ")
  }
}

/// A slash command or skill the agent offers (`agentSession.commands`).
public struct ChatCommand: Sendable, Equatable, Identifiable {
  public var name: String
  /// `command` or `skill`.
  public var kind: String
  public var description: String?
  public var argumentHint: String?

  public var id: String { kind + ":" + name }

  public init(name: String, kind: String = "command", description: String?, argumentHint: String?) {
    self.name = name
    self.kind = kind
    self.description = description
    self.argumentHint = argumentHint
  }

  /// `/side` and its alias `/btw`: a side question asked in a fork beside the chat, never sent to the agent
  /// (native-chat-side-chat-command.ts).
  public static let sideChatCommands = ["side", "btw"]

  /// The question of a `/side …` or `/btw …` message; nil for anything else.
  public static func sideQuestion(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    let parts = trimmed.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard let name = parts.first, sideChatCommands.contains(name.lowercased()) else { return nil }
    return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
  }

  init?(_ json: JSONValue) {
    guard let name = json["name"]?.stringValue, !name.isEmpty else {
      return nil
    }
    self.name = name.hasPrefix("/") ? String(name.dropFirst()) : name
    kind = json["kind"]?.stringValue ?? "command"
    description = json["description"]?.stringValue
    argumentHint = json["argumentHint"]?.stringValue
  }

  /// The two commands the host runs itself rather than sending them to the agent as text.
  public static let conversationCommands = ["clear", "compact"]

  /// Matches for what follows the slash, best first.
  public static func matching(_ query: String, in commands: [ChatCommand]) -> [ChatCommand] {
    let needle = query.lowercased()
    let builtIns = conversationCommands.filter { name in !commands.contains { $0.name == name } }.map {
      ChatCommand(name: $0, kind: "command", description: nil, argumentHint: nil)
    }
    let all = builtIns + commands
    if needle.isEmpty {
      return all
    }
    return all.filter { $0.name.lowercased().hasPrefix(needle) } + all.filter {
      !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
    }
  }

}
