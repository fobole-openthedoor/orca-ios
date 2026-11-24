import Foundation

/// Capability strings a host advertises in `status.get`, for the features this client gates on them.
public enum HostCapability {
  public static let structuredChat = "agent-session.structured.v1"
  public static let phoneAttachments = "agent-session.attachments.phone.v1"
  public static let conversationStop = "agent-session.conversation-stop.v1"
  public static let queuedMessages = "agent-session.queued-messages.v2"
  public static let agentLaunch = "agent.launch.v2"
  public static let agentLaunchReplay = "agent.launch.replay-required.v1"
  public static let ticketExchange = "pairing.ticket-exchange.v1"
  public static let terminalQueryReply = "terminal.query-reply-input.v1"
}

/// What this client tells the host it can read. Each string is a promise to understand a newer wire
/// shape, so the list holds only what is implemented here.
public enum ClientCapability {
  public static let all = [
    "agent-session.structured.v1",
    "agent-session.structured.claude.v1",
    "agent-session.structured.registered-agents.v1",
    "agent-session.turn-item.v1",
    "agent-session.pending-send-result.v1",
    "agent.launch.v2",
    "agent.launch.unstarted-tab.v1",
    "terminal.host-pane-respawn.v1",
  ]
}

/// The application-level calls, typed. One per paired host, over its connection.
/// See `docs/protocol/rpc-surface.md` for the wire shapes.
public struct HostAPI: Sendable {
  public let connection: OrcaConnection
  /// This install's stable id, which names the phone as a terminal viewer and input driver.
  public let clientId: String

  public init(connection: OrcaConnection, clientId: String) {
    self.connection = connection
    self.clientId = clientId
  }

  var client: JSONValue {
    ["id": .string(clientId), "type": "mobile"]
  }

  // MARK: Host

  public func status() async throws -> HostStatus {
    HostStatus(try await connection.request("status.get", [:]))
  }

  /// Invalidation hints: none carries data, each says what to read again.
  public func clientEvents() async -> RPCSubscription {
    await connection.subscribe(
      "runtime.clientEvents.subscribe", nil, release: .readyId(method: "runtime.clientEvents.unsubscribe"))
  }

  // MARK: Workspaces

  /// Reads the workspace list into `catalog`, falling back to one full read when a delta does not fit.
  public func refresh(_ catalog: inout WorktreeCatalog) async throws {
    if catalog.apply(try await connection.request("worktree.ps", catalog.requestParams)) == .needsFullRead {
      _ = catalog.apply(try await connection.request("worktree.ps", catalog.requestParams))
    }
  }

  public func repos() async throws -> [Repo] {
    try await reposReply().repos
  }

  /// The repos and the reply they came from, for caching.
  public func reposReply() async throws -> (repos: [Repo], raw: JSONValue) {
    let reply = try await connection.request("repo.list", [:])
    return ((reply["repos"]?.arrayValue ?? []).compactMap(Repo.init), reply)
  }

  /// Tells the desktop this workspace was opened; nobody waits for the answer.
  /// Makes a workspace in a project (`worktree.create`) and returns its id. A name the user typed is kept as
  /// its display name; an agent, when given, starts in it.
  public func createWorktree(repoId: String, name: String, agent: String?) async throws -> String? {
    var params: [String: JSONValue] = [
      "repo": .string("id:\(repoId)"), "name": .string(name), "displayName": .string(name),
      "displayNameKind": "user", "activate": .bool(true),
    ]
    if let agent {
      params["startupAgent"] = .string(agent)
      params["createdWithAgent"] = .string(agent)
    }
    let result = try await connection.request("worktree.create", .object(params))
    return result["worktree"]?["id"]?.stringValue
  }

  public func activate(worktree selector: String) async {
    await connection.notify("worktree.activate", ["worktree": .string(selector)])
  }

  public func setPinned(_ pinned: Bool, worktree selector: String) async throws {
    _ = try await connection.request("worktree.set", ["worktree": .string(selector), "isPinned": .bool(pinned)])
  }

  /// Deletes a workspace, as the official phone does (worktree-remove-request.ts): a git worktree with
  /// `worktree.rm`, uncommitted work and all; a folder workspace leaves Orca and its folder stays on disk.
  /// The repository's archive hook doesn't run from the phone. Throws the desktop's refusal.
  public func removeWorkspace(id: String) async throws {
    if id.hasPrefix("folder:") {
      _ = try await connection.request(
        "folderWorkspace.delete",
        [
          "folderWorkspaceId": .string(String(id.dropFirst("folder:".count))), "requireUniqueId": true,
          "runHooks": false,
        ], timeout: .seconds(60))
    } else {
      _ = try await connection.request(
        "worktree.rm", ["worktree": .string("id:\(id)"), "force": true, "runHooks": false], timeout: .seconds(60))
    }
  }

  // MARK: Tabs

  public func tabs(worktree selector: String) async -> RPCSubscription {
    await connection.subscribe(
      "session.tabs.subscribe", ["worktree": .string(selector)],
      // Older hosts only register the stream with its first snapshot.
      release: .requestKeyed(method: "session.tabs.unsubscribe", afterFirstFrame: true) { openerId in
        ["worktree": .string(selector), "subscriptionId": .string(openerId)]
      })
  }

  public func activateTab(_ tabId: String, worktree selector: String) async {
    await connection.notify("session.tabs.activate", ["worktree": .string(selector), "tabId": .string(tabId)])
  }

  public func closeTab(_ tabId: String, worktree selector: String) async throws {
    _ = try await connection.request(
      "session.tabs.close", ["worktree": .string(selector), "tabId": .string(tabId), "reason": "user"])
  }

  /// Opens a new agent chat tab (`agentSession.create`). A refusal inside the reply is thrown as an RPCError.
  /// `forkFrom` starts it as a copy of another chat through one of its items.
  /// A new chat; with `forkFrom` it holds that one through the item, and `firstMessage` goes in as its first
  /// question (`/btw`, on hosts with `agentSession.create.message.v1`).
  /// Returns the new chat's session id.
  @discardableResult
  public func createChat(
    agent: String, worktree selector: String, forkFrom: (sessionId: String, throughItemId: String)? = nil,
    firstMessage: String? = nil
  ) async throws -> String {
    var fields: [String: JSONValue] = ["worktree": .string(selector), "agent": .string(agent)]
    if let forkFrom {
      fields["forkFrom"] = ["sessionId": .string(forkFrom.sessionId), "throughItemId": .string(forkFrom.throughItemId)]
    }
    if let firstMessage, let body = ChatMessageBody.send(text: firstMessage, filePaths: [], imagePaths: []) {
      fields["firstMessage"] = ["clientMessageId": .string(AgentSessionMutation.newOperationId()), "body": body]
    }
    let sessionId = UUID().uuidString.lowercased()
    let mutation = AgentSessionMutation(
      method: "agentSession.create", sessionId: sessionId, fields: fields, expectedRuntimeFence: nil)
    let result = try await connection.request("agentSession.create", mutation.params, timeout: .seconds(15))
    if result["ok"]?.boolValue == false {
      throw RPCError(
        code: result["error"]?["code"]?.stringValue ?? "refused",
        message: result["error"]?["message"]?.stringValue ?? "", data: nil)
    }
    return sessionId
  }

  public func createTerminalTab(worktree selector: String) async throws {
    _ = try await connection.request("session.tabs.createTerminal", ["worktree": .string(selector)])
  }

  /// A browser tab on a blank page (`browser.tabCreate`), shown on the desktop as the workspace's new tab.
  /// No `profileId` lets the host pick the profile by desktop's rule.
  public func createBrowserTab(worktree selector: String, url: String = "about:blank", profileId: String? = nil) async throws {
    var params: [String: JSONValue] = ["worktree": .string(selector), "url": .string(url), "activate": true]
    if let profileId { params["profileId"] = .string(profileId) }
    _ = try await connection.request("browser.tabCreate", .object(params))
  }

  /// A new Markdown note opened as a tab, as the official New tab sheet makes one: `untitled.md`, or the first
  /// free `untitled-N.md`, created with `files.createFile` and opened with `files.open`.
  public func createMarkdownNote(worktree selector: String) async throws {
    for attempt in 1...100 {
      let path = attempt == 1 ? "untitled.md" : "untitled-\(attempt).md"
      do {
        _ = try await connection.request(
          "files.createFile",
          ["worktree": .string(selector), "relativePath": .string(path), "expectedExecutionHostId": "local"])
      } catch let error as RPCError where error.message.lowercased().contains("exist") && attempt < 100 {
        continue
      }
      _ = try await connection.request("files.open", ["worktree": .string(selector), "relativePath": .string(path)])
      return
    }
  }

  /// Starts an agent in an existing workspace. The operation id makes a lost reply safe to replay:
  /// call again with the same id, never a new one, after an ambiguous outcome.
  public func launchAgent(_ agent: String, worktree selector: String, prompt: String?, operationId: String) async throws -> JSONValue {
    var params: [String: JSONValue] = [
      "agent": .string(agent),
      "operationId": .string(operationId),
      "target": ["kind": "existing", "worktree": .string(selector)],
      "nativeChatDefault": true,
      "launchSource": "orca-ios",
    ]
    if let prompt, !prompt.isEmpty {
      params["prompt"] = ["text": .string(prompt), "delivery": "submit"]
    }
    return try await connection.request("agent.launchReplay", .object(params))
  }

  // MARK: Chat

  /// Opens a chat's stream. Without `capabilities` the host sends whole items every time.
  public func chat(sessionId: String, resumingFrom cursor: TranscriptCursor?) async -> RPCSubscription {
    var params: [String: JSONValue] = ["sessionId": .string(sessionId)]
    if let cursor {
      params["cursor"] = cursor.json
    }
    return await connection.subscribe(
      "agentSession.subscribe", .object(params),
      // Without the opener's id the host would end every stream of this session on the socket.
      release: .requestKeyed(method: "agentSession.unsubscribe") { openerId in
        ["sessionId": .string(sessionId), "subscriptionId": .string(openerId)]
      })
  }

  /// An older page, or nil when the host answered with a reset instead.
  public func history(sessionId: String, before cursor: TranscriptCursor) async throws -> JSONValue? {
    let reply = try await connection.request(
      "agentSession.history",
      ["sessionId": .string(sessionId), "direction": "before", "cursor": cursor.json, "limit": 200])
    return reply["ok"]?.boolValue == true ? reply["page"] : nil
  }

  func terminalChat(_ source: TerminalChatSource) async -> RPCSubscription {
    let subscriptionId = "\(source.agent):\(source.sessionId):\(UUID().uuidString)"
    var params = terminalChatParams(source, limit: TerminalChatTranscript.initialLimit)
    params["subscriptionId"] = .string(subscriptionId)
    params["capabilities"] = ["transcriptPending": 1, "transcriptSourceOrder": 1]
    return await connection.subscribe(
      "nativeChat.subscribe", .object(params),
      release: .requestKeyed(method: "nativeChat.unsubscribe") { _ in ["subscriptionId": .string(subscriptionId)] })
  }

  func terminalChatHistory(_ source: TerminalChatSource, page: TerminalChatTranscript.Page) async throws -> JSONValue {
    var params = terminalChatParams(source, limit: page.limit)
    params["capabilities"] = ["transcriptSourceOrder": 1]
    if let before = page.before { params["beforeOffset"] = .number(Double(before)) }
    return try await connection.request("nativeChat.readSession", .object(params), timeout: .seconds(15))
  }

  private func terminalChatParams(_ source: TerminalChatSource, limit: Int) -> [String: JSONValue] {
    var params: [String: JSONValue] = [
      "agent": .string(source.agent), "sessionId": .string(source.sessionId), "limit": .number(Double(limit)),
    ]
    if let path = source.transcriptPath { params["transcriptPath"] = .string(path) }
    return params
  }

  /// Sends one chat write. A thrown error means the outcome is unknown, not that it failed:
  /// replay the identical mutation or reconcile from the stream, never retry under a new id.
  public func perform(_ mutation: AgentSessionMutation) async throws -> AgentSessionMutationResult {
    AgentSessionMutationResult(result: try await connection.request(mutation.method, mutation.params, timeout: .seconds(15)))
  }

  public func chatOptions(sessionId: String) async throws -> JSONValue {
    try await connection.request("agentSession.options", ["sessionId": .string(sessionId)])
  }

  /// A stored attachment or chat image, as base64.
  public func readAttachment(path: String) async throws -> Data? {
    let reply = try await connection.request("agentSessionAttachment.read", ["path": .string(path)])
    return reply["content"]?.stringValue.flatMap { Data(base64Encoded: $0) }
  }

  public func readChatImage(path: String, worktree selector: String) async throws -> Data? {
    let reply = try await connection.request("files.readChatImage", ["worktree": .string(selector), "path": .string(path)])
    return reply["content"]?.stringValue.flatMap { Data(base64Encoded: $0) }
  }

  // MARK: Terminal

  public func terminal(handle: String, cols: Int, rows: Int) async -> RPCBinarySubscription {
    await connection.subscribeWithBinary(
      "terminal.subscribe", terminalSubscribeParams(handle: handle, cols: cols, rows: rows),
      release: .requestKeyed(method: "terminal.unsubscribe") { [clientId] openerId in
        ["subscriptionId": .string("\(handle):\(clientId)"), "client": ["id": .string(clientId)], "requestId": .string(openerId)]
      })
  }

  func terminalSubscribeParams(handle: String, cols: Int, rows: Int) -> JSONValue {
    [
      "terminal": .string(handle),
      "client": client,
      // Sent so the host fits the PTY before it serialises the snapshot.
      "viewport": ["cols": .number(Double(cols)), "rows": .number(Double(rows))],
      "capabilities": ["terminalBinaryStream": 1],
    ]
  }

  /// Resizes in place. The stream's replay params are updated too, so a reconnect carries the new size.
  public func updateTerminalViewport(handle: String, subscriptionId: String, cols: Int, rows: Int) async {
    await connection.updateReplayParams(of: subscriptionId, terminalSubscribeParams(handle: handle, cols: cols, rows: rows))
    await connection.notify(
      "terminal.updateViewport",
      ["terminal": .string(handle), "client": client, "viewport": ["cols": .number(Double(cols)), "rows": .number(Double(rows))]])
  }

  /// Raw keystrokes, escape sequences included. `isQueryReply` marks bytes the emulator produced on
  /// its own to answer a program's query, which the host orders apart from what the user typed.
  public func sendTerminalInput(_ text: String, handle: String, isQueryReply: Bool = false) async throws {
    var params: [String: JSONValue] = ["terminal": .string(handle), "text": .string(text), "enter": false, "client": client]
    if isQueryReply {
      params["inputKind"] = "query-reply"
    }
    _ = try await connection.request("terminal.send", .object(params))
  }

  /// `auto`: the phone drives the PTY's size while it is watching. `desktop`: the phone only looks.
  public func setTerminalDisplayMode(_ mode: String, handle: String, cols: Int, rows: Int) async throws {
    _ = try await connection.request(
      "terminal.setDisplayMode",
      ["terminal": .string(handle), "mode": .string(mode), "client": client,
       "viewport": ["cols": .number(Double(cols)), "rows": .number(Double(rows))]])
  }
}
