import Foundation

/// How the phone reaches the host right now.
public enum ConnectionPath: String, Sendable, Equatable {
  /// Straight to the desktop's WebSocket, on the LAN or a tailnet.
  case direct
  /// Through Orca's relay service, from anywhere.
  case relay
}

public enum ConnectionState: Sendable, Equatable {
  case disconnected
  case connecting
  case handshaking
  case connected
  case reconnecting(attempt: Int)
  /// The host no longer accepts this device's token; only pairing again recovers.
  case authFailed
}

/// A refusal the host answered with: `{ ok: false, error }`.
public struct RPCError: Error, Sendable, Equatable {
  public let code: String
  public let message: String
  public let data: JSONValue?
}

public enum ConnectionError: Error, Sendable, Equatable {
  case invalidEndpoint
  case timedOut(method: String)
  /// The socket went away with the request written; the host may or may not have run it.
  case interrupted
  case closed
  case authenticationRejected
  case handshakeFailed
  /// A streaming request answered with a plain reply instead of opening.
  case streamEndedBeforeReady
}

/// How an open stream is released on the host when its consumer stops.
/// Mirrors the three families in `rpc-client-stream-registry.ts` of stablyai/orca.
public enum StreamRelease: Sendable {
  /// The host has no release call for this stream; it ends with the socket.
  case none
  /// The host names the registration in its `ready` frame, and only that id releases it.
  case readyId(method: String)
  /// The release echoes selector params plus the opener's request id. `afterFirstFrame` holds the
  /// release until the stream has answered once, for hosts that only register with that frame.
  case requestKeyed(method: String, afterFirstFrame: Bool = false, params: @Sendable (_ openerId: String) -> JSONValue)
}

/// An open streaming request: its id, for calls that name it, and every frame the host sends for it.
public struct RPCSubscription: Sendable {
  public let requestId: String
  public let events: AsyncThrowingStream<JSONValue, Error>
}

/// A frame of a stream that also carries binary data.
public enum InboundFrame: Sendable, Equatable {
  case reply(JSONValue)
  case binary([UInt8])
}

/// A streaming request whose JSON replies and the socket's binary frames arrive in one ordered sequence.
/// A terminal needs that order: its `subscribed` reply names the stream the following binary frames belong to.
public struct RPCBinarySubscription: Sendable {
  public let requestId: String
  public let frames: AsyncThrowingStream<InboundFrame, Error>
}

/// One paired host: E2EE v2, token auth, then JSON RPC, over the direct endpoint or the relay.
/// Reconnects on its own, prefers whichever path worked last, and replays open subscriptions.
/// Mirrors `DirectRpcClient` and the relay session of stablyai/orca.
public actor OrcaConnection {
  public struct Configuration: Sendable {
    /// The direct WebSocket endpoint; empty when only the relay can reach the host.
    public var endpoint: String
    public var deviceToken: String
    public var hostPublicKeyB64: String
    /// Capability strings this client asks the host to honour for this socket.
    public var clientCapabilities: [String]
    public var requestTimeout: Duration = .seconds(30)
    public var handshakeTimeout: Duration = .seconds(10)
    public var livenessIdle: Duration = .seconds(20)
    public var livenessProbeTimeout: Duration = .seconds(8)
    public var missedProbeLimit = 3
    public var authRejectionLimit = 3
    public var reconnectBaseDelay: Duration = .milliseconds(500)
    public var relay: RelayEndpoint?
    public var relayCredential: RelayCredentialSource?
    /// The relay assignment or credentials changed and must be saved with the host.
    public var onRelayUpdate: (@Sendable (RelayEndpoint, RelayCredentialBundle) -> Void)?
    /// How long a direct dial may take before the relay is tried, when there is one.
    public var directTimeoutWithRelay: Duration = .seconds(4)

    public init(endpoint: String, deviceToken: String, hostPublicKeyB64: String, clientCapabilities: [String] = []) {
      self.endpoint = endpoint
      self.deviceToken = deviceToken
      self.hostPublicKeyB64 = hostPublicKeyB64
      self.clientCapabilities = clientCapabilities
    }

    /// A connection for pairing: the direct endpoint, and the relay with the offer's invite.
    public init(offer: PairingOffer, clientCapabilities: [String] = []) {
      self.init(
        endpoint: offer.endpoint, deviceToken: offer.deviceToken,
        hostPublicKeyB64: offer.publicKeyB64, clientCapabilities: clientCapabilities)
      if let relay = offer.relay {
        self.relay = RelayEndpoint(offer: relay)
        relayCredential = .invite(relay.inviteToken)
      }
    }
  }

  static let livenessIdPrefix = "mobile-liveness-"
  static let capabilityUpdateMethod = "runtime.clientCapabilities.update"

  private struct PendingRequest {
    let continuation: CheckedContinuation<JSONValue, Error>
    let timer: Task<Void, Never>
  }

  private struct StreamEntry {
    let method: String
    var params: JSONValue?
    let release: StreamRelease
    let yield: @Sendable (InboundFrame) -> Void
    let finish: @Sendable (Error?) -> Void
    let receivesBinary: Bool
    var sent = false
    var answered = false
    var subscriptionId: String?
    /// The consumer stopped before the stream could be released; release it at the next chance.
    var cancelled = false
  }

  public private(set) var state: ConnectionState = .disconnected
  /// The path of the open socket, or of the last one.
  public private(set) var path: ConnectionPath?

  private let configuration: Configuration
  private let dialer: any WebSocketDialer
  private let director: any RelayDirector
  private var relay: RelayEndpoint?
  private var relayCredential: RelayCredentialSource?
  /// Credential versions the relay refused this run; they are not offered again.
  private var rejectedRelayVersions: Set<Int> = []
  private let clock = ContinuousClock()

  private var runTask: Task<Void, Never>?
  private var backoffTask: Task<Void, Never>?
  private var socket: (any WebSocketTransport)?
  private var e2ee: E2EEV2ClientSession?
  private var closed = false
  private var reachedConnected = false
  private var counter = 0
  private var lastInboundAt: ContinuousClock.Instant
  private var pending: [String: PendingRequest] = [:]
  private var streams: [String: StreamEntry] = [:]
  private var connectWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
  private var stateObservers: [Int: AsyncStream<ConnectionState>.Continuation] = [:]
  private var binaryObservers: [Int: AsyncStream<[UInt8]>.Continuation] = [:]

  public init(
    configuration: Configuration, dialer: any WebSocketDialer = URLSessionWebSocketDialer(),
    director: any RelayDirector = HTTPRelayDirector()
  ) {
    self.configuration = configuration
    self.dialer = dialer
    self.director = director
    self.relay = configuration.relay
    self.relayCredential = configuration.relayCredential
    self.lastInboundAt = clock.now
  }

  /// The relay credentials as they stand now, for pairing to save.
  public var relayState: (endpoint: RelayEndpoint, credential: RelayCredentialSource)? {
    guard let relay, let relayCredential else {
      return nil
    }
    return (relay, relayCredential)
  }

  // MARK: Lifecycle

  /// Starts dialing. Safe to call again; a closed connection stays closed.
  public func start() {
    guard runTask == nil, !closed else {
      return
    }
    runTask = Task { await self.run() }
  }

  public func close() {
    guard !closed else {
      return
    }
    closed = true
    runTask?.cancel()
    backoffTask?.cancel()
    socket?.close()
    setState(.disconnected)
    failPending(ConnectionError.closed)
    for (_, entry) in streams {
      entry.finish(ConnectionError.closed)
    }
    streams.removeAll()
    for (_, observer) in stateObservers {
      observer.finish()
    }
    for (_, observer) in binaryObservers {
      observer.finish()
    }
  }

  /// The app came to the foreground or the network changed: redial now instead of waiting out the backoff.
  public func nudge() {
    backoffTask?.cancel()
  }

  /// The current state, then every change.
  public func states() -> AsyncStream<ConnectionState> {
    let id = nextCounter()
    let (stream, continuation) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(16))
    continuation.yield(state)
    if closed {
      continuation.finish()
      return stream
    }
    stateObservers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeStateObserver(id) }
    }
    return stream
  }

  /// Decrypted binary frames (terminal output, screencasts), in arrival order.
  public func binaryFrames() -> AsyncStream<[UInt8]> {
    let id = nextCounter()
    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
    binaryObservers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeBinaryObserver(id) }
    }
    return stream
  }

  // MARK: Requests

  /// Sends one request and returns its `result`. Waits for the connection first, within the same timeout.
  public func request(_ method: String, _ params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
    let timeout = timeout ?? configuration.requestTimeout
    let deadline = clock.now + timeout
    try await waitUntilConnected(timeout: timeout, method: method)
    return try await perform(method, params, timeout: max(deadline - clock.now, .seconds(1)))
  }

  /// Opens a streaming request. Every reply to it is yielded until the host ends it or the consumer stops.
  /// The request is replayed after a reconnect, so a consumer sees a fresh opening reply then.
  public func subscribe(_ method: String, _ params: JSONValue? = nil, release: StreamRelease = .none) -> RPCSubscription {
    let id = nextRequestId()
    let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
    continuation.onTermination = { [weak self] _ in
      Task { await self?.dropStream(id) }
    }
    open(
      id, method, params, release, receivesBinary: false,
      yield: { frame in
        if case .reply(let reply) = frame {
          continuation.yield(reply)
        }
      },
      finish: { continuation.finish(throwing: $0) })
    return RPCSubscription(requestId: id, events: stream)
  }

  /// Opens a streaming request that also receives the socket's binary frames, in arrival order with its replies.
  public func subscribeWithBinary(_ method: String, _ params: JSONValue? = nil, release: StreamRelease = .none) -> RPCBinarySubscription {
    let id = nextRequestId()
    let (stream, continuation) = AsyncThrowingStream<InboundFrame, Error>.makeStream()
    continuation.onTermination = { [weak self] _ in
      Task { await self?.dropStream(id) }
    }
    open(
      id, method, params, release, receivesBinary: true,
      yield: { continuation.yield($0) },
      finish: { continuation.finish(throwing: $0) })
    return RPCBinarySubscription(requestId: id, frames: stream)
  }

  private func open(
    _ id: String, _ method: String, _ params: JSONValue?, _ release: StreamRelease, receivesBinary: Bool,
    yield: @escaping @Sendable (InboundFrame) -> Void, finish: @escaping @Sendable (Error?) -> Void
  ) {
    if closed {
      finish(ConnectionError.closed)
      return
    }
    streams[id] = StreamEntry(
      method: method, params: params, release: release, yield: yield, finish: finish, receivesBinary: receivesBinary)
    if state == .connected {
      streams[id]?.sent = write(frame(id: id, method: method, params: params))
    }
  }

  /// Ends a stream from the consumer's side and releases it on the host. Dropping every reference to
  /// `events` does the same; this is for a consumer that keeps the subscription value around.
  public func unsubscribe(_ requestId: String) {
    guard let entry = streams[requestId] else {
      return
    }
    dropStream(requestId)
    entry.finish(nil)
  }

  /// Replaces the params a stream is replayed with after a reconnect (a terminal's current viewport).
  public func updateReplayParams(of requestId: String, _ params: JSONValue?) {
    streams[requestId]?.params = params
  }

  /// Fire-and-forget: queues a request whose reply nobody waits for. False when there is no open socket.
  @discardableResult
  public func notify(_ method: String, _ params: JSONValue? = nil) -> Bool {
    state == .connected && write(frame(id: nextRequestId(), method: method, params: params))
  }

  // MARK: Run loop

  private func run() async {
    var attempt = 0
    var authRejections = 0
    while !closed {
      setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
      reachedConnected = false
      var routes = plannedRoutes()
      var resolvedDirector = false
      while !routes.isEmpty, !closed, !reachedConnected {
        let route = routes.removeFirst()
        do {
          try await runSession(route, quickDirect: routes.contains { $0.isRelay })
        } catch ConnectionError.authenticationRejected {
          authRejections += 1
          if authRejections >= configuration.authRejectionLimit {
            closed = true
            setState(.authFailed)
            failPending(ConnectionError.authenticationRejected)
            for (_, entry) in streams {
              entry.finish(ConnectionError.authenticationRejected)
            }
            streams.removeAll()
            return
          }
        } catch let error where route.isRelay && !reachedConnected {
          // A cell's refusal says what to try next.
          let code = Self.relayCode(of: error)
          if code == RelayCloseCode.badCredential.rawValue, let version = route.relayVersion {
            rejectedRelayVersions.insert(version)
            continue
          }
          routes.removeAll { $0.isRelay }
          let moved = code == RelayCloseCode.wrongCell.rawValue || code == RelayCloseCode.draining.rawValue || code == nil
          if moved, !resolvedDirector, let token = route.relayToken, route.relayVersion != nil, await resolveCell(token: token) {
            resolvedDirector = true
            routes.insert(route, at: 0)
          }
        } catch {
          // Any other failure is a dropped or refused socket: try the next path, then redial.
        }
      }
      if reachedConnected {
        attempt = 0
        authRejections = 0
      }
      failPending(ConnectionError.interrupted)
      for (id, entry) in streams {
        if entry.cancelled {
          // Its registration died with the socket.
          streams[id] = nil
          continue
        }
        streams[id]?.sent = false
        streams[id]?.answered = false
        streams[id]?.subscriptionId = nil
      }
      if closed {
        return
      }
      attempt += 1
      setState(.reconnecting(attempt: attempt))
      await backoff(attempt)
    }
  }

  private func backoff(_ attempt: Int) async {
    // 0.5s, 1s, 2s … capped at 15s, with jitter so several hosts do not redial in step.
    let delay = min(.seconds(15), configuration.reconnectBaseDelay * Int(pow(2, Double(min(attempt, 10) - 1)))) * Double.random(in: 0.8...1.2)
    let task = Task {
      _ = try? await Task.sleep(for: delay)
    }
    backoffTask = task
    await task.value
    backoffTask = nil
  }

  private enum Route {
    case direct(URL)
    case relay(token: String, version: Int?)

    var isRelay: Bool {
      if case .relay = self {
        return true
      }
      return false
    }

    var relayToken: String? {
      if case .relay(let token, _) = self {
        return token
      }
      return nil
    }

    var relayVersion: Int? {
      if case .relay(_, let version) = self {
        return version
      }
      return nil
    }
  }

  /// The paths to try this round: whichever worked last first, then the other.
  private func plannedRoutes() -> [Route] {
    var direct: [Route] = []
    if let url = URL(string: configuration.endpoint), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") {
      direct = [.direct(url)]
    }
    var relayed: [Route] = []
    if relay != nil {
      switch relayCredential {
      case .invite(let token):
        relayed = [.relay(token: token, version: nil)]
      case .resume(let bundle):
        relayed = bundle.usable(nowMs: Date().timeIntervalSince1970 * 1000)
          .filter { !rejectedRelayVersions.contains($0.version) }
          .map { .relay(token: $0.token, version: $0.version) }
      case nil:
        break
      }
    }
    return path == .relay ? relayed + direct : direct + relayed
  }

  private static func relayCode(of error: Error) -> Int? {
    switch error {
    case RelayError.closed(let code):
      return code
    case let closed as WebSocketClosedError where (4000..<5000).contains(closed.code):
      return closed.code
    default:
      return nil
    }
  }

  /// Asks the director where the host is served now. True when it named a different cell.
  private func resolveCell(token: String) async -> Bool {
    guard let current = relay, let resolved = try? await director.resolve(current, resumeToken: token), resolved != current else {
      return false
    }
    relay = resolved
    if case .resume(let bundle) = relayCredential {
      configuration.onRelayUpdate?(resolved, bundle)
    }
    return true
  }

  private func runSession(_ route: Route, quickDirect: Bool) async throws {
    let url: URL
    let transport: E2EETransport
    switch route {
    case .direct(let directURL):
      url = directURL
      transport = .direct
    case .relay:
      guard let connectURL = relay?.connectURL() else {
        throw ConnectionError.invalidEndpoint
      }
      url = connectURL
      transport = .relay
    }
    let socket = dialer.dial(url)
    self.socket = socket
    let session = try E2EEV2ClientSession(
      desktopPublicKeyB64: configuration.hostPublicKeyB64, transport: transport,
      relayHostId: transport == .relay ? relay?.relayHostId : nil)
    let handshakeTimeout = route.isRelay || !quickDirect ? configuration.handshakeTimeout : configuration.directTimeoutWithRelay
    let deadline = ContinuousClock.now + handshakeTimeout
    var background: [Task<Void, Never>] = []
    defer {
      for task in background {
        task.cancel()
      }
      socket.close()
      self.socket = nil
      self.e2ee = nil
    }

    if case .relay(let token, let version) = route {
      // The cell checks the relay credential in the clear; everything after it is end to end.
      send(.text(RelayHandshake.auth(credential: token)), on: socket)
      let hello: RelayHandshake.Hello
      do {
        guard case .text(let text) = try await Self.receive(on: socket, by: deadline) else {
          throw RelayError.invalidHello
        }
        hello = try RelayHandshake.readHello(text)
      } catch let closed as WebSocketClosedError {
        throw RelayError.closed(code: closed.code)
      }
      guard hello.kind == (version == nil ? "invite" : "resume") else {
        throw RelayError.invalidHello
      }
    }
    send(.text(session.helloText), on: socket)
    setState(.handshaking)
    guard case .text(let ready) = try await Self.receive(on: socket, by: deadline), session.acceptReady(ready) else {
      throw ConnectionError.handshakeFailed
    }
    send(.text(try session.sealTokenAuth(deviceToken: configuration.deviceToken)), on: socket)
    guard case .text(let sealedReply) = try await Self.receive(on: socket, by: deadline), let reply = session.openText(sealedReply) else {
      throw ConnectionError.handshakeFailed
    }
    guard session.isAuthenticatedReply(reply) else {
      let rejected = JSONValue.parse(reply)?["type"]?.stringValue == "e2ee_error"
      throw rejected ? ConnectionError.authenticationRejected : ConnectionError.handshakeFailed
    }
    e2ee = session
    lastInboundAt = clock.now
    path = route.isRelay ? .relay : .direct

    background.append(Task {
      await self.negotiateCapabilities(on: socket)
      await self.maintainRelayCredential(usedVersion: route.relayVersion, viaRelay: route.isRelay)
    })
    background.append(Task { await self.watchLiveness(of: socket) })

    while true {
      let message = try await socket.receive()
      lastInboundAt = clock.now
      try handle(message, session: session)
    }
  }

  private func negotiateCapabilities(on socket: any WebSocketTransport) async {
    // A timeout or refusal only means the host has no such capabilities; the connection still stands.
    _ = try? await perform(
      Self.capabilityUpdateMethod,
      // Every socket of this client inflates compressed frames, so it always asks for them.
      ["clientCapabilities": .array((configuration.clientCapabilities + [CompressedFrame.clientCapability]).map(JSONValue.string))],
      timeout: .seconds(5)
    )
    guard !Task.isCancelled, e2ee != nil, !closed else {
      return
    }
    reachedConnected = true
    setState(.connected)
    for (_, waiter) in connectWaiters {
      waiter.resume()
    }
    connectWaiters.removeAll()
    for (id, entry) in streams where !entry.sent {
      streams[id]?.sent = write(frame(id: id, method: entry.method, params: entry.params))
    }
  }

  /// Keeps the relay credential alive: confirms the one just used, and replaces it a week before it lapses.
  /// Runs over whichever path connected, so a phone that only ever sees the desktop on the LAN still keeps
  /// a working relay credential for the day it leaves.
  private func maintainRelayCredential(usedVersion: Int?, viaRelay: Bool) async {
    guard state == .connected, case .resume(var bundle) = relayCredential, var endpoint = relay else {
      return
    }
    var changed = false
    if viaRelay, let usedVersion {
      let reply = try? await perform(
        "pairing.getEndpoints", ["resumeConfirmReqId": .string(RelayCrypto.newRequestId("confirm"))], timeout: .seconds(10))
      if let confirmation = reply?["resumeConfirmation"] {
        bundle.applyConfirmation(confirmation, usedVersion: usedVersion)
        changed = true
      }
      if let moved = RelayEndpoint(reply?["relay"]), moved.relayHostId == endpoint.relayHostId, moved != endpoint {
        endpoint = moved
        changed = true
      }
    }
    if bundle.needsRotation(nowMs: Date().timeIntervalSince1970 * 1000) {
      if let rotated = try? await rotate(bundle, onPending: { [weak self] pending in
        await self?.saveRelay(endpoint, pending)
      }) {
        bundle = rotated.bundle
        endpoint = rotated.endpoint ?? endpoint
        changed = true
      }
    }
    if changed {
      saveRelay(endpoint, bundle)
    }
  }

  private func saveRelay(_ endpoint: RelayEndpoint, _ bundle: RelayCredentialBundle) {
    relay = endpoint
    relayCredential = .resume(bundle)
    configuration.onRelayUpdate?(endpoint, bundle)
  }

  /// Installs a new resume credential. The pending token is saved before the host is asked, so a lost
  /// reply can be finished later under the same request id instead of authorising a second one.
  private func rotate(
    _ bundle: RelayCredentialBundle, onPending: (RelayCredentialBundle) async -> Void
  ) async throws -> (bundle: RelayCredentialBundle, endpoint: RelayEndpoint?) {
    var bundle = bundle
    if bundle.pending == nil {
      let token = RelayCrypto.newToken()
      bundle.pending = .init(token: token, hash: RelayCrypto.hash(token), reqId: RelayCrypto.newRequestId("rotate"))
      await onPending(bundle)
    }
    guard let pending = bundle.pending else {
      throw RelayError.noUsableCredential
    }
    var endpoints = try await perform("pairing.getEndpoints", ["installReqId": .string(pending.reqId)], timeout: .seconds(15))
    if endpoints["installStatus"]?["state"]?.stringValue != "committed" {
      _ = try await perform(
        "pairing.provisionRelay",
        ["reqId": .string(pending.reqId), "newResumeTokenHash": .string(pending.hash), "expectedCurrentHash": .string(bundle.current.hash)],
        timeout: .seconds(15))
      endpoints = try await perform("pairing.getEndpoints", ["installReqId": .string(pending.reqId)], timeout: .seconds(15))
    }
    // Only the host's own record of the install makes the new token current.
    guard let installed = endpoints["installStatus"]?["result"], endpoints["installStatus"]?["state"]?.stringValue == "committed" else {
      throw RelayError.noUsableCredential
    }
    return (bundle.installing(pending, result: installed), RelayEndpoint(endpoints["relay"]))
  }

  private func watchLiveness(of socket: any WebSocketTransport) async {
    var missed = 0
    while !Task.isCancelled {
      guard (try? await Task.sleep(for: configuration.livenessIdle)) != nil else {
        return
      }
      guard state == .connected, clock.now - lastInboundAt >= configuration.livenessIdle else {
        missed = 0
        continue
      }
      let before = lastInboundAt
      // Older hosts ignore the probe flag and answer the full status; either reply proves liveness.
      _ = write(frame(id: Self.livenessIdPrefix + String(nextCounter()), method: "status.get", params: ["probe": true]))
      guard (try? await Task.sleep(for: configuration.livenessProbeTimeout)) != nil else {
        return
      }
      if lastInboundAt != before {
        missed = 0
        continue
      }
      missed += 1
      if missed >= configuration.missedProbeLimit {
        socket.close()
        return
      }
    }
  }

  // MARK: Inbound

  private func handle(_ message: WebSocketMessage, session: E2EEV2ClientSession) throws {
    switch message {
    case .text(let frame):
      // Frames are ordered; one that does not open means this socket's counters no longer agree.
      guard let text = session.openText(frame) else {
        throw ConnectionError.handshakeFailed
      }
      try handleReply(text)
    case .binary(let frame):
      guard let sealed = session.openBinary(frame) else {
        throw ConnectionError.handshakeFailed
      }
      var bytes = sealed
      switch try CompressedFrame.inflate(sealed) {
      case .text(let text):
        try handleReply(text)
        return
      case .binary(let inflated):
        bytes = inflated
      case nil:
        break
      }
      for (_, observer) in binaryObservers {
        observer.yield(bytes)
      }
      for (_, entry) in streams where entry.receivesBinary && entry.sent && !entry.cancelled {
        entry.yield(.binary(bytes))
      }
    }
  }

  private func handleReply(_ text: String) throws {
    guard let reply = JSONValue.parse(text), let id = reply["id"]?.stringValue else {
      return
    }
    if id.hasPrefix(Self.livenessIdPrefix) {
      return
    }
    let outcome: Result<JSONValue, Error>
    if reply["ok"]?.boolValue == true {
      outcome = .success(reply["result"] ?? .null)
    } else {
      let error = RPCError(
        code: reply["error"]?["code"]?.stringValue ?? "unknown",
        message: reply["error"]?["message"]?.stringValue ?? "",
        data: reply["error"]?["data"]
      )
      outcome = .failure(error)
      if error.code == "unauthorized" {
        settle(id, outcome)
        throw ConnectionError.authenticationRejected
      }
    }

    if var entry = streams[id] {
      switch outcome {
      case .failure(let error):
        streams[id] = nil
        entry.finish(error)
      case .success(let result):
        let type = result["type"]?.stringValue
        if type == "end" {
          // The host ended it, so there is nothing left to release.
          streams[id] = nil
          entry.yield(.reply(result))
          entry.finish(nil)
        } else if reply["streaming"]?.boolValue == true || type == "scrollback" {
          entry.answered = true
          if type == "ready", let subscriptionId = result["subscriptionId"]?.stringValue {
            entry.subscriptionId = subscriptionId
          }
          streams[id] = entry
          if entry.cancelled {
            dropStream(id)
          } else {
            entry.yield(.reply(result))
          }
        } else {
          streams[id] = nil
          entry.finish(ConnectionError.streamEndedBeforeReady)
        }
      }
      return
    }
    settle(id, outcome)
  }

  // MARK: Outbound

  private func perform(_ method: String, _ params: JSONValue?, timeout: Duration) async throws -> JSONValue {
    let id = nextRequestId()
    return try await withCheckedThrowingContinuation { continuation in
      let timer = Task { [weak self] in
        guard (try? await Task.sleep(for: timeout)) != nil else {
          return
        }
        await self?.settle(id, .failure(ConnectionError.timedOut(method: method)))
      }
      pending[id] = PendingRequest(continuation: continuation, timer: timer)
      if !write(frame(id: id, method: method, params: params)) {
        settle(id, .failure(ConnectionError.interrupted))
      }
    }
  }

  private func settle(_ id: String, _ outcome: Result<JSONValue, Error>) {
    guard let request = pending.removeValue(forKey: id) else {
      return
    }
    request.timer.cancel()
    request.continuation.resume(with: outcome)
  }

  private func failPending(_ error: Error) {
    for id in Array(pending.keys) {
      settle(id, .failure(error))
    }
    for (_, waiter) in connectWaiters {
      waiter.resume(throwing: error)
    }
    connectWaiters.removeAll()
  }

  private func waitUntilConnected(timeout: Duration, method: String) async throws {
    if state == .connected {
      return
    }
    if closed {
      throw state == .authFailed ? ConnectionError.authenticationRejected : ConnectionError.closed
    }
    let id = nextCounter()
    let timer = Task { [weak self] in
      guard (try? await Task.sleep(for: timeout)) != nil else {
        return
      }
      await self?.expireConnectWaiter(id, method: method)
    }
    defer {
      timer.cancel()
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connectWaiters[id] = continuation
    }
  }

  private func expireConnectWaiter(_ id: Int, method: String) {
    connectWaiters.removeValue(forKey: id)?.resume(throwing: ConnectionError.timedOut(method: method))
  }

  private func frame(id: String, method: String, params: JSONValue?) -> JSONValue {
    var object: [String: JSONValue] = [
      "id": .string(id),
      "deviceToken": .string(configuration.deviceToken),
      "method": .string(method),
    ]
    if let params {
      object["params"] = params
    }
    return .object(object)
  }

  /// Seals and queues one frame. Sealing and queueing happen in one actor turn, which keeps counters in wire order.
  private func write(_ value: JSONValue) -> Bool {
    guard let socket, let e2ee, let sealed = try? e2ee.sealText(value.serialized()) else {
      return false
    }
    socket.send(.text(sealed)) { error in
      if error != nil {
        socket.close()
      }
    }
    return true
  }

  /// One handshake read that gives up at `deadline`. A socket dialled to an address that never answers
  /// neither delivers nor fails a read, even once closed, so the read is raced against the clock here.
  private static func receive(on socket: any WebSocketTransport, by deadline: ContinuousClock.Instant) async throws -> WebSocketMessage {
    let outcome = OnceResult<WebSocketMessage>()
    return try await withCheckedThrowingContinuation { continuation in
      outcome.attach(continuation)
      Task {
        do {
          outcome.resolve(.success(try await socket.receive()))
        } catch {
          outcome.resolve(.failure(error))
        }
      }
      Task {
        try? await Task.sleep(until: deadline)
        if outcome.resolve(.failure(ConnectionError.handshakeFailed)) {
          socket.close()
        }
      }
    }
  }

  /// Queues a handshake frame without waiting for the system to confirm it. A socket to an address that
  /// never answers never confirms or fails a send, so waiting here would hold the dial past its watchdog;
  /// a failed send closes the socket instead, and the read that follows ends.
  private func send(_ message: WebSocketMessage, on socket: any WebSocketTransport) {
    socket.send(message) { error in
      if error != nil {
        socket.close()
      }
    }
  }

  // MARK: Bookkeeping

  private func dropStream(_ id: String) {
    guard let entry = streams[id] else {
      return
    }
    // An opener that never reached the socket registered nothing.
    guard entry.sent, state == .connected else {
      streams[id] = nil
      return
    }
    switch entry.release {
    case .none:
      streams[id] = nil
    case .readyId(let method):
      guard let subscriptionId = entry.subscriptionId else {
        streams[id]?.cancelled = true
        return
      }
      streams[id] = nil
      _ = write(frame(id: nextRequestId(), method: method, params: ["subscriptionId": .string(subscriptionId)]))
    case .requestKeyed(let method, let afterFirstFrame, let params):
      if afterFirstFrame, !entry.answered {
        streams[id]?.cancelled = true
        return
      }
      streams[id] = nil
      _ = write(frame(id: nextRequestId(), method: method, params: params(id)))
    }
  }

  private func removeStateObserver(_ id: Int) {
    stateObservers[id] = nil
  }

  private func removeBinaryObserver(_ id: Int) {
    binaryObservers[id] = nil
  }

  private func setState(_ next: ConnectionState) {
    guard state != next else {
      return
    }
    state = next
    for (_, observer) in stateObservers {
      observer.yield(next)
    }
  }

  private func nextCounter() -> Int {
    counter += 1
    return counter
  }

  private func nextRequestId() -> String {
    "rpc-\(nextCounter())-\(Int(Date().timeIntervalSince1970 * 1000))"
  }
}

/// A continuation resumed by whichever of several racers finishes first.
final class OnceResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var early: Result<Value, Error>?

  func attach(_ continuation: CheckedContinuation<Value, Error>) {
    let ready: Result<Value, Error>? = lock.withLock {
      if let early {
        return early
      }
      self.continuation = continuation
      return nil
    }
    if let ready {
      continuation.resume(with: ready)
    }
  }

  /// True for the racer that won.
  @discardableResult
  func resolve(_ result: Result<Value, Error>) -> Bool {
    let (waiting, won): (CheckedContinuation<Value, Error>?, Bool) = lock.withLock {
      if let continuation {
        self.continuation = nil
        early = result
        return (continuation, true)
      }
      if early == nil {
        early = result
        return (nil, true)
      }
      return (nil, false)
    }
    waiting?.resume(with: result)
    return won
  }
}
