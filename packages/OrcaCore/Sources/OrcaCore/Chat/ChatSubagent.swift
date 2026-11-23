import Foundation

/// A provider's child agent, recorded as an individual or grouped block in the journal.
public struct ChatSubagent: Sendable, Equatable, Identifiable {
  public var id: String
  public var label: String
  public var state: String
  public var parentId: String?
  public var tokens: Int?
  public var startedAt: Double?
  public var settledAt: Double?
  public var agentType: String?
  public var model: String?
  public var effort: String?
  public var operation: String?
  public var lastMessage: String?

  init(id: String, label: String = "", state: String = "unverifiable") {
    self.id = id
    self.label = label
    self.state = state
  }

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
    self.init(id: id, label: json["label"]?.stringValue ?? "", state: json["state"]?.stringValue ?? "unverifiable")
    parentId = json["parentId"]?.stringValue
    tokens = json["tokens"]?.intValue
    startedAt = json["startedAt"]?.doubleValue
    settledAt = json["settledAt"]?.doubleValue
    agentType = json["agentType"]?.stringValue
    model = json["model"]?.stringValue
    effort = json["effort"]?.stringValue
    if let name = json["operation"]?["toolName"]?.stringValue {
      operation = [name, json["operation"]?["input"]?.stringValue].compactMap { $0 }.joined(separator: " ")
    }
    lastMessage = json["lastMessage"]?.stringValue
  }
}

/// An Orca orchestration worker owned by this chat. Its dispatch ID is also the key for its report.
public struct ChatWorker: Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String
  public var agent: String?
  public var state: String
  public var activity: String?
  public var pendingQuestion: Bool
  public var backgroundWait: Bool
  public var summary: String?

  public var isWorking: Bool {
    state == "working" && !pendingQuestion && !backgroundWait
      && (activity == nil || activity == "working" || activity == "unknown")
  }

  public var displayState: String {
    guard state == "working", !isWorking else { return state }
    if activity == "blocked" { return "blocked" }
    return pendingQuestion || backgroundWait || activity == "waiting" ? "waiting" : "idle"
  }

  init?(_ json: JSONValue) {
    guard let id = json["dispatchId"]?.stringValue, !id.isEmpty else { return nil }
    self.id = id
    title = json["title"]?.stringValue ?? ""
    agent = json["agent"]?.stringValue
    state = json["state"]?.stringValue ?? "unverifiable"
    activity = json["activity"]?.stringValue
    pendingQuestion = json["pendingQuestion"]?.boolValue ?? false
    backgroundWait = json["backgroundWait"]?.objectValue != nil
    summary = json["summary"]?.stringValue
  }
}
