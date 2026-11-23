import Foundation

/// A position in a chat's journal. Sequence 0 is before the first row.
public struct TranscriptCursor: Sendable, Equatable {
  public var epoch: String
  public var sequence: Int

  init?(_ json: JSONValue?) {
    guard let epoch = json?["epoch"]?.stringValue, let sequence = json?["sequence"]?.intValue else {
      return nil
    }
    self.epoch = epoch
    self.sequence = sequence
  }

  public var json: JSONValue {
    ["epoch": .string(epoch), "sequence": .number(Double(sequence))]
  }
}

/// One row of a chat transcript. `body.kind` and every enum inside are open: a host may send values
/// this build has never seen, and those must degrade to something drawable, never fail the page.
public struct TranscriptItem: Sendable, Equatable, Identifiable {
  public struct ToolCall: Sendable, Equatable {
    public var name: String
    public var input: JSONValue
    public var callId: String?
    /// `running`, `completed`, `failed`.
    public var state: String
    public var output: String?
    public var outputTruncated: Bool
    public var exitCode: Int?
    public var durationMs: Double?

    init(_ json: JSONValue) {
      name = json["name"]?.stringValue ?? ""
      input = json["input"] ?? .null
      callId = json["callId"]?.stringValue
      state = json["state"]?.stringValue ?? "completed"
      output = json["output"]?["head"]?.stringValue
      outputTruncated = json["output"]?["truncated"]?.boolValue ?? false
      exitCode = json["exitCode"]?.intValue
      durationMs = json["durationMs"]?.doubleValue
    }

    /// The one line a collapsed tool row shows: the command, path, pattern or URL it was called with.
    public var summary: String {
      for key in ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"] {
        if let value = input[key]?.stringValue, !value.isEmpty {
          return value
        }
      }
      if let text = input.stringValue {
        return text
      }
      return ""
    }
  }

  public enum Block: Sendable, Equatable {
    case text(String, tone: String?)
    case toolCall(ToolCall)
    case toolResult(output: String, isError: Bool, callId: String?)
    /// An image by host path or by URL; exactly one is set.
    case image(path: String?, url: String?)
    case subagent(label: String, state: String)
    case other(type: String)

    init(_ json: JSONValue) {
      let type = json["type"]?.stringValue ?? ""
      switch type {
      case "text":
        self = .text(json["text"]?.stringValue ?? "", tone: json["tone"]?.stringValue)
      case "tool-call":
        self = .toolCall(ToolCall(json))
      case "tool-result":
        self = .toolResult(
          output: json["output"]?.stringValue ?? "", isError: json["isError"]?.boolValue ?? false,
          callId: json["callId"]?.stringValue)
      case "image-ref":
        self = .image(path: json["path"]?.stringValue, url: json["url"]?.stringValue)
      case "subagent":
        self = .subagent(label: json["label"]?.stringValue ?? "", state: json["state"]?.stringValue ?? "")
      default:
        self = .other(type: type)
      }
    }
  }

  public struct Message: Sendable, Equatable {
    /// `user`, `assistant`, `tool`, `reasoning`, `system`.
    public var role: String
    public var blocks: [Block]
    /// Still being written by the agent.
    public var isStreaming: Bool
    /// A `/compact` or `/clear` the user sent.
    public var commandName: String?
    /// Who Orca delivered it for: `bot-created` is Orca's own first turn to a new bot, drawn as a notice.
    public var origin: String? = nil

    /// The message's text blocks joined, which is what copy and the bubble use.
    public var text: String {
      blocks.compactMap { block in
        if case .text(let text, _) = block {
          return text
        }
        return nil
      }.joined(separator: "\n\n")
    }

    public var imagePaths: [String] {
      blocks.compactMap { block in
        if case .image(let path, _) = block {
          return path
        }
        return nil
      }
    }
  }

  public struct PromptOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always`, when the host classifies the option.
    public var intent: String?

    init?(_ json: JSONValue) {
      guard let id = json["id"]?.stringValue else {
        return nil
      }
      self.id = id
      label = json["label"]?.stringValue ?? id
      description = json["description"]?.stringValue
      intent = json["intent"]?.stringValue
    }

    public var isRejection: Bool {
      intent?.hasPrefix("reject") ?? false
    }
  }

  /// An approval or question card.
  public struct Prompt: Sendable, Equatable {
    public var title: String
    public var detail: String?
    public var options: [PromptOption]
    /// `pending`, `resolved`, `cancelled`.
    public var resolutionState: String
    public var selectedOptionId: String?

    public var isPending: Bool { resolutionState == "pending" }
  }

  public struct Turn: Sendable, Equatable {
    public var turnId: String
    /// `running`, `completed`, `interrupted`, `unverifiable`.
    public var state: String
    public var startedAt: Double?
    public var durationMs: Double?
  }

  public enum Body: Sendable, Equatable {
    case message(Message)
    case toolCall(ToolCall)
    case diff(path: String, patch: String, truncated: Bool)
    case approval(Prompt)
    case question(Prompt)
    case status(text: String, tone: String?)
    case turn(Turn)
    case other(kind: String)
  }

  public var id: String
  public var revision: Int
  public var sequence: Int
  public var sequenceIndex: Int
  /// Host clock, milliseconds.
  public var observedAt: Double
  /// Set on a subagent's row; nil for the session's own agent.
  public var agentId: String?
  /// The text was cut for the wire; the whole item is read on demand.
  public var shortened: Bool
  public var body: Body

  public init?(_ json: JSONValue) {
    guard let id = json["itemId"]?.stringValue, let body = json["body"] else {
      return nil
    }
    self.id = id
    revision = json["revision"]?.intValue ?? 0
    sequence = json["sequence"]?.intValue ?? 0
    sequenceIndex = json["sequenceIndex"]?.intValue ?? 0
    observedAt = json["observedAt"]?.doubleValue ?? 0
    agentId = json["agentId"]?.stringValue
    shortened = json["shortened"]?.boolValue ?? false
    self.body = Self.body(body)
  }

  private static func body(_ json: JSONValue) -> Body {
    let kind = json["kind"]?.stringValue ?? ""
    switch kind {
    case "message":
      let role = json["role"]?.stringValue ?? "assistant"
      // A reasoning row says so itself; an assistant row is live until it carries a completion time.
      let streaming = json["state"]?.stringValue.map { $0 == "running" } ?? (role == "assistant" && json["completedAt"] == nil)
      return .message(Message(
        role: role,
        blocks: (json["blocks"]?.arrayValue ?? []).map(Block.init),
        isStreaming: streaming,
        commandName: json["command"]?["name"]?.stringValue,
        origin: json["origin"]?.stringValue))
    case "tool-call":
      return .toolCall(ToolCall(json))
    case "diff":
      return .diff(
        path: json["path"]?.stringValue ?? "", patch: json["patch"]?["head"]?.stringValue ?? "",
        truncated: json["patch"]?["truncated"]?.boolValue ?? false)
    case "approval":
      return .approval(prompt(json, title: json["displayName"]?.stringValue ?? json["title"]?.stringValue ?? "", detail: json["detail"]?.stringValue ?? json["description"]?.stringValue))
    case "question":
      return .question(prompt(json, title: json["question"]?.stringValue ?? "", detail: nil))
    case "status":
      return .status(text: json["text"]?.stringValue ?? "", tone: json["tone"]?.stringValue)
    case "turn":
      return .turn(Turn(
        turnId: json["turnId"]?.stringValue ?? "", state: json["state"]?.stringValue ?? "",
        startedAt: json["startedAt"]?.doubleValue, durationMs: json["durationMs"]?.doubleValue))
    default:
      return .other(kind: kind)
    }
  }

  private static func prompt(_ json: JSONValue, title: String, detail: String?) -> Prompt {
    Prompt(
      title: title, detail: detail,
      options: (json["options"]?.arrayValue ?? []).compactMap(PromptOption.init),
      resolutionState: json["resolution"]?["state"]?.stringValue ?? "pending",
      selectedOptionId: json["resolution"]?["selectedOptionId"]?.stringValue)
  }
}

/// The delivery state of one of this client's sends.
public struct TranscriptSubmission: Sendable, Equatable {
  /// The `clientOperationId` the send carried.
  public var clientMessageId: String
  /// `pending`, `accepted`, `rejected`, or `unknown` (delivery unconfirmed: neither sent nor failed).
  public var dispatchState: String
  /// The journal row the message became, once accepted.
  public var providerItemId: String?
  public var reason: String?

  init?(_ json: JSONValue) {
    guard let id = json["clientMessageId"]?.stringValue else {
      return nil
    }
    clientMessageId = id
    dispatchState = json["dispatchState"]?.stringValue ?? "unknown"
    providerItemId = json["providerItemId"]?.stringValue
    reason = json["reason"]?.stringValue
  }
}

/// A chat's transcript as built from `agentSession.subscribe` frames and history pages.
/// Frames are cursor-qualified current states, not deltas: applying one twice converges.
public struct ChatTranscript: Sendable, Equatable {
  /// In journal order.
  public private(set) var items: [TranscriptItem] = []
  public private(set) var submissions: [String: TranscriptSubmission] = [:]
  /// The latest fence seen; every write names it.
  public private(set) var fence: Int?
  /// The last applied position, to resume a dropped stream from.
  public private(set) var cursor: TranscriptCursor?
  public private(set) var oldestCursor: TranscriptCursor?
  public private(set) var hasOlder = false
  /// The host's own "is it busy" verdict, when it sends one.
  public private(set) var hostWorking: Bool?
  /// The ephemeral "what it is doing" line.
  public private(set) var activity: String?
  /// The prompts that can still be answered, when the host says; nil on hosts that do not.
  public private(set) var actionablePromptIds: Set<String>?
  public private(set) var ended = false

  private var byId: [String: TranscriptItem] = [:]

  public init() {}

  /// Applies one stream frame. Unknown frame types are ignored.
  public mutating func apply(_ frame: JSONValue) {
    switch frame["type"]?.stringValue {
    case "snapshot", "reset":
      byId = [:]
      submissions = [:]
      oldestCursor = nil
      if let page = frame["page"] {
        merge(page: page, replacingWindow: true)
      }
      noteFence(frame["fence"])
      noteExtras(frame)
    case "batch":
      guard let batch = frame["batch"] else {
        return
      }
      if let next = TranscriptCursor(batch["cursor"]) {
        if let cursor, cursor.epoch != next.epoch {
          // The journal was renumbered; nothing held is comparable any more.
          byId = [:]
          oldestCursor = nil
        }
        cursor = next
      }
      upsert(batch)
      noteFence(frame["fence"])
      noteExtras(frame)
      rebuild()
    case "end":
      ended = true
    default:
      break
    }
  }

  /// Merges an older page from `agentSession.history`.
  public mutating func prepend(page: JSONValue) {
    merge(page: page, replacingWindow: false)
  }

  /// The fence a mutation reply reported.
  public mutating func noteFence(_ fence: Int?) {
    if let fence {
      self.fence = max(fence, self.fence ?? 0)
    }
  }

  /// The running turn, which Stop names.
  public var runningTurnId: String? {
    for item in items.reversed() {
      if case .turn(let turn) = item.body {
        return turn.state == "running" ? turn.turnId : nil
      }
    }
    return nil
  }

  public var isWorking: Bool {
    hostWorking ?? (runningTurnId != nil)
  }

  /// Whether a prompt row can still be answered.
  public func isActionable(_ item: TranscriptItem) -> Bool {
    let pending: Bool
    switch item.body {
    case .approval(let prompt), .question(let prompt):
      pending = prompt.isPending
    default:
      return false
    }
    return pending && (actionablePromptIds?.contains(item.id) ?? true)
  }

  private mutating func merge(page: JSONValue, replacingWindow: Bool) {
    upsert(page)
    noteFence(page["fence"])
    let window = page["window"]
    if replacingWindow {
      cursor = TranscriptCursor(page["liveCursor"]) ?? TranscriptCursor(window?["newest"]) ?? TranscriptCursor(window?["nextCursor"])
      hostWorking = page["working"]?.boolValue
      actionablePromptIds = (page["actionablePromptIds"]?.arrayValue).map { Set($0.compactMap(\.stringValue)) }
    }
    // Only a page that reaches further back moves the paging position.
    if page["direction"]?.stringValue != "after" {
      if let oldest = TranscriptCursor(window?["oldest"]) ?? (replacingWindow ? nil : TranscriptCursor(window?["nextCursor"])) {
        oldestCursor = oldest
      }
      hasOlder = page["hasOlder"]?.boolValue ?? false
    }
    rebuild()
  }

  private mutating func upsert(_ container: JSONValue) {
    for item in (container["items"]?.arrayValue ?? []).compactMap(TranscriptItem.init) {
      if let held = byId[item.id], held.revision > item.revision {
        continue
      }
      byId[item.id] = item
    }
    for id in (container["removedItemIds"]?.arrayValue ?? []).compactMap(\.stringValue) {
      byId[id] = nil
    }
    for submission in (container["submissions"]?.arrayValue ?? []).compactMap(TranscriptSubmission.init) {
      submissions[submission.clientMessageId] = submission
    }
  }

  private mutating func noteFence(_ json: JSONValue?) {
    noteFence(json?.intValue)
  }

  private mutating func noteExtras(_ frame: JSONValue) {
    if let working = frame["working"]?.boolValue {
      hostWorking = working
    }
    // Absent means unchanged; null clears.
    if let activity = frame["activity"] {
      self.activity = activity["text"]?.stringValue
    }
    if let ids = frame["actionablePromptIds"]?.arrayValue {
      actionablePromptIds = Set(ids.compactMap(\.stringValue))
    }
  }

  private mutating func rebuild() {
    // Journal order, never arrival or clock order.
    items = byId.values.sorted { ($0.sequence, $0.sequenceIndex, $0.id) < ($1.sequence, $1.sequenceIndex, $1.id) }
  }
}
