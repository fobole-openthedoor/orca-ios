import Foundation
import Observation

/// A message this phone has sent that the journal does not show yet.
public struct PendingSend: Sendable, Equatable, Identifiable {
  public enum State: Sendable, Equatable {
    case uploading(progress: Double)
    case sending
    /// The reply was lost: the host may or may not have taken it. Never offered as "failed".
    case unconfirmed
    case failed(reason: String)
  }

  /// The send's operation id, which the journal's submission row echoes.
  public let id: String
  public var text: String
  public var attachments: [OutgoingAttachment]
  public var state: State
  /// When the send started, in the journal's epoch milliseconds.
  public var createdAt: Double = Date().timeIntervalSince1970 * 1000
}

/// One row of the conversation screen.
public enum ChatRow: Sendable, Equatable, Identifiable {
  case item(TranscriptItem)
  case pending(PendingSend)

  public var id: String {
    switch self {
    case .item(let item):
      return item.id
    case .pending(let send):
      return "pending:" + send.id
    }
  }
}

/// One open chat: its live transcript, the sends in flight, and the writes a screen can make.
@MainActor
@Observable
public final class ChatSessionModel {
  public enum Phase: Sendable, Equatable {
    case loading
    case ready
    case failed(String)
  }

  public let sessionId: String
  public private(set) var transcript = ChatTranscript()
  public private(set) var pending: [PendingSend] = []
  public private(set) var phase: Phase = .loading
  public private(set) var isLoadingOlder = false
  public private(set) var options: ChatOptions?
  public private(set) var commands: [ChatCommand] = []
  /// A Stop is on its way to the host.
  public private(set) var isStopping = false

  @ObservationIgnored private let api: HostAPI
  /// An image this phone sent, with the host path its message will name: the chat keeps it as the
  /// message's preview (imagePreviewsByMessageId), since the host may refuse to send a large one back.
  @ObservationIgnored public var onImageUploaded: ((String, Data) -> Void)?
  @ObservationIgnored private let capabilities: Set<String>
  /// The SSH connection of the workspace's project, which image uploads name.
  @ObservationIgnored private let connectionId: String?
  @ObservationIgnored private var streamTask: Task<Void, Never>?

  public init(api: HostAPI, sessionId: String, capabilities: Set<String>, connectionId: String?) {
    self.api = api
    self.sessionId = sessionId
    self.capabilities = capabilities
    self.connectionId = connectionId
  }

  /// The transcript rows worth drawing, then the sends still in flight.
  public var rows: [ChatRow] {
    // A subagent's rows share the session's journal; the chat draws only its own agent's, and a subagent's
    // work is read from its task in the dock (`subagentItems`).
    transcript.items.filter { $0.agentId == nil && Self.isDrawable($0) }.map(ChatRow.item) + pending.map(ChatRow.pending)
  }

  /// What one subagent wrote and ran, in order.
  public func subagentItems(_ agentId: String) -> [TranscriptItem] {
    transcript.items.filter { $0.agentId == agentId && Self.isDrawable($0) }
  }

  /// The subagents with rows in the loaded journal.
  public var subagentIds: [String] {
    var seen = Set<String>()
    return transcript.items.compactMap(\.agentId).filter { seen.insert($0).inserted }
  }

  public var isWorking: Bool {
    transcript.isWorking
  }

  var apiForTests: HostAPI { api }

  public var acceptsFiles: Bool {
    capabilities.contains(HostCapability.phoneAttachments)
  }

  // MARK: Stream

  public func start() {
    guard streamTask == nil else {
      return
    }
    streamTask = Task { [weak self] in
      var delay: Duration = .milliseconds(500)
      while !Task.isCancelled {
        guard let self else {
          return
        }
        // Every open starts from a snapshot, which replaces what is held.
        let subscription = await self.api.chat(sessionId: self.sessionId, resumingFrom: nil)
        do {
          for try await frame in subscription.events {
            self.apply(frame)
            delay = .milliseconds(500)
          }
        } catch let error as RPCError {
          if self.transcript.items.isEmpty {
            self.phase = .failed(error.message.isEmpty ? error.code : error.message)
          }
        } catch {
          // A dropped socket: the connection replays or the loop reopens below.
        }
        guard (try? await Task.sleep(for: delay)) != nil else {
          return
        }
        delay = min(delay * 2, .seconds(10))
      }
    }
  }

  public func stop() {
    streamTask?.cancel()
    streamTask = nil
  }

  /// Reads the model choices and the slash commands. Both are best effort: a chat works without them.
  public func loadOptions() async {
    if let reply = try? await api.chatOptions(sessionId: sessionId) {
      options = ChatOptions(reply)
    }
    if let reply = try? await api.connection.request("agentSession.commands", ["sessionId": .string(sessionId)], timeout: .seconds(10)) {
      commands = (reply["commands"]?.arrayValue ?? []).compactMap(ChatCommand.init)
    }
  }

  /// Switches model, effort, fast mode or plan mode. Returns the refusal message when the host declines.
  public func setOption(_ key: String, _ value: String) async -> String? {
    let mutation = AgentSessionMutation(
      method: "agentSession.setOption", sessionId: sessionId,
      fields: ["key": .string(key), "value": .string(value)], expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        if let reply = try? await api.chatOptions(sessionId: sessionId) {
          options = ChatOptions(reply)
        }
        return nil
      case .refused(let code, let message):
        return message.isEmpty ? code : message
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  /// Sends a queued message now, or takes it out of the queue.
  public func queuedMessage(_ id: String, send: Bool) async -> String? {
    let mutation = AgentSessionMutation(
      method: send ? "agentSession.queuedMessageSend" : "agentSession.queuedMessageDelete", sessionId: sessionId,
      fields: ["messageId": .string(id)], expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        return nil
      case .refused(let code, let message):
        return message.isEmpty ? code : message
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  public enum GoalChange: Sendable {
    case pause, resume, clear
  }

  /// Pauses, resumes or clears the thread's goal: through the host when it keeps the goal
  /// (agentSession.threadGoal), else by sending the agent its own `/goal clear`.
  public func changeGoal(_ change: GoalChange) async -> String? {
    guard let goal = options?.goal else { return nil }
    guard goal.hostChanges else {
      guard case .clear = change else { return nil }
      await send(text: "/goal clear", attachments: [])
      return nil
    }
    let wire: JSONValue =
      switch change {
      case .pause: ["kind": "status", "status": "paused"]
      case .resume: ["kind": "status", "status": "active"]
      case .clear: ["kind": "clear"]
      }
    let mutation = AgentSessionMutation(
      method: "agentSession.threadGoal", sessionId: sessionId, fields: ["change": wire],
      expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        await refreshOptions()
        return nil
      case .refused(let code, let message):
        return message.isEmpty ? code : message
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  /// `/clear` or `/compact`, which the host runs itself.
  public func runConversationCommand(_ command: String, instructions: String?) async -> String? {
    var fields: [String: JSONValue] = ["command": .string(command)]
    if let instructions, !instructions.isEmpty {
      fields["instructions"] = .string(instructions)
    }
    let mutation = AgentSessionMutation(
      method: "agentSession.conversationCommand", sessionId: sessionId, fields: fields, expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        return nil
      case .refused(let code, let message):
        return message.isEmpty ? code : message
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  /// Sends a composed message, turning a leading `/clear` or `/compact` into the host's own command.
  /// `queue`: while the agent works, hold it until the turn ends instead of steering into it
  /// (`delivery: queue-if-active`, the send button's hold menu).
  public func submit(text: String, attachments: [OutgoingAttachment], queue: Bool = false) async -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if attachments.isEmpty, trimmed.hasPrefix("/") {
      let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
      if let name = parts.first, ChatCommand.conversationCommands.contains(name) {
        return await runConversationCommand(name, instructions: parts.count > 1 ? parts[1] : nil)
      }
    }
    await send(text: text, attachments: attachments, queue: queue)
    return nil
  }

  public func loadOlder() async {
    guard transcript.hasOlder, !isLoadingOlder, let cursor = transcript.oldestCursor else {
      return
    }
    isLoadingOlder = true
    defer {
      isLoadingOlder = false
    }
    if let page = try? await api.history(sessionId: sessionId, before: cursor) {
      transcript.prepend(page: page)
    }
  }

  private func apply(_ frame: JSONValue) {
    transcript.apply(frame)
    if phase != .ready, frame["type"]?.stringValue != "end" {
      phase = .ready
    }
    if !transcript.isWorking {
      isStopping = false
    }
    reconcilePending()
  }

  /// The journal is the truth about a send once it names it.
  private func reconcilePending() {
    pending = pending.compactMap { send in
      // The person's own message in the journal settles the send, whatever the submission row says: a
      // host may name the provider's item rather than the journal's, so the ids need not match.
      if Self.arrivedWithoutSubmission(send, in: transcript) { return nil }
      guard let submission = transcript.submissions[send.id] else { return send }
      var send = send
      switch submission.dispatchState {
      case "accepted":
        // Keep the local bubble until the journal's own row can take its place.
        let arrived = submission.providerItemId.map { id in transcript.items.contains { $0.id == id } } ?? true
        return arrived ? nil : send
      case "rejected":
        send.state = .failed(reason: submission.reason ?? "The agent did not take this message.")
      case "unknown":
        send.state = .unconfirmed
      default:
        break
      }
      return send
    }
  }

  static func arrivedWithoutSubmission(_ send: PendingSend, in transcript: ChatTranscript) -> Bool {
    let text = send.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    // A little slack for clock skew between the phone and the desktop.
    let earliest = send.createdAt - 5_000
    return transcript.items.contains { item in
      guard item.observedAt >= earliest, case .message(let message) = item.body, message.role == "user" else {
        return false
      }
      return message.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
    }
  }

  // MARK: Writes

  /// Sends a message. The bubble appears at once and follows the upload, the write and the journal.
  public func send(text: String, attachments: [OutgoingAttachment], queue: Bool = false) async {
    let operationId = AgentSessionMutation.newOperationId()
    let uploads = !attachments.isEmpty
    pending.append(PendingSend(id: operationId, text: text, attachments: attachments, state: uploads ? .uploading(progress: 0) : .sending))

    var imagePaths: [String] = []
    var filePaths: [String] = []
    do {
      for (index, attachment) in attachments.enumerated() {
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
          let overall = (Double(index) + fraction) / Double(attachments.count)
          Task { @MainActor in self?.update(operationId) { $0.state = .uploading(progress: overall) } }
        }
        switch attachment.kind {
        case .image:
          let path = try await api.uploadImage(attachment.data, fileName: attachment.name, connectionId: connectionId, progress: report)
          imagePaths.append(path)
          onImageUploaded?(path, attachment.data)
        case .file:
          guard acceptsFiles else {
            throw AttachmentError.unsupportedByHost
          }
          filePaths.append(try await api.uploadFile(attachment.data, name: attachment.name, sessionId: sessionId, progress: report))
        }
      }
    } catch {
      // Nothing was sent yet, so this is a definite failure.
      update(operationId) { $0.state = .failed(reason: Self.describeUpload(error)) }
      return
    }

    guard let body = ChatMessageBody.send(text: text, filePaths: filePaths, imagePaths: imagePaths) else {
      pending.removeAll { $0.id == operationId }
      return
    }
    update(operationId) { $0.state = .sending }
    await write(operationId: operationId, body: body, queue: queue, retryOnStaleFence: true)
  }

  private func write(operationId: String, body: JSONValue, queue: Bool = false, retryOnStaleFence: Bool) async {
    var fields: [String: JSONValue] = ["body": body]
    if queue { fields["delivery"] = "queue-if-active" }
    let mutation = AgentSessionMutation(
      method: "agentSession.send", sessionId: sessionId, fields: fields,
      expectedRuntimeFence: transcript.fence, clientOperationId: operationId)
    do {
      switch try await api.perform(mutation) {
      case .accepted(let value, let fence, _):
        transcript.noteFence(fence)
        // Held for after the turn: it shows in the queue, not as a bubble.
        if let queued = value["queued"], queued != .null { pending.removeAll { $0.id == operationId } }
        reconcilePending()
      case .refused(let code, let message):
        if code == "agent_session_checkpoint_stale", retryOnStaleFence {
          // The stream carries the new fence; give it a moment to land, then try once more.
          try? await Task.sleep(for: .milliseconds(400))
          await write(operationId: operationId, body: body, queue: queue, retryOnStaleFence: false)
        } else {
          update(operationId) { $0.state = .failed(reason: message.isEmpty ? code : message) }
        }
      }
    } catch {
      // Unknown, not failed: the journal's submission row settles it.
      update(operationId) { $0.state = .unconfirmed }
    }
  }

  /// Drops a failed bubble, handing its content back so the composer can offer it again.
  @discardableResult
  public func discard(_ id: String) -> PendingSend? {
    guard let index = pending.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    return pending.remove(at: index)
  }

  /// Stops the running turn. Each press is a new operation.
  public func stopTurn() async {
    guard !isStopping else {
      return
    }
    var fields: [String: JSONValue] = [:]
    if !capabilities.contains(HostCapability.conversationStop) {
      guard let turnId = transcript.runningTurnId else {
        return
      }
      fields["turnId"] = .string(turnId)
    }
    isStopping = true
    let mutation = AgentSessionMutation(
      method: "agentSession.cancel", sessionId: sessionId, fields: fields, expectedRuntimeFence: transcript.fence)
    if case .refused? = try? await api.perform(mutation) {
      isStopping = false
    }
  }

  /// Answers an approval or question card. Returns the refusal message when the host declines.
  /// Rewind to here: the conversation forgets this message and everything after it.
  /// One item as the host keeps it, when the transcript carried only its head (agentSession.item).
  /// Nil when it is gone or the host predates the call.
  public func fullItem(_ itemId: String) async -> TranscriptItem? {
    let result = try? await api.connection.request(
      "agentSession.item", ["sessionId": .string(sessionId), "itemId": .string(itemId)])
    return result?["item"].flatMap(TranscriptItem.init)
  }

  public func rewind(to item: TranscriptItem) async -> String? {
    guard let epoch = transcript.cursor?.epoch else { return "unavailable" }
    let mutation = AgentSessionMutation(
      method: "agentSession.rewind", sessionId: sessionId,
      fields: ["itemId": .string(item.id), "expectedEpoch": .string(epoch)], expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        return nil
      case .refused(let code, let message):
        return message.isEmpty ? code : message
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  /// Stops one background task, or all of them.
  public func stopBackgroundTask(_ taskId: String? = nil) async -> String? {
    var fields: [String: JSONValue] = ["turnId": "background-tasks", "scope": "background-tasks"]
    if let taskId { fields["taskId"] = .string(taskId) }
    let mutation = AgentSessionMutation(method: "agentSession.cancel", sessionId: sessionId, fields: fields, expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        return nil
      case .refused(let code, let message):
        return message.isEmpty ? code : message
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  /// Re-reads the options, for the goal's time and status between turns.
  public func refreshOptions() async {
    if let reply = try? await api.chatOptions(sessionId: sessionId) { options = ChatOptions(reply) }
  }

  /// Answers a structured question, one answer per question.
  public func answer(_ item: TranscriptItem, with answers: [TranscriptItem.Answer]) async -> String? {
    let mutation = AgentSessionMutation(
      method: "agentSession.respondToQuestion", sessionId: sessionId,
      fields: [
        "itemId": .string(item.id), "expectedRevision": .number(Double(item.revision)),
        "answers": .array(answers.map(\.json)),
      ],
      expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        return nil
      case .refused(let code, let message):
        return code == "agent_session_already_resolved" ? nil : (message.isEmpty ? code : message)
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  public func respond(to item: TranscriptItem, optionId: String) async -> String? {
    let method: String
    switch item.body {
    case .approval:
      method = "agentSession.respondToApproval"
    case .question:
      method = "agentSession.respondToQuestion"
    default:
      return nil
    }
    let mutation = AgentSessionMutation(
      method: method, sessionId: sessionId,
      fields: ["itemId": .string(item.id), "expectedRevision": .number(Double(item.revision)), "optionId": .string(optionId)],
      expectedRuntimeFence: transcript.fence)
    do {
      switch try await api.perform(mutation) {
      case .accepted(_, let fence, _):
        transcript.noteFence(fence)
        return nil
      case .refused(let code, let message):
        // Someone else answered first; the stream already shows their answer.
        return code == "agent_session_already_resolved" ? nil : (message.isEmpty ? code : message)
      }
    } catch {
      return HostSession.describe(error)
    }
  }

  private func update(_ id: String, _ change: (inout PendingSend) -> Void) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else {
      return
    }
    change(&pending[index])
  }

  private static func isDrawable(_ item: TranscriptItem) -> Bool {
    switch item.body {
    case .message(let message):
      return !message.blocks.isEmpty || message.commandName != nil
    case .status(let text, _):
      return !text.isEmpty
    case .toolCall, .diff, .approval, .question:
      return true
    case .turn, .other:
      return false
    }
  }

  private static func describeUpload(_ error: Error) -> String {
    switch error {
    case AttachmentError.tooLarge:
      return "An attachment is too large to send."
    case AttachmentError.unsupportedByHost:
      return "This desktop's Orca version does not take file attachments from a phone."
    default:
      return "An attachment could not be uploaded. " + HostSession.describe(error)
    }
  }
}
