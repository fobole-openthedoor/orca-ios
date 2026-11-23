import Foundation

/// A read-only view of a structured session. Keep journal identities and counts in memory, without message text.
public struct AgentActivityMetrics: Sendable {
  public struct Reading: Sendable, Equatable {
    public let estimatedTokensPerSecond: Int?
    public let toolCalls: Int?
    public let toolCountIsPartial: Bool
    public let toolIsRunning: Bool
  }

  private struct Call: Sendable {
    let id: String
    let running: Bool
    let standalone: Bool
  }

  private struct Row: Sendable {
    let id: String
    let revision: Int
    let sequence: Int
    let agentId: String?
    let turnId: String?
    let turnRunning: Bool?
    let calls: [Call]
    let results: [String]
    let textBytes: Int?
    let streaming: Bool

    init?(_ item: JSONValue) {
      guard let id = item["itemId"]?.stringValue, let body = item["body"],
        let revision = item["revision"]?.intValue, let sequence = item["sequence"]?.intValue
      else { return nil }
      self.id = id
      self.revision = revision
      self.sequence = sequence
      agentId = item["agentId"]?.stringValue
      turnId = item["turnScope"]?["turnItemId"]?.stringValue
      let kind = body["kind"]?.stringValue
      let role = body["role"]?.stringValue
      let blocks = body["blocks"]?.arrayValue ?? []
      turnRunning = kind == "turn" ? body["state"]?.stringValue.map { $0 == "running" } : nil
      if kind == "tool-call" {
        calls = [Call(id: body["callId"]?.stringValue ?? "row:\(id)",
          running: body["state"]?.stringValue == "running", standalone: true)]
      } else {
        calls = blocks.enumerated().compactMap { index, block in
          guard block["type"]?.stringValue == "tool-call" else { return nil }
          return Call(id: block["callId"]?.stringValue ?? "row:\(id):\(index)",
            running: block["state"]?.stringValue == "running", standalone: false)
        }
      }
      results = blocks.compactMap { $0["type"]?.stringValue == "tool-result" ? $0["callId"]?.stringValue : nil }
      streaming = body["state"]?.stringValue.map { $0 == "running" }
        ?? (role == "assistant" && body["completedAt"] == nil)
      if kind == "message", role == "assistant" || role == "reasoning", item["shortened"]?.boolValue != true,
        item["recovered"]?.boolValue != true {
        textBytes = blocks.reduce(0) { count, block in
          guard block["type"]?.stringValue == "text" else { return count }
          return count + (block["text"]?.stringValue?.utf8.count ?? 0)
        }
      } else {
        textBytes = nil
      }
    }
  }

  private struct Turn: Sendable {
    let id: String
    let running: Bool
  }

  private struct Sample: Sendable {
    let at: TimeInterval
    let bytes: Int
  }

  private static let interval: TimeInterval = 4
  private static let bytesPerToken = 4.0
  private var cursor: TranscriptCursor?
  private var turn: Turn?
  private var rows: [String: Row] = [:]
  private var samples: [String?: [Sample]] = [:]
  private var hasOlder = true
  private var catchingUp = false

  public init() {}

  public mutating func apply(_ frame: JSONValue, at time: TimeInterval) {
    switch frame["type"]?.stringValue {
    case "snapshot", "reset":
      self = Self()
      guard let page = frame["page"] else { return }
      cursor = TranscriptCursor(page["liveCursor"]) ?? TranscriptCursor(page["window"]?["nextCursor"])
      hasOlder = page["hasOlder"]?.boolValue != false
      catchingUp = page["hasNewer"]?.boolValue == true
      for row in (page["items"]?.arrayValue ?? []).compactMap(Row.init) { rows[row.id] = row }
      noteTurn(frame["latestTurn"] ?? page["latestTurn"])
    case "batch":
      guard let batch = frame["batch"], let next = TranscriptCursor(batch["cursor"]) else { return }
      if cursor?.epoch != next.epoch { self = Self() }
      let previous = cursor
      if let previous, next.sequence < previous.sequence { return }
      let hasNewer = frame["hasNewer"]?.boolValue == true
      let live = previous.map { next.sequence > $0.sequence } == true && !catchingUp && !hasNewer
      cursor = next
      catchingUp = hasNewer
      var growth: [(Row, Row?)] = []
      for row in (batch["items"]?.arrayValue ?? []).compactMap(Row.init) {
        let old = rows[row.id]
        if let old, old.revision >= row.revision { continue }
        rows[row.id] = row
        if live, row.textBytes != nil { growth.append((row, old)) }
      }
      for id in (batch["removedItemIds"]?.arrayValue ?? []).compactMap(\.stringValue) { rows.removeValue(forKey: id) }
      noteTurn(frame["latestTurn"])
      guard live, let previous else { return }

      // Completed full responses, history, recoveries and repeated tool output do not measure live generation.
      for (row, old) in growth where rows[row.id]?.revision == row.revision && (row.turnId == nil || row.turnId == turn?.id) {
        guard let size = row.textBytes else { continue }
        let base: Int
        if let old {
          guard old.agentId == row.agentId, old.streaming, let oldSize = old.textBytes else { continue }
          base = oldSize
        } else {
          guard row.streaming, row.sequence > previous.sequence else { continue }
          base = 0
        }
        if size > base {
          samples[row.agentId, default: []].removeAll { time - $0.at >= Self.interval }
          samples[row.agentId, default: []].append(Sample(at: time, bytes: size - base))
        }
      }
    case "end": self = Self()
    default: break
    }
  }

  private mutating func noteTurn(_ marker: JSONValue?) {
    let previous = turn?.id
    if let marker {
      turn = marker["itemId"]?.stringValue.map { id in
        Turn(id: id, running: marker["turn"]?["state"]?.stringValue == "running")
      }
    } else if let latest = rows.values.filter({ $0.agentId == nil && $0.turnRunning != nil })
      .max(by: { $0.sequence < $1.sequence }) {
      if turn.flatMap({ rows[$0.id] != nil }) != false {
        turn = Turn(id: latest.id, running: latest.turnRunning == true)
      }
    }
    if let id = turn?.id, previous != id {
      samples.removeAll()
      rows = rows.filter { $0.value.turnId == nil || $0.value.turnId == id }
    } else if turn == nil, previous != nil {
      samples.removeAll()
    }
  }

  public func reading(agentId: String?, at time: TimeInterval) -> Reading {
    guard cursor != nil, !catchingUp else {
      return Reading(estimatedTokensPerSecond: nil, toolCalls: nil, toolCountIsPartial: false, toolIsRunning: false)
    }
    let rate = samples[agentId].map { values in
      let bytes = values.filter { time - $0.at < Self.interval }.reduce(0.0) { $0 + Double($1.bytes) }
      return Int((bytes / Self.interval / Self.bytesPerToken).rounded())
    }
    let turnId = turn?.id
    let agentRows = rows.values.filter { $0.agentId == agentId }
    let relevant = agentRows.filter { turnId != nil && $0.turnId == turnId }
    let calls = resolvedCalls(in: relevant)
    let running = (turn?.running == true || agentId != nil) && calls.values.contains(where: \.running)
    let canCount = turnId != nil && (agentId == nil ? turn?.running == true : !relevant.isEmpty)
    let start = turnId.flatMap { rows[$0]?.sequence }
    let unscoped = agentRows.contains { row in
      row.turnId == nil && !row.calls.isEmpty && row.sequence >= (start ?? 0)
    }
    let partial = canCount && ((hasOlder && start == nil) || unscoped)
    return Reading(
      estimatedTokensPerSecond: rate,
      toolCalls: canCount && (!partial || !calls.isEmpty) ? calls.count : nil,
      toolCountIsPartial: partial,
      toolIsRunning: running)
  }

  private func resolvedCalls(in rows: [Row]) -> [String: Call] {
    let results = Set(rows.flatMap(\.results))
    var calls: [String: Call] = [:]
    for call in rows.flatMap(\.calls) {
      if let old = calls[call.id], (old.standalone && !call.standalone || old.standalone == call.standalone && !old.running) {
        continue
      }
      calls[call.id] = Call(id: call.id, running: call.running && !results.contains(call.id), standalone: call.standalone)
    }
    return calls
  }
}
