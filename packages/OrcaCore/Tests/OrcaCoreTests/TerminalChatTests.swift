import Foundation
import Testing

@testable import OrcaCore

@Suite struct TerminalChatTests {
  @Test func onlyOffersKnownTerminalProviderSessions() throws {
    let tab = try #require(SessionTab([
      "id": "tab", "type": "terminal", "terminal": "term-1", "viewMode": "chat", "launchAgent": "claude",
      "agentStatus": ["agentType": "codex", "providerSession": ["id": "provider-id", "transcriptPath": "/transcripts/provider.jsonl"]],
    ]))
    let source = try #require(tab.terminalChat)
    #expect(tab.prefersTerminalChat)
    #expect(source.agent == "codex")
    #expect(source.sessionId == "provider-id")
    #expect(source.transcriptPath == "/transcripts/provider.jsonl")
    #expect(source.isReadable(connectionId: "ssh", locationKnown: true))
    #expect(SessionTab(["id": "tab", "type": "terminal", "terminal": "term-1", "launchAgent": "codex"])?.terminalChat == nil)
    #expect(SessionTab(["id": "tab", "type": "terminal", "terminal": "term-1", "launchAgent": "codex",
      "agentStatus": ["agentType": "unsupported", "providerSession": ["id": "provider-id"]]])?.terminalChat == nil)
    let grok = try #require(TerminalChatSource(tab: [
      "terminal": "term-grok", "agentStatus": ["agentType": "grok", "providerSession": ["id": "provider-grok"]],
    ]))
    #expect(grok.isReadable(connectionId: nil, locationKnown: true))
    #expect(grok.isReadable(connectionId: "runtime-ssh-vm", locationKnown: true))
    #expect(!grok.isReadable(connectionId: "ssh-user-host", locationKnown: true))
    #expect(!grok.isReadable(connectionId: nil, locationKnown: false))
  }

  @Test func omittedStatusDoesNotCloseAnOpenChatOnTheSameTerminal() {
    let previous = SessionTabs(["tabs": [["id": "tab", "type": "terminal", "terminal": "term-1",
      "agentStatus": ["agentType": "codex", "providerSession": ["id": "original"]]]]])
    var omitted = SessionTabs(["tabs": [["id": "tab", "type": "terminal", "terminal": "term-1"]]])
    omitted.retainTerminalChats(from: previous)
    #expect(omitted.tabs.first?.terminalChat?.sessionId == "original")

    var replaced = SessionTabs(["tabs": [["id": "tab", "type": "terminal", "terminal": "term-2"]]])
    replaced.retainTerminalChats(from: previous)
    #expect(replaced.tabs.first?.terminalChat == nil)

    var starting = SessionTabs(["tabs": [["id": "tab", "type": "terminal", "terminal": "term-1", "agentStatus": ["agentType": "claude"]]]])
    starting.retainTerminalChats(from: previous)
    #expect(starting.tabs.first?.terminalChat == nil)
  }

  @Test func updatesToolsAndKeepsTheNewestStateWhenHistoryArrives() throws {
    var terminal = TerminalChatTranscript()
    var transcript = ChatTranscript()
    let question = message("question", role: "user", blocks: [["type": "text", "text": "Inspect the workspace"]])
    let call = message("call", blocks: [["type": "tool-call", "name": "exec_command", "callId": "read",
      "input": ["command": "ls"], "state": "running"]])
    terminal.apply(["type": "snapshot", "messages": [question, call], "hasMore": true, "beforeOffset": 42,
      "lifecycle": ["state": "working"]])
    let page = try #require(terminal.nextPage)
    #expect(page.before == 42)
    terminal.update(&transcript)
    #expect(transcript.isWorking)
    let callID = try #require(transcript.items.last?.id)

    let result = message("result", role: "tool", blocks: [["type": "tool-result", "callId": "read", "output": "README.md"]])
    let latest = message("answer", blocks: [["type": "text", "text": "Found the README."]])
    terminal.apply(["type": "appended", "messages": [result, latest], "lifecycle": ["state": "completed"]])
    let older = message("older", role: "user", blocks: [["type": "text", "text": "Earlier question"]])
    terminal.prepend(["messages": [older, call], "hasMore": false, "beforeOffset": 0], requested: page)
    terminal.update(&transcript)
    #expect(transcript.items.map(\.id) == ["terminal-message:older", "terminal-message:question", callID, "terminal-message:answer"])
    #expect(!transcript.hasOlder)
    #expect(!transcript.isWorking)
    guard case .toolCall(let finished) = transcript.items[2].body else { Issue.record("Expected tool call"); return }
    #expect(finished.output == "README.md")
    #expect(finished.state == "completed")
  }

  @Test func pendingSnapshotsKeepRowsAndIgnoreEarlierWindowPages() throws {
    var terminal = TerminalChatTranscript()
    var transcript = ChatTranscript()
    let first = message("old", blocks: [["type": "text", "text": "Previously loaded"]])
    terminal.apply(["type": "snapshot", "messages": [first], "hasMore": true, "beforeOffset": 42])
    let stale = try #require(terminal.nextPage)
    terminal.apply(["type": "snapshot", "messages": [], "pending": true])
    terminal.update(&transcript)
    #expect(transcript.items.map(\.id) == ["terminal-message:old"])
    #expect(!transcript.hasOlder)
    let revised = message("replacement", blocks: [["type": "text", "text": "The new window"]])
    terminal.apply(["type": "replacement", "messages": [revised], "hasMore": true, "beforeOffset": 42])
    terminal.prepend(["messages": [first], "hasMore": false], requested: stale)
    terminal.update(&transcript)
    #expect(transcript.items.map(\.id) == ["terminal-message:replacement"])
    #expect(transcript.hasOlder)
  }

  @MainActor @Test func readsPagesAndReplaysWithoutSendingTerminalInput() async throws {
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "nativeChat.subscribe":
        socket.stream(request, ["type": "snapshot", "pending": true, "messages": []])
        socket.stream(request, ["type": "snapshot", "hasMore": true, "beforeOffset": 50, "messages": [[
          "id": .string("live-\(socket.serial)"), "role": "assistant", "source": "transcript",
          "blocks": [["type": "text", "text": "Current window"]],
        ]]])
      case "nativeChat.readSession":
        socket.succeed(request, ["hasMore": false, "beforeOffset": 0, "messages": [[
          "id": "history", "role": "user", "source": "transcript", "blocks": [["type": "text", "text": "Past prompt"]],
        ]]])
      default:
        socket.succeed(request, [:])
      }
    }
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    let terminal = try #require(TerminalChatSource(tab: [
      "terminal": "term-1", "agentStatus": ["agentType": "codex", "providerSession": ["id": "provider-session"]],
    ]))
    let model = ChatSessionModel(api: HostAPI(connection: connection, clientId: "phone"), terminal: terminal)
    model.start()
    await eventually("terminal snapshot") { model.phase == .ready && model.rows.count == 1 }
    await model.loadOlder()
    #expect(model.rows.map(\.id) == ["terminal-message:history", "terminal-message:live-1"])
    #expect(host.seenRequests.first { $0["method"] == "nativeChat.readSession" }?["params"]?["beforeOffset"] == 50)

    host.lastSocket?.drop()
    await eventually("terminal transcript replay") { model.rows.map(\.id) == ["terminal-message:live-2"] }
    let subscribes = host.seenRequests.filter { $0["method"] == "nativeChat.subscribe" }
    let subscription = try #require(subscribes.first?["params"]?["subscriptionId"])
    #expect(subscribes.count == 2)
    #expect(subscribes.last?["params"]?["subscriptionId"] == subscription)
    #expect(subscribes.last?["params"]?["sessionId"] == "provider-session")

    await model.send(text: "this draft must stay on the phone", attachments: [])
    #expect(model.pending.isEmpty)
    #expect(await model.setOption("model", "other") == "Read-only chat")
    model.stop()
    await eventually("the exact native chat subscription is released") {
      host.seenRequests.contains { $0["method"] == "nativeChat.unsubscribe" && $0["params"]?["subscriptionId"] == subscription }
    }
    #expect(!host.seenRequests.contains { $0["method"]?.stringValue?.hasPrefix("agentSession.") == true || $0["method"] == "terminal.send" })
    await connection.close()
  }

  private func message(_ id: String, role: String = "assistant", blocks: [JSONValue]) -> JSONValue {
    ["id": .string(id), "role": .string(role), "source": "transcript", "blocks": .array(blocks)]
  }
}
