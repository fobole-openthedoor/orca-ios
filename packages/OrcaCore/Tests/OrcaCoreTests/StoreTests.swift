import Foundation
import Testing

@testable import OrcaCore

/// Waits until `condition` holds on the main actor, or records a failure after two seconds.
@MainActor
func eventually(_ what: String, _ condition: () -> Bool) async {
  for _ in 0..<400 {
    if condition() {
      return
    }
    try? await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("timed out waiting for \(what)")
}

@MainActor
@Suite struct ChatSessionModelTests {
  nonisolated static func snapshot(items: [JSONValue] = [], fence: Int = 2) -> JSONValue {
    [
      "type": "snapshot", "sessionId": "session-1", "fence": .number(Double(fence)),
      "page": ["epoch": "e1", "direction": "tail", "hasOlder": false, "items": .array(items), "removedItemIds": [], "submissions": [],
               "window": ["oldest": nil, "newest": nil, "nextCursor": ["epoch": "e1", "sequence": 0]]],
    ]
  }

  static func model(_ host: FakeHost, capabilities: Set<String> = []) async -> ChatSessionModel {
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    return ChatSessionModel(
      api: HostAPI(connection: connection, clientId: "phone-1"), sessionId: "session-1", capabilities: capabilities, connectionId: nil)
  }

  @Test func sendsShowAtOnceAndGiveWayToTheJournal() async throws {
    let subscribeRequest = LockedBox<JSONValue?>(nil)
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "agentSession.subscribe":
        subscribeRequest.set(request)
        socket.stream(request, Self.snapshot())
      case "agentSession.send":
        socket.succeed(request, ["ok": true, "replayed": false, "fence": 3, "cursor": ["epoch": "e1", "sequence": 1], "value": [:]])
      default:
        socket.succeed(request, .null)
      }
    }
    let model = await Self.model(host)
    model.start()
    await eventually("the snapshot") { model.phase == .ready }

    await model.send(text: "ship it  ", attachments: [])
    #expect(model.pending.map(\.text) == ["ship it  "])
    #expect(model.pending.first?.state == .sending)
    #expect(model.transcript.fence == 3)

    let send = try #require(host.seenRequests.first { $0["method"] == "agentSession.send" })
    let operationId = try #require(send["params"]?["envelope"]?["clientOperationId"]?.stringValue)
    #expect(send["params"]?["envelope"]?["expectedRuntimeFence"] == 2)
    #expect(send["params"]?["body"]?["blocks"] == [["type": "text", "text": "ship it"]])
    #expect(model.rows.last?.id == "pending:" + operationId)

    // The journal names the send and carries the user's row: the local bubble steps aside.
    host.lastSocket?.stream(try #require(subscribeRequest.get()), [
      "type": "batch", "sessionId": "session-1",
      "batch": [
        "cursor": ["epoch": "e1", "sequence": 1], "removedItemIds": [],
        "items": [ChatTranscriptTests.item("u1", 1, body: ChatTranscriptTests.message("user", "ship it"))],
        "submissions": [["clientMessageId": .string(operationId), "dispatchState": "accepted", "providerItemId": "u1"]],
      ],
    ])
    await eventually("the journal row") { model.pending.isEmpty }
    #expect(model.rows.map(\.id) == ["u1"])
    model.stop()
    await model.stopAndClose()
  }

  @Test func marksRefusedAndUnansweredSendsDifferently() async throws {
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "agentSession.subscribe":
        socket.stream(request, Self.snapshot())
      case "agentSession.send":
        if request["params"]?["body"]?["blocks"]?[0]?["text"] == "refuse me" {
          socket.succeed(request, ["ok": false, "refusal": ["code": "agent_session_conflict", "message": "Another device is driving this chat."]])
        } else {
          socket.drop()
        }
      default:
        socket.succeed(request, .null)
      }
    }
    let model = await Self.model(host)
    model.start()
    await eventually("the snapshot") { model.phase == .ready }

    await model.send(text: "refuse me", attachments: [])
    #expect(model.pending.first?.state == .failed(reason: "Another device is driving this chat."))
    #expect(model.discard(model.pending[0].id)?.text == "refuse me")

    // The socket dies with the write on the wire: unknown, never "failed".
    await model.send(text: "lost reply", attachments: [])
    #expect(model.pending.first?.state == .unconfirmed)
    await model.stopAndClose()
  }

  @Test func refusesFilesTheHostCannotTakeBeforeSendingAnything() async throws {
    let host = FakeHost { request, socket in
      if request["method"] == "agentSession.subscribe" {
        socket.stream(request, Self.snapshot())
      } else {
        socket.succeed(request, .null)
      }
    }
    let model = await Self.model(host)
    model.start()
    await eventually("the snapshot") { model.phase == .ready }
    await model.send(text: "see file", attachments: [OutgoingAttachment(kind: .file, name: "a.pdf", data: Data([1]))])
    guard case .failed = model.pending.first?.state else {
      Issue.record("expected a failed send")
      return
    }
    #expect(!host.seenRequests.contains { $0["method"] == "agentSession.send" })
    await model.stopAndClose()
  }

  @Test func stopsByConversationOrByTurn() async throws {
    let running = ChatTranscriptTests.item("t1", 1, body: ["kind": "turn", "turnId": "turn-9", "state": "running"])
    let host = FakeHost { request, socket in
      if request["method"] == "agentSession.subscribe" {
        socket.stream(request, Self.snapshot(items: [running]))
      } else {
        socket.succeed(request, ["ok": true, "replayed": false, "fence": 2, "value": ["cancelled": true]])
      }
    }
    let byTurn = await Self.model(host)
    byTurn.start()
    await eventually("the snapshot") { byTurn.isWorking }
    await byTurn.stopTurn()
    #expect(byTurn.isStopping)
    let cancel = try #require(host.seenRequests.first { $0["method"] == "agentSession.cancel" })
    #expect(cancel["params"]?["turnId"] == "turn-9")
    await byTurn.stopAndClose()

    let byConversation = await Self.model(host, capabilities: [HostCapability.conversationStop])
    byConversation.start()
    await eventually("the snapshot") { byConversation.isWorking }
    await byConversation.stopTurn()
    let second = try #require(host.seenRequests.last { $0["method"] == "agentSession.cancel" })
    #expect(second["params"]?["turnId"] == nil)
    await byConversation.stopAndClose()
  }
}

extension ChatSessionModel {
  /// Test teardown: ends the stream loop and the connection under it.
  func stopAndClose() async {
    stop()
    await apiForTests.connection.close()
  }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func get() -> Value {
    lock.withLock { value }
  }

  func set(_ next: Value) {
    lock.withLock { value = next }
  }
}

@MainActor
@Suite struct TerminalSessionModelTests {
  nonisolated static func frame(_ opcode: UInt8, stream: UInt8, _ payload: String = "") -> [UInt8] {
    [0x74, 1, opcode, 0, stream, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + Array(payload.utf8)
  }

  @Test func loadsTheSnapshotFeedsOutputAndRecoversAfterAReconnect() async throws {
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "terminal.subscribe":
        // The stream id differs per socket, as it does on a real host.
        let stream = UInt8(socket.serial)
        socket.stream(request, ["type": "subscribed", "streamId": .number(Double(stream)), "cols": 80, "rows": 24])
        socket.binary(Self.frame(2, stream: stream, #"{"cols":80,"rows":24}"#))
        socket.binary(Self.frame(3, stream: stream, "screen-\(socket.serial)"))
        socket.binary(Self.frame(4, stream: stream))
        socket.binary(Self.frame(1, stream: stream, "$ "))
      default:
        socket.succeed(request, ["send": ["accepted": true]])
      }
    }
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    let model = TerminalSessionModel(api: HostAPI(connection: connection, clientId: "phone-1"), handle: "term-1", cols: 40, rows: 20)
    var log: [String] = []
    var hostSize: [Int] = []
    model.onSnapshot = { log.append("snapshot:" + String(decoding: $0, as: UTF8.self)) }
    model.onOutput = { log.append("output:" + String(decoding: $0, as: UTF8.self)) }
    model.onHostSize = { hostSize = [$0, $1] }
    model.start()
    await eventually("the first screen") { log == ["snapshot:screen-1", "output:$ "] }
    #expect(model.phase == .live)
    #expect(hostSize == [80, 24])

    let subscribe = try #require(host.seenRequests.first { $0["method"] == "terminal.subscribe" })
    #expect(subscribe["params"]?["viewport"] == ["cols": 40, "rows": 20])
    #expect(subscribe["params"]?["client"] == ["id": "phone-1", "type": "mobile"])
    #expect(subscribe["params"]?["capabilities"] == ["terminalBinaryStream": 1])

    model.send("ls")
    model.send("\r")
    model.resize(cols: 50, rows: 30)
    await eventually("input and resize") {
      host.seenRequests.filter { $0["method"] == "terminal.send" }.count == 2
        && host.seenRequests.contains { $0["method"] == "terminal.updateViewport" }
    }
    #expect(host.seenRequests.filter { $0["method"] == "terminal.send" }.map { $0["params"]?["text"] } == ["ls", "\r"])

    // After a drop the replayed subscription carries the new size and brings a fresh screen.
    host.lastSocket?.drop()
    await eventually("the replayed screen") { log.suffix(2) == ["snapshot:screen-2", "output:$ "] }
    let replay = try #require(host.seenRequests.last { $0["method"] == "terminal.subscribe" })
    #expect(replay["params"]?["viewport"] == ["cols": 50, "rows": 30])

    model.stop()
    try await Task.sleep(for: .milliseconds(30))
    _ = try await connection.request("flush")
    let release = try #require(host.seenRequests.last { $0["method"] == "terminal.unsubscribe" })
    #expect(release["params"]?["subscriptionId"] == "term-1:phone-1")
    await connection.close()
  }
}
