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
    let reply = try await connection.request("repo.list", [:])
    return (reply["repos"]?.arrayValue ?? []).compactMap(Repo.init)
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
  public func createChat(agent: String, worktree selector: String, forkFrom: (sessionId: String, throughItemId: String)? = nil) async throws {
    var fields: [String: JSONValue] = ["worktree": .string(selector), "agent": .string(agent)]
    if let forkFrom {
      fields["forkFrom"] = ["sessionId": .string(forkFrom.sessionId), "throughItemId": .string(forkFrom.throughItemId)]
    }
    let mutation = AgentSessionMutation(
      method: "agentSession.create", sessionId: UUID().uuidString.lowercased(), fields: fields, expectedRuntimeFence: nil)
    let result = try await connection.request("agentSession.create", mutation.params, timeout: .seconds(15))
    if result["ok"]?.boolValue == false {
      throw RPCError(
        code: result["error"]?["code"]?.stringValue ?? "refused",
        message: result["error"]?["message"]?.stringValue ?? "", data: nil)
    }
  }

  public func createTerminalTab(worktree selector: String) async throws {
    _ = try await connection.request("session.tabs.createTerminal", ["worktree": .string(selector)])
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
