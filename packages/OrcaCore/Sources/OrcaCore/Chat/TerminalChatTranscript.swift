import Foundation

/// A terminal transcript is addressed by the provider session reported for its PTY.
public struct TerminalChatSource: Sendable, Equatable {
  public let handle: String
  public let agent: String
  public let sessionId: String
  let transcriptPath: String?

  init?(tab: JSONValue) {
    let status = tab["agentStatus"]
    let provider = status?["providerSession"]
    guard status?["restoredUnconfirmed"]?.boolValue != true, let handle = tab["terminal"]?.stringValue, !handle.isEmpty,
      let agent = status?["agentType"]?.stringValue ?? tab["launchAgent"]?.stringValue,
      ["claude", "openclaude", "codex", "grok", "omp", "opencode", "opencode2", "zcode"].contains(agent),
      let sessionId = provider?["id"]?.stringValue, !sessionId.isEmpty
    else { return nil }
    self.handle = handle
    self.agent = agent
    self.sessionId = sessionId
    transcriptPath = provider?["transcriptPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Grok, OMP and OpenCode require a transcript the desktop's reader can reach locally.
  public func isReadable(connectionId: String?, locationKnown: Bool) -> Bool {
    if ["claude", "openclaude", "codex"].contains(agent) { return true }
    return connectionId?.hasPrefix("runtime-ssh-") ?? locationKnown
  }
}

/// Terminal transcript frames carry provider messages, including calls and results in separate blocks.
/// Adapt them to the same rows used by the structured chat without creating a structured session.
struct TerminalChatTranscript: Sendable {
  static let initialLimit = 40
  private static let maximumMessages = 2_000

  struct Page: Sendable, Equatable {
    let window: Int
    let limit: Int
    let before: Int?
  }

  private struct Message: Sendable {
    let id: String
    let source: Int
    let raw: [String: JSONValue]

    init?(_ json: JSONValue) {
      guard let raw = json.objectValue, let id = raw["id"]?.stringValue, !id.isEmpty else { return nil }
      self.id = id
      self.raw = raw
      self.source = ["transcript": 3, "hook": 2, "scrape": 1][raw["source"]?.stringValue ?? ""] ?? 0
    }
  }

  private var messages: [Message] = []
  private var window = 0
  private var before: Int?
  private var hasMore = false
  private var readLimit = initialLimit
  private var working = false
  private var awaitingSnapshot = true

  var nextPage: Page? {
    guard !awaitingSnapshot, hasMore, messages.count < Self.maximumMessages else { return nil }
    let room = Self.maximumMessages - messages.count
    let limit = before == nil ? min(Self.maximumMessages, max(readLimit, messages.count) + 100) : min(100, room)
    if before == nil, limit <= readLimit { return nil }
    return Page(window: window, limit: limit, before: before)
  }

  var pagingCursor: TranscriptCursor? {
    guard let page = nextPage else { return nil }
    return TranscriptCursor(["epoch": .string("terminal-\(page.window)"), "sequence": .number(Double(page.before ?? page.limit))])
  }

  /// A replay or a provider rewrite replaces the old window. Pending snapshots keep what was already read.
  mutating func apply(_ frame: JSONValue) {
    switch frame["type"]?.stringValue {
    case "snapshot", "replacement":
      window += 1
      if frame["pending"]?.boolValue == true || frame["error"]?.stringValue != nil {
        awaitingSnapshot = true
        working = false
        return
      }
      awaitingSnapshot = false
      readLimit = Self.initialLimit
      let incoming = (frame["messages"]?.arrayValue ?? []).compactMap(Message.init)
      messages = Self.merge([], incoming)
      before = frame["beforeOffset"]?.intValue
      hasMore = frame["hasMore"]?.boolValue ?? (incoming.count >= readLimit)
      working = false
    case "appended":
      let incoming = (frame["messages"]?.arrayValue ?? []).compactMap(Message.init)
      if awaitingSnapshot, !incoming.isEmpty { awaitingSnapshot = false }
      messages = Self.merge(messages, incoming)
      if messages.count > Self.maximumMessages {
        messages.removeFirst(messages.count - Self.maximumMessages)
        // The old cursor preceded rows which were just dropped.
        hasMore = false
      }
    case "end":
      window += 1
      awaitingSnapshot = true
      working = false
    default: return
    }
    if let state = frame["lifecycle"]?["state"]?.stringValue { working = state == "working" }
  }

  mutating func prepend(_ reply: JSONValue, requested page: Page) {
    guard page.window == window, before == page.before, let rows = reply["messages"]?.arrayValue,
      reply["error"]?.stringValue == nil else { return }
    let incoming = rows.compactMap(Message.init)
    let held = Set(messages.map(\.id))
    // A page may arrive after new live rows. Keep their newest states and insert older rows above them.
    let unseen = incoming.filter { !held.contains($0.id) }
    if page.before == nil, let first = messages.first?.id, let overlap = incoming.firstIndex(where: { $0.id == first }) {
      messages = Self.merge(Array(incoming[..<overlap]).filter { !held.contains($0.id) }, messages)
    } else if page.before != nil || messages.isEmpty {
      messages = Self.merge(unseen, messages)
    }
    let oldBefore = before
    before = reply["beforeOffset"]?.intValue
    if page.before == nil { readLimit = page.limit }
    // Some older hosts ignore an unfamiliar cursor. Stop if the returned offset didn't move back.
    hasMore = (reply["hasMore"]?.boolValue ?? (rows.count >= page.limit))
      && (oldBefore.map { old in before.map { $0 < old } ?? false } ?? true)
  }

  private static func merge(_ existing: [Message], _ incoming: [Message]) -> [Message] {
    var result = existing
    var indices = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
    for row in incoming {
      if let index = indices[row.id] {
        if row.source >= result[index].source { result[index] = row }
      } else {
        indices[row.id] = result.count
        result.append(row)
      }
    }
    return result
  }

  func update(_ transcript: inout ChatTranscript) {
    var items: [TranscriptItem] = []
    var toolPositions: [String: Int] = [:]
    var adjacentCalls: [Int] = []
    for (sequence, message) in messages.enumerated() {
      var body = message.raw
      body["kind"] = "message"
      // Legacy transcript rows without a lifecycle are history, even when the agent is still active.
      if body["state"] == nil { body["state"] = "completed" }
      let blocks = body["blocks"]?.arrayValue ?? []
      // Old transcripts without call IDs pair neighboring call/result blocks in their emitted order.
      if !blocks.contains(where: { $0["type"] == "tool-result" }) { adjacentCalls.removeAll(keepingCapacity: true) }
      let content = blocks.filter { !["tool-call", "tool-result"].contains($0["type"]?.stringValue ?? "") }
      body["blocks"] = .array(content)
      let hasMediaOrText = !content.isEmpty || (body["role"] == "user" && body["command"] != nil)
      let rowID = "terminal-message:" + message.id
      if hasMediaOrText, let item = Self.item(body, id: rowID, sequence: sequence, index: 0, message: message) {
        items.append(item)
      }
      for (index, block) in blocks.enumerated() {
        switch block["type"]?.stringValue {
        case "tool-call":
          guard var call = block.objectValue else { continue }
          call["kind"] = "tool-call"
          let callId = call["callId"]?.stringValue
          if let callId { toolPositions[callId] = items.count } else { adjacentCalls.append(items.count) }
          if let item = Self.item(call, id: "terminal-tool:\(index):\(message.id)", sequence: sequence, index: index + 1, message: message) {
            items.append(item)
          }
        case "tool-result":
          let callId = block["callId"]?.stringValue
          let target = callId.flatMap { toolPositions[$0] } ?? (callId == nil && !adjacentCalls.isEmpty ? adjacentCalls.removeFirst() : nil)
          guard let target, items.indices.contains(target), case .toolCall(var call) = items[target].body else { continue }
          call.output = block["output"]?.stringValue
          call.state = block["isError"]?.boolValue == true ? "failed" : "completed"
          items[target].body = .toolCall(call)
        default: break
        }
      }
    }
    transcript.replaceTerminalRows(items, before: pagingCursor, working: working)
  }

  private static func item(_ body: [String: JSONValue], id: String, sequence: Int, index: Int, message: Message) -> TranscriptItem? {
    TranscriptItem([
      "itemId": .string(id), "sequence": .number(Double(sequence)), "sequenceIndex": .number(Double(index)),
      "observedAt": message.raw["timestamp"] ?? 0, "body": .object(body),
      "shortened": message.raw["shortened"] ?? false,
    ])
  }
}
