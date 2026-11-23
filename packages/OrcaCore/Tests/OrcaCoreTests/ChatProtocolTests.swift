import Foundation
import Testing

@testable import OrcaCore

@Suite struct CanonicalJSONTests {
  @Test func matchesJavaScriptStringify() {
    let value: JSONValue = [
      "b": [1, 2.5, -0.0, 1_700_000_000_000, true, nil],
      "a": "slash / quote \" back \\ tab \t nl \n bell \u{07} é 漢 😀",
      "Z": ["y": "1", "x": [:]],
    ]
    // Produced by JSON.stringify with sorted keys.
    #expect(
      CanonicalJSON.string(value)
        == #"{"Z":{"x":{},"y":"1"},"a":"slash / quote \" back \\ tab \t nl \n bell \u0007 é 漢 😀","b":[1,2.5,0,1700000000000,true,null]}"#)
  }

  @Test func fingerprintsASendTheWayTheHostDoes() {
    let mutation = AgentSessionMutation(
      method: "agentSession.send",
      sessionId: "0b1c2d3e-aaaa-bbbb-cccc-000000000001",
      fields: ["body": ["kind": "message", "role": "user", "blocks": [["type": "text", "text": "hi / there"]]]],
      expectedRuntimeFence: 7,
      clientOperationId: "1700000000000-0123456789abcdef0123456789abcdef"
    )
    // sha256 of {"fields":{"body":{"blocks":[{"text":"hi / there","type":"text"}],"kind":"message","role":"user"}},"method":"agentSession.send","sessionId":"0b1c2d3e-aaaa-bbbb-cccc-000000000001"}
    #expect(mutation.payloadFingerprint == "4cc25775361587fc75fb745204b373614b8088c0c2a3580b221521171e54a2ee")
    #expect(mutation.params["envelope"]?["expectedRuntimeFence"] == 7)
    #expect(mutation.params["envelope"]?["clientOperationId"] == "1700000000000-0123456789abcdef0123456789abcdef")
    #expect(mutation.params["body"]?["role"] == "user")
  }

  @Test func usesTheFingerprintNamesTheHostExpects() {
    let approval = AgentSessionMutation(
      method: "agentSession.respondToApproval", sessionId: "session-1", fields: ["itemId": "i"], expectedRuntimeFence: 1)
    #expect(approval.fingerprintMethod == "agentSession.respondTo:approval")

    let create = AgentSessionMutation(
      method: "agentSession.create", sessionId: "session-1",
      fields: ["worktree": "id:w", "agent": "claude", "tabPlacement": ["groupId": "g"]], expectedRuntimeFence: nil)
    #expect(create.fingerprintFields.keys.sorted() == ["agent", "worktree"])
    #expect(create.params["tabPlacement"] != nil)
    #expect(create.params["envelope"]?["expectedRuntimeFence"] == .null)
  }

  @Test func mintsOperationIdsInTheRequiredFormat() {
    let id = AgentSessionMutation.newOperationId()
    #expect(id.range(of: "^[0-9]{13}-[0-9a-f]{32}$", options: .regularExpression) != nil)
  }
}

@Suite struct TerminalFrameTests {
  static func frame(_ opcode: UInt8, stream: UInt32 = 5, _ payload: [UInt8] = []) -> TerminalFrame {
    let header: [UInt8] = [0x74, 1, opcode, 0, UInt8(stream), 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0]
    return TerminalFrame(header + payload)!
  }

  @Test func parsesTheHeader() {
    let frame = Self.frame(1, Array("ls\r\n".utf8))
    #expect(frame.streamId == 5)
    #expect(frame.sequence == 9)
    #expect(frame.payload == Array("ls\r\n".utf8))
    #expect(TerminalFrame([0x7a, 1, 0, 0]) == nil)
    #expect(TerminalFrame([0x73] + [UInt8](repeating: 0, count: 20)) == nil)
  }

  @Test func reassemblesSnapshotsAndPassesOutput() {
    var decoder = TerminalFrameDecoder(streamId: 5)
    #expect(decoder.decode(Self.frame(2, Array(#"{"cols":80,"rows":24}"#.utf8))) == nil)
    #expect(decoder.decode(Self.frame(3, Array("hello ".utf8))) == nil)
    #expect(decoder.decode(Self.frame(3, Array("world".utf8))) == nil)
    #expect(decoder.decode(Self.frame(4)) == .snapshot(serialized: Array("hello world".utf8), meta: ["cols": 80, "rows": 24]))
    #expect(decoder.decode(Self.frame(1, [0x1b, 0x5b, 0x41])) == .output([0x1b, 0x5b, 0x41]))
    #expect(decoder.decode(Self.frame(15, Array(#"{"data":"span"}"#.utf8))) == .output(Array("span".utf8)))
    #expect(decoder.decode(Self.frame(1, stream: 6)) == nil)
  }

  @Test func asksForAFreshSnapshotOnWhatItCannotRead() {
    var decoder = TerminalFrameDecoder(streamId: 5)
    #expect(decoder.decode(Self.frame(4)) == .failed(message: "Terminal snapshot end without a start."))
    #expect(decoder.decode(Self.frame(99)) == .failed(message: "Unsupported terminal stream frame (opcode 99)."))
    #expect(decoder.decode(Self.frame(6, Array("gone".utf8))) == .failed(message: "gone"))
  }

  @Test func readsGoalTransitionsFromStatusRows() {
    let set = TranscriptItem([
      "itemId": "g1", "sequence": 3,
      "body": [
        "kind": "status", "text": "Goal set",
        "threadGoal": ["state": "set", "goal": ["objective": "Ship it", "status": "active", "timeUsedSeconds": 12, "tokensUsed": 40]],
      ],
    ])
    #expect(set?.goalChange == .set(ChatOptions.Goal(objective: "Ship it", status: "active", timeUsedSeconds: 12, tokensUsed: 40)))
    let cleared = TranscriptItem(["itemId": "g2", "body": ["kind": "status", "text": "Goal cleared", "threadGoal": ["state": "cleared"]]])
    #expect(cleared?.goalChange == .cleared)
    let plain = TranscriptItem(["itemId": "s", "body": ["kind": "status", "text": "Compacted", "contextClear": ["reason": "clear"]]])
    #expect(plain?.goalChange == nil)
    #expect(plain?.clearsContext == true)
  }
}
