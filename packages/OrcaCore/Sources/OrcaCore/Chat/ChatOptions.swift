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
  }

  public var models: [Model]
  public var model: String?
  public var effort: String?
  public var fastMode: Bool?
  /// `default` or `plan`.
  public var interactionMode: String?
  public var acceptsImages: Bool
  public var fastModeSupported: Bool
  public var planModeSupported: Bool

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
        supportsFastMode: model["supportsFastMode"]?.boolValue ?? false)
    }
    let current = json["current"]
    model = current?["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? current?["reportedModel"]?.stringValue
    effort = current?["effort"]?.stringValue ?? current?["reportedEffort"]?.stringValue
    fastMode = current?["fastMode"]?.boolValue
    interactionMode = current?["interactionMode"]?.stringValue
    acceptsImages = json["acceptsImages"]?.boolValue ?? true
    fastModeSupported = json["fastModeSupport"]?["supported"]?.boolValue ?? false
    planModeSupported = current?["interactionMode"] != nil
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

  init(name: String, kind: String, description: String?, argumentHint: String?) {
    self.name = name
    self.kind = kind
    self.description = description
    self.argumentHint = argumentHint
  }
}
