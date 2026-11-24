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
    ]))
    #expect(metrics.reading(agentId: nil).toolCalls == 1)
    #expect(metrics.reading(agentId: nil).toolIsRunning)
    #expect(metrics.reading(agentId: "child").toolCalls == 1)
    #expect(!metrics.reading(agentId: "child").toolIsRunning)
    #expect(metrics.reading(agentId: "unmapped-child").toolCalls == nil)

    let completion = batch(sequence: 6, rows: [row("call", sequence: 2, revision: 2, body: tool("shell", state: "completed"))])
    metrics.apply(completion)
    metrics.apply(completion)
    #expect(metrics.reading(agentId: nil).toolCalls == 1)
    #expect(!metrics.reading(agentId: nil).toolIsRunning)

    metrics.apply(batch(sequence: 7, rows: [row("new-turn", sequence: 7, body: ["kind": "turn", "state": "running"], scope: nil)],
      turn: "new-turn"))
    #expect(metrics.reading(agentId: nil).toolCalls == 0)
    #expect(metrics.reading(agentId: "child").toolCalls == nil)
  }

  @Test func usesCumulativeCodexChildTotalsFromTheBackgroundChannel() {
    var metrics = AgentActivityMetrics()
    let background: (Int) -> JSONValue = { total in
      ["state": "monitoring", "tasks": [
        ["id": "codex-agent:thread-a", "kind": "agent", "totalTokens": .number(Double(total))],
        ["id": "shell", "kind": "command", "totalTokens": 123],
      ]]
    }
    metrics.apply(snapshot(sequence: 5, rows: [], background: background(100_100)))
    #expect(metrics.reading(agentId: "thread-a").totalTokens == 100_100)
    #expect(metrics.reading(agentId: "shell").totalTokens == nil)
    #expect(metrics.reading(agentId: nil).totalTokens == nil)

    // A token-only publication need not advance the journal cursor.
    let update = batch(sequence: 5, rows: [], background: background(1_120_000))
    metrics.apply(update)
    metrics.apply(update)
    metrics.apply(batch(sequence: 6, rows: [], turn: "next-turn"))
    #expect(metrics.reading(agentId: "thread-a").totalTokens == 1_120_000)
    metrics.apply(batch(sequence: 4, rows: [], background: background(1_290_000)))
    #expect(metrics.reading(agentId: "thread-a").totalTokens == 1_120_000)
    metrics.apply(["type": "end"])
    #expect(metrics.reading(agentId: "thread-a").totalTokens == nil)
  }

  @Test func readsChildChannelAndJournalTotalsWithoutUsingTheRootsContextSize() {
    var metrics = AgentActivityMetrics()
    let parent = row("turn", sequence: 1, body: ["kind": "turn", "state": "running", "contextUsage": [
      "used": ["kind": "report", "usedTokens": 55_000, "windowTokens": 200_000],
    ]], scope: nil)
    let roster = row("roster", sequence: 2, body: ["kind": "message", "blocks": [
      ["type": "subagent-group", "agents": [["id": "a", "tokens": 11_000], ["id": "b", "tokens": 0]]],
    ]])
    metrics.apply(snapshot(sequence: 5, rows: [parent, roster], background: ["children": [
      ["id": "work:3", "providerId": "c", "kind": "agent", "totalTokens": 42_000],
    ]], roster: [["entry": ["id": "a", "tokens": 9_000]], ["entry": ["id": "d", "tokens": -1]]]))
    #expect(metrics.reading(agentId: "a").totalTokens == 11_000)
    #expect(metrics.reading(agentId: "b").totalTokens == 0)
    #expect(metrics.reading(agentId: "c").totalTokens == 42_000)
    #expect(metrics.reading(agentId: "d").totalTokens == nil)
    #expect(metrics.reading(agentId: nil).totalTokens == nil)
  }

  @Test func suppressesPartialToolCountsDuringCatchUpAndAppliesRemovals() {
    var metrics = AgentActivityMetrics()
    metrics.apply(snapshot(sequence: 6, rows: [row("call", sequence: 6, body: tool("shell", state: "running"))],
      hasOlder: true))
    #expect(metrics.reading(agentId: nil).toolCalls == 1)
    #expect(metrics.reading(agentId: nil).toolCountIsPartial)
    metrics.apply(batch(sequence: 7, rows: [], hasNewer: true))
    #expect(metrics.reading(agentId: nil).toolCalls == nil)
    metrics.apply(batch(sequence: 8, rows: []))
    #expect(metrics.reading(agentId: nil).toolCalls == 1)
    metrics.apply(batch(sequence: 9, rows: [], removed: ["call"]))
    #expect(metrics.reading(agentId: nil).toolCalls == nil)
    #expect(!metrics.reading(agentId: nil).toolIsRunning)
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

  private func snapshot(sequence: Int, rows: [JSONValue], hasOlder: Bool = false, background: JSONValue = .null,
    roster: [JSONValue] = []) -> JSONValue {
    ["type": "snapshot", "page": ["liveCursor": cursor(sequence), "items": .array(rows),
      "hasOlder": .bool(hasOlder), "latestTurn": marker("turn"), "backgroundTasks": background,
      "subagentRoster": .array(roster)]]
  }

  private func batch(sequence: Int, rows: [JSONValue], removed: [String] = [], turn: String = "turn",
    hasNewer: Bool = false, background: JSONValue = .null) -> JSONValue {
    ["type": "batch", "latestTurn": marker(turn), "hasNewer": .bool(hasNewer), "backgroundTasks": background,
      "batch": ["cursor": cursor(sequence), "items": .array(rows), "removedItemIds": .array(removed.map(JSONValue.string))]]
  }

  private func cursor(_ sequence: Int) -> JSONValue {
    ["epoch": "one", "sequence": .number(Double(sequence))]
  }

  private func marker(_ id: String) -> JSONValue {
    ["itemId": .string(id), "turn": ["state": "running"]]
  }
}
