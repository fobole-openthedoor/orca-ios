import Foundation
import Testing

@testable import OrcaCore

@Suite struct AgentActivityMetricsTests {
  @Test func countsCallsOncePerProducerAndCurrentTurn() {
    var metrics = AgentActivityMetrics()
    metrics.apply(snapshot(sequence: 5, rows: [
      row("turn", sequence: 1, body: ["kind": "turn", "state": "running"], scope: nil),
      row("call", sequence: 2, body: tool("shell", state: "running")),
      row("inline", sequence: 3, body: ["kind": "message", "role": "assistant", "blocks": [["type": "tool-call", "callId": "shell"]]]),
      row("child-call", sequence: 4, agent: "child", body: tool("child-command", state: "completed")),
      row("old-call", sequence: 5, body: tool("old", state: "completed"), scope: "earlier-turn"),
    ]), at: 100)
    #expect(metrics.reading(agentId: nil, at: 100).toolCalls == 1)
    #expect(metrics.reading(agentId: nil, at: 100).toolIsRunning)
    #expect(metrics.reading(agentId: "child", at: 100).toolCalls == 1)
    #expect(!metrics.reading(agentId: "child", at: 100).toolIsRunning)
    #expect(metrics.reading(agentId: "unmapped-child", at: 100).toolCalls == nil)

    let completion = batch(sequence: 6, rows: [row("call", sequence: 2, revision: 2, body: tool("shell", state: "completed"))])
    metrics.apply(completion, at: 101)
    metrics.apply(completion, at: 102)
    #expect(metrics.reading(agentId: nil, at: 102).toolCalls == 1)
    #expect(!metrics.reading(agentId: nil, at: 102).toolIsRunning)

    metrics.apply(batch(sequence: 7, rows: [row("new-turn", sequence: 7, body: ["kind": "turn", "state": "running"], scope: nil)],
      turn: "new-turn"), at: 103)
    #expect(metrics.reading(agentId: nil, at: 103).toolCalls == 0)
    #expect(metrics.reading(agentId: "child", at: 103).toolCalls == nil)
  }

  @Test func startsFromLiveGrowthAndDecaysWhenOutputStops() {
    var metrics = AgentActivityMetrics()
    let base = String(repeating: "a", count: 240)
    metrics.apply(snapshot(sequence: 10, rows: [
      row("stream", sequence: 10, body: message(base)),
    ]), at: 40)
    #expect(metrics.reading(agentId: nil, at: 40).estimatedTokensPerSecond == nil)
    let revision = batch(sequence: 11, rows: [
      row("stream", sequence: 10, revision: 2, body: message(base + String(repeating: "b", count: 48))),
      row("full-reply", sequence: 11, body: message(base, streaming: false)),
    ])
    metrics.apply(revision, at: 41)
    metrics.apply(revision, at: 42)
    #expect(metrics.reading(agentId: nil, at: 42).estimatedTokensPerSecond == 3)
    #expect(metrics.reading(agentId: nil, at: 45).estimatedTokensPerSecond == 0)

    let child = row("child", sequence: 12, agent: "worker", body: message(String(repeating: "c", count: 32)))
    metrics.apply(batch(sequence: 12, rows: [child]), at: 46)
    #expect(metrics.reading(agentId: "worker", at: 47).estimatedTokensPerSecond == 2)
    #expect(metrics.reading(agentId: nil, at: 47).estimatedTokensPerSecond == 0)
    metrics.apply(["type": "end"], at: 48)
    #expect(metrics.reading(agentId: "worker", at: 48).estimatedTokensPerSecond == nil)
  }

  @Test func clippedHistoryAndCatchUpDontLookLikeFreshWork() {
    var metrics = AgentActivityMetrics()
    metrics.apply(snapshot(sequence: 6, rows: [row("call", sequence: 6, body: tool("shell", state: "running"))],
      hasOlder: true), at: 100)
    #expect(metrics.reading(agentId: nil, at: 100).toolCalls == 1)
    #expect(metrics.reading(agentId: nil, at: 100).toolCountIsPartial)

    let text = String(repeating: "a", count: 1_000)
    metrics.apply(batch(sequence: 7, rows: [row("history", sequence: 7, body: message(text))], hasNewer: true), at: 101)
    metrics.apply(batch(sequence: 8, rows: [row("caught-up", sequence: 8, body: message(text))]), at: 102)
    #expect(metrics.reading(agentId: nil, at: 102).estimatedTokensPerSecond == nil)
    metrics.apply(batch(sequence: 9, rows: [], removed: ["call"]), at: 103)
    #expect(metrics.reading(agentId: nil, at: 103).toolCalls == nil)
    #expect(!metrics.reading(agentId: nil, at: 103).toolIsRunning)
  }

  private func row(_ id: String, sequence: Int, revision: Int = 1, agent: String? = nil, body: JSONValue,
    scope: String? = "turn") -> JSONValue {
    var row: [String: JSONValue] = ["itemId": .string(id), "sequence": .number(Double(sequence)),
      "revision": .number(Double(revision)), "body": body]
    if let agent { row["agentId"] = .string(agent) }
    if let scope { row["turnScope"] = ["kind": "turn", "turnItemId": .string(scope)] }
    return .object(row)
  }

  private func tool(_ id: String, state: String) -> JSONValue {
    ["kind": "tool-call", "callId": .string(id), "state": .string(state)]
  }

  private func message(_ text: String, streaming: Bool = true) -> JSONValue {
    ["kind": "message", "role": "assistant", "state": streaming ? "running" : "completed",
      "blocks": [["type": "text", "text": .string(text)]]]
  }

  private func snapshot(sequence: Int, rows: [JSONValue], hasOlder: Bool = false) -> JSONValue {
    ["type": "snapshot", "page": ["liveCursor": cursor(sequence), "items": .array(rows),
      "hasOlder": .bool(hasOlder), "latestTurn": marker("turn")]]
  }

  private func batch(sequence: Int, rows: [JSONValue], removed: [String] = [], turn: String = "turn",
    hasNewer: Bool = false) -> JSONValue {
    ["type": "batch", "latestTurn": marker(turn), "hasNewer": .bool(hasNewer),
      "batch": ["cursor": cursor(sequence), "items": .array(rows), "removedItemIds": .array(removed.map(JSONValue.string))]]
  }

  private func cursor(_ sequence: Int) -> JSONValue {
    ["epoch": "one", "sequence": .number(Double(sequence))]
  }

  private func marker(_ id: String) -> JSONValue {
    ["itemId": .string(id), "turn": ["state": "running"]]
  }
}
