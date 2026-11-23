import Foundation
import Testing

@testable import OrcaCore

@Suite struct WorktreeCatalogTests {
  static func row(_ id: String, name: String? = nil) -> JSONValue {
    ["worktreeId": .string(id), "repoId": "r1", "repo": "orca", "branch": "main", "displayName": .string(name ?? id), "path": "/p"]
  }

  @Test func appliesFullUnchangedAndDeltaReplies() {
    var catalog = WorktreeCatalog()
    #expect(catalog.requestParams["afterSnapshotId"] == nil)
    #expect(catalog.requestParams["limit"] == 10_000)

    #expect(catalog.apply(["worktrees": [Self.row("a"), Self.row("b"), Self.row("c")], "snapshotId": "s1"]) == .replaced)
    #expect(catalog.requestParams["afterSnapshotId"] == "s1")
    #expect(catalog.apply(["unchanged": true, "snapshotId": "s1"]) == .unchanged)

    // c moved first, b was renamed, a is gone.
    let delta: JSONValue = ["snapshotId": "s2", "baseSnapshotId": "s1", "rowsFromBase": [2, Self.row("b", name: "renamed")]]
    #expect(catalog.apply(delta) == .replaced)
    #expect(catalog.worktrees.map(\.title) == ["c", "renamed"])
    #expect(catalog.snapshotId == "s2")
  }

  @Test func dropsItsSnapshotOnAnythingThatDoesNotFit() {
    var catalog = WorktreeCatalog()
    _ = catalog.apply(["worktrees": [Self.row("a")], "snapshotId": "s1"])
    #expect(catalog.apply(["snapshotId": "s2", "baseSnapshotId": "other", "rowsFromBase": [0]]) == .needsFullRead)
    #expect(catalog.snapshotId == nil)

    _ = catalog.apply(["worktrees": [Self.row("a")], "snapshotId": "s1"])
    #expect(catalog.apply(["snapshotId": "s2", "baseSnapshotId": "s1", "rowsFromBase": [4]]) == .needsFullRead)
    _ = catalog.apply(["worktrees": [Self.row("a")], "snapshotId": "s1"])
    #expect(catalog.apply(["unchanged": true, "snapshotId": "zzz"]) == .needsFullRead)
    // One unreadable row refuses the whole reply, and the rows held stay.
    #expect(catalog.apply(["worktrees": [Self.row("x"), ["nope": 1]], "snapshotId": "s3"]) == .needsFullRead)
    #expect(catalog.worktrees.map(\.id) == ["a"])
  }

  @Test func readsStatusAndAgents() throws {
    var json = Self.row("a")
    if case .object(var object) = json {
      object["status"] = "active"
      object["sidebarStatus"] = "permission"
      object["agents"] = [["paneKey": "t:l", "state": "blocked", "agentType": "claude", "prompt": "fix it", "taskTitle": "Fix the build"]]
      object["linkedPR"] = ["number": 12, "state": "open"]
      json = .object(object)
    }
    let worktree = try #require(Worktree(json))
    #expect(worktree.displayStatus == "permission")
    #expect(worktree.needsAttention)
    #expect(worktree.agents.first?.title == "Fix the build")
    #expect(worktree.linkedPR?.number == 12)
    #expect(worktree.selector == "id:a")
  }
}

@Suite struct SessionTabsTests {
  @Test func ordersByGroupsAndReadsEveryKind() {
    let tabs = SessionTabs([
      "activeTabId": "chat",
      "tabGroups": [["id": "g", "tabOrder": ["chat", "term"]]],
      "tabs": [
        ["type": "terminal", "id": "term", "title": "zsh", "customTitle": "server", "status": "ready", "terminal": "h-1", "isActive": false],
        ["type": "browser", "id": "web", "title": "Docs", "url": "https://x.test", "isActive": false],
        ["type": "agent-session", "id": "chat", "title": "Fix build", "sessionId": "s-12345678", "agent": "claude", "isActive": true],
        ["type": "terminal", "id": "pending", "title": "claude", "status": "pending-handle", "terminal": nil],
        ["type": "hologram", "id": "new", "title": "Future"],
      ],
    ])
    #expect(tabs.tabs.map(\.id) == ["chat", "term", "web", "pending", "new"])
    #expect(tabs.tabs[0].kind == .agentSession(sessionId: "s-12345678", agent: "claude"))
    #expect(tabs.tabs[1].title == "server")
    #expect(tabs.tabs[1].terminalHandle == "h-1")
    #expect(tabs.tabs[3].kind == .terminal(handle: nil))
    #expect(tabs.tabs[4].kind == .unknown(type: "hologram"))
    #expect(tabs.activeTabId == "chat")
  }
}

@Suite struct ChatTranscriptTests {
  static func item(_ id: String, _ sequence: Int, revision: Int = 1, body: JSONValue) -> JSONValue {
    ["itemId": .string(id), "revision": .number(Double(revision)), "sequence": .number(Double(sequence)), "observedAt": 1, "body": body]
  }

  static func message(_ role: String, _ text: String, done: Bool = true) -> JSONValue {
    var body: [String: JSONValue] = ["kind": "message", "role": .string(role), "blocks": [["type": "text", "text": .string(text)]]]
    if done {
      body["completedAt"] = 5
    }
    return .object(body)
  }

  static func cursor(_ sequence: Int, epoch: String = "e1") -> JSONValue {
    ["epoch": .string(epoch), "sequence": .number(Double(sequence))]
  }

  static var snapshot: JSONValue {
    [
      "type": "snapshot", "sessionId": "s", "fence": 3,
      "page": [
        "epoch": "e1", "direction": "tail", "hasOlder": true, "hasNewer": false,
        "items": [
          item("u1", 10, body: message("user", "hello")),
          item("t1", 11, body: ["kind": "turn", "turnId": "turn-1", "state": "running"]),
        ],
        "removedItemIds": [], "submissions": [],
        "window": ["oldest": cursor(10), "newest": cursor(11), "nextCursor": cursor(11)],
      ],
    ]
  }

  @Test func buildsFromASnapshotAndStreamsABatch() {
    var transcript = ChatTranscript()
    transcript.apply(Self.snapshot)
    #expect(transcript.items.map(\.id) == ["u1", "t1"])
    #expect(transcript.fence == 3)
    #expect(transcript.cursor?.sequence == 11)
    #expect(transcript.hasOlder)
    #expect(transcript.runningTurnId == "turn-1")
    #expect(transcript.isWorking)

    let growing: JSONValue = [
      "type": "batch", "sessionId": "s", "activity": ["turnId": "turn-1", "text": "Reading files"],
      "batch": ["cursor": Self.cursor(12), "removedItemIds": [], "submissions": [],
                "items": [Self.item("a1", 12, body: Self.message("assistant", "Hel", done: false))]],
    ]
    transcript.apply(growing)
    #expect(transcript.activity == "Reading files")
    guard case .message(let partial) = transcript.items.last?.body else {
      Issue.record("expected a message")
      return
    }
    #expect(partial.isStreaming && partial.text == "Hel")

    let finished: JSONValue = [
      "type": "batch", "sessionId": "s", "working": false, "activity": nil, "fence": 4,
      "batch": ["cursor": Self.cursor(13), "removedItemIds": [], "submissions": [],
                "items": [
                  Self.item("a1", 12, revision: 2, body: Self.message("assistant", "Hello there")),
                  Self.item("t1", 11, revision: 2, body: ["kind": "turn", "turnId": "turn-1", "state": "completed"]),
                ]],
    ]
    transcript.apply(finished)
    // A duplicate frame, and a stale revision arriving late, both converge.
    transcript.apply(finished)
    transcript.apply(growing)
    #expect(transcript.items.map(\.id) == ["u1", "t1", "a1"])
    guard case .message(let whole) = transcript.items.last?.body else {
      Issue.record("expected a message")
      return
    }
    #expect(!whole.isStreaming && whole.text == "Hello there")
    #expect(transcript.runningTurnId == nil)
    #expect(!transcript.isWorking)
    #expect(transcript.fence == 4)
  }

  @Test func pagesBackwardsRemovesRowsAndTracksSubmissions() {
    var transcript = ChatTranscript()
    transcript.apply(Self.snapshot)
    transcript.prepend(page: [
      "epoch": "e1", "direction": "before", "hasOlder": false, "hasNewer": true,
      "items": [Self.item("old", 2, body: Self.message("assistant", "earlier"))],
      "removedItemIds": [], "submissions": [],
      "window": ["oldest": Self.cursor(2), "newest": Self.cursor(2), "nextCursor": Self.cursor(2)],
    ])
    #expect(transcript.items.map(\.id) == ["old", "u1", "t1"])
    #expect(!transcript.hasOlder)
    #expect(transcript.oldestCursor?.sequence == 2)
    // Paging back never moves the live resume point.
    #expect(transcript.cursor?.sequence == 11)

    transcript.apply([
      "type": "batch", "sessionId": "s",
      "batch": ["cursor": Self.cursor(14), "items": [], "removedItemIds": ["u1"],
                "submissions": [["clientMessageId": "op-1", "dispatchState": "rejected", "providerItemId": nil, "reason": "busy"]]],
    ])
    #expect(transcript.items.map(\.id) == ["old", "t1"])
    #expect(transcript.submissions["op-1"]?.dispatchState == "rejected")
    #expect(transcript.submissions["op-1"]?.reason == "busy")
  }

  @Test func degradesUnknownShapesAndGatesPrompts() {
    var transcript = ChatTranscript()
    transcript.apply([
      "type": "snapshot", "sessionId": "s", "fence": 1,
      "page": [
        "epoch": "e1", "direction": "tail", "hasOlder": false, "actionablePromptIds": ["ask"],
        "items": [
          Self.item("card", 1, body: ["kind": "automation-saved"]),
          Self.item("ask", 2, body: [
            "kind": "approval", "title": "Run command", "detail": "rm -rf build",
            "options": [["id": "y", "label": "Allow", "intent": "allow_once"], ["id": "n", "label": "Deny", "intent": "reject_once"]],
            "resolution": ["state": "pending", "selectedOptionId": nil],
          ]),
          Self.item("stale", 3, body: [
            "kind": "question", "question": "Which?", "options": [["id": "a", "label": "A"]],
            "resolution": ["state": "pending", "selectedOptionId": nil],
          ]),
          Self.item("tool", 4, body: ["kind": "tool-call", "name": "Bash", "input": ["command": "swift test"], "state": "running"]),
          ["no": "itemId"],
        ],
        "removedItemIds": [], "submissions": [], "window": ["oldest": nil, "newest": nil, "nextCursor": Self.cursor(4)],
      ],
    ])
    #expect(transcript.items.count == 4)
    #expect(transcript.items[0].body == .other(kind: "automation-saved"))
    #expect(transcript.isActionable(transcript.items[1]))
    #expect(!transcript.isActionable(transcript.items[2]))
    guard case .approval(let prompt) = transcript.items[1].body, case .toolCall(let tool) = transcript.items[3].body else {
      Issue.record("unexpected bodies")
      return
    }
    #expect(prompt.options.map(\.isRejection) == [false, true])
    #expect(tool.summary == "swift test")
    #expect(transcript.cursor?.sequence == 4)
  }
}
