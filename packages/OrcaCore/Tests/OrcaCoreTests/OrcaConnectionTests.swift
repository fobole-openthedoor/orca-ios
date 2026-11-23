import Foundation
import Testing

@testable import OrcaCore

/// An in-memory host: the desktop half of the handshake, then whatever `respond` answers.
final class FakeHost: WebSocketDialer, @unchecked Sendable {
  typealias Responder = @Sendable (_ request: JSONValue, _ socket: FakeHostSocket) -> Void

  private let lock = NSLock()
  private let desktop = FakeDesktop()
  private var sockets: [FakeHostSocket] = []
  private var requests: [JSONValue] = []
  let acceptedToken: String
  let respond: Responder
  /// False makes the direct endpoint unreachable, as it is away from home.
  var directReachable = true
  /// The direct endpoint swallows everything and never answers or fails, as an unroutable address does.
  var directSilent = false
  /// How the relay cell answers a credential: nil accepts it as the given kind, a code refuses it.
  var relayAnswer: @Sendable (_ credential: String) -> (kind: String?, refusal: Int?) = { _ in ("resume", nil) }
  private(set) var relayCredentials: [String] = []
  private(set) var dialedURLs: [URL] = []

  init(acceptedToken: String = "token", respond: @escaping Responder) {
    self.acceptedToken = acceptedToken
    self.respond = respond
  }

  func noteRelayCredential(_ credential: String) {
    lock.withLock { relayCredentials.append(credential) }
  }

  var publicKeyB64: String {
    // Every socket shares the long-lived host key the phone pinned at pairing.
    desktop.publicKeyB64
  }

  var keyPair: NaCl.KeyPair {
    desktop.keyPair
  }

  var dialCount: Int {
    lock.withLock { sockets.count }
  }

  var seenRequests: [JSONValue] {
    lock.withLock { requests }
  }

  var lastSocket: FakeHostSocket? {
    lock.withLock { sockets.last }
  }

  func record(_ request: JSONValue) {
    lock.withLock { requests.append(request) }
  }

  func dial(_ url: URL) -> any WebSocketTransport {
    lock.withLock {
      dialedURLs.append(url)
      let isRelay = url.path.hasPrefix("/v1/connect/")
      let socket = FakeHostSocket(
        host: self, serial: sockets.count + 1, relay: isRelay, reachable: isRelay || directReachable, silent: !isRelay && directSilent)
      sockets.append(socket)
      return socket
    }
  }

  func configuration(token: String = "token") -> OrcaConnection.Configuration {
    var configuration = OrcaConnection.Configuration(
      endpoint: "ws://host.test:6768", deviceToken: token, hostPublicKeyB64: publicKeyB64,
      clientCapabilities: ["test.capability"])
    configuration.reconnectBaseDelay = .milliseconds(5)
    return configuration
  }
}

final class FakeHostSocket: WebSocketTransport, @unchecked Sendable {
  private enum Stage {
    case awaitingRelayAuth
    case awaitingHello
    case awaitingAuth
    case open
  }

  private let lock = NSLock()
  private let host: FakeHost
  private let desktop: FakeDesktop
  private var stage: Stage
  private let inbox: AsyncThrowingStream<WebSocketMessage, Error>
  private let outbox: AsyncThrowingStream<WebSocketMessage, Error>.Continuation

  let serial: Int

  private var silent = false

  init(host: FakeHost, serial: Int, relay: Bool = false, reachable: Bool = true, silent: Bool = false) {
    self.host = host
    self.serial = serial
    self.desktop = FakeDesktop(keyPair: host.keyPair)
    (inbox, outbox) = AsyncThrowingStream<WebSocketMessage, Error>.makeStream()
    stage = relay ? .awaitingRelayAuth : .awaitingHello
    self.silent = silent
    if !reachable {
      outbox.finish(throwing: URLError(.cannotConnectToHost))
    }
  }

  func send(_ message: WebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
    if silent {
      return
    }
    let request: JSONValue? = lock.withLock {
      guard case .text(let text) = message else {
        return nil
      }
      switch stage {
      case .awaitingRelayAuth:
        let credential = JSONValue.parse(text)?["credential"]?.stringValue ?? ""
        host.noteRelayCredential(credential)
        let answer = host.relayAnswer(credential)
        if let code = answer.refusal {
          outbox.finish(throwing: WebSocketClosedError(code: code))
        } else {
          outbox.yield(.text(#"{"type":"relay-hello","ok":true,"credentialKind":"\#(answer.kind ?? "resume")","leaseExpiresAt":1}"#))
          stage = .awaitingHello
        }
        return nil
      case .awaitingHello:
        outbox.yield(.text(try! desktop.ready(forHello: text)))
        stage = .awaitingAuth
        return nil
      case .awaitingAuth:
        let auth = JSONValue.parse(desktop.openText(text) ?? "")
        let hash = Base64.encode(desktop.schedule!.transcriptHash)
        if auth?["deviceToken"]?.stringValue == host.acceptedToken, auth?["transcriptHashB64"]?.stringValue == hash {
          outbox.yield(.text(desktop.sealText(#"{"type":"e2ee_authenticated","v":2,"transcriptHashB64":"\#(hash)"}"#)))
          stage = .open
        } else {
          outbox.yield(.text(desktop.sealText(#"{"type":"e2ee_error","error":{"code":"unauthorized"}}"#)))
        }
        return nil
      case .open:
        // A frame that fails to open here means the client sent counters out of order.
        guard let plaintext = desktop.openText(text) else {
          outbox.finish(throwing: URLError(.badServerResponse))
          return nil
        }
        return JSONValue.parse(plaintext)
      }
    }
    completion(nil)
    if let request {
      host.record(request)
      host.respond(request, self)
    }
  }

  func receive() async throws -> WebSocketMessage {
    for try await message in inbox {
      return message
    }
    throw URLError(.networkConnectionLost)
  }

  func close() {
    if !silent {
      outbox.finish()
    }
  }

  func reply(_ value: JSONValue) {
    lock.withLock {
      _ = outbox.yield(.text(desktop.sealText(value.serialized())))
    }
  }

  func succeed(_ request: JSONValue, _ result: JSONValue) {
    reply(["id": request["id"] ?? .null, "ok": true, "result": result])
  }

  func stream(_ request: JSONValue, _ result: JSONValue) {
    reply(["id": request["id"] ?? .null, "ok": true, "streaming": true, "result": result])
  }

  func binary(_ bytes: [UInt8]) {
    lock.withLock {
      _ = outbox.yield(.binary(desktop.seal(bytes, kind: .binary)))
    }
  }

  func drop() {
    outbox.finish(throwing: URLError(.networkConnectionLost))
  }
}

func waitFor(_ target: ConnectionState, on connection: OrcaConnection) async {
  for await state in await connection.states() where state == target {
    return
  }
}

@Suite struct OrcaConnectionTests {
  static func echoHost() -> FakeHost {
    FakeHost { request, socket in
      if request["method"]?.stringValue == "fail" {
        socket.reply(["id": request["id"] ?? .null, "ok": false, "error": ["code": "not_found", "message": "nope"]])
      } else {
        socket.succeed(request, ["echo": request["params"] ?? .null])
      }
    }
  }

  @Test func connectsNegotiatesCapabilitiesAndAnswersRequests() async throws {
    let host = Self.echoHost()
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()

    let result = try await connection.request("worktree.list", ["limit": 5])
    #expect(result == ["echo": ["limit": 5]])
    #expect(await connection.state == .connected)

    let first = try #require(host.seenRequests.first)
    #expect(first["method"]?.stringValue == "runtime.clientCapabilities.update")
    #expect(first["params"]?["clientCapabilities"] == ["test.capability", "transport.compressed-frames.v1"])
    #expect(first["deviceToken"]?.stringValue == "token")
    await connection.close()
  }

  @Test func surfacesHostRefusals() async throws {
    let host = Self.echoHost()
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    await #expect(throws: RPCError(code: "not_found", message: "nope", data: nil)) {
      try await connection.request("fail")
    }
    await connection.close()
  }

  @Test func keepsConcurrentRequestsInCounterOrder() async throws {
    let host = Self.echoHost()
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<200 {
        group.addTask {
          let result = try await connection.request("echo", .number(Double(index)))
          #expect(result == ["echo": .number(Double(index))])
        }
      }
      try await group.waitForAll()
    }
    #expect(host.dialCount == 1)
    await connection.close()
  }

  @Test func latchesAuthFailureForARevokedToken() async throws {
    let host = Self.echoHost()
    let connection = OrcaConnection(configuration: host.configuration(token: "revoked"), dialer: host)
    await connection.start()
    await waitFor(.authFailed, on: connection)
    #expect(host.dialCount == 3)
    await #expect(throws: ConnectionError.authenticationRejected) {
      try await connection.request("echo")
    }
  }

  @Test func reconnectsAndReplaysSubscriptions() async throws {
    let host = FakeHost { request, socket in
      if request["method"]?.stringValue == "events.subscribe" {
        socket.stream(request, ["type": "ready", "subscriptionId": .string("sub-\(socket.serial)")])
      } else {
        socket.succeed(request, .null)
      }
    }
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()

    var events = await connection.subscribe("events.subscribe", ["scope": "all"]).events.makeAsyncIterator()
    #expect(try await events.next() == ["type": "ready", "subscriptionId": "sub-1"])

    host.lastSocket?.drop()
    // The replayed request opens the stream again on the new socket.
    #expect(try await events.next() == ["type": "ready", "subscriptionId": "sub-2"])
    #expect(host.dialCount == 2)
    #expect(host.seenRequests.filter { $0["method"]?.stringValue == "events.subscribe" }.count == 2)

    let subscribe = try #require(host.seenRequests.last { $0["method"]?.stringValue == "events.subscribe" })
    host.lastSocket?.succeed(subscribe, ["type": "end"])
    #expect(try await events.next() == ["type": "end"])
    #expect(try await events.next() == nil)
    await connection.close()
  }

  @Test func releasesStreamsTheWayEachFamilyExpects() async throws {
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "runtime.clientEvents.subscribe":
        socket.stream(request, ["type": "ready", "subscriptionId": "events-1"])
      case "session.tabs.subscribe":
        socket.stream(request, ["type": "snapshot", "tabs": []])
      case "plain.subscribe":
        socket.succeed(request, ["unexpected": true])
      default:
        socket.succeed(request, .null)
      }
    }
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    _ = try await connection.request("warmup")

    func consumeFirst(_ subscription: RPCSubscription) async throws {
      for try await _ in subscription.events {
        break
      }
    }
    try await consumeFirst(await connection.subscribe(
      "runtime.clientEvents.subscribe", release: .readyId(method: "runtime.clientEvents.unsubscribe")))
    let tabs = await connection.subscribe(
      "session.tabs.subscribe", ["worktree": "id:w1"],
      release: .requestKeyed(method: "session.tabs.unsubscribe", afterFirstFrame: true) { openerId in
        ["worktree": "id:w1", "subscriptionId": .string(openerId)]
      })
    try await consumeFirst(tabs)
    await connection.unsubscribe(tabs.requestId)

    // Releases are queued from the consumers' termination handlers; a later request flushes behind them.
    try await Task.sleep(for: .milliseconds(50))
    _ = try await connection.request("flush")
    let releases = host.seenRequests.filter { $0["method"]?.stringValue?.hasSuffix("unsubscribe") == true }
    #expect(releases.count == 2)
    #expect(releases.first { $0["method"] == "runtime.clientEvents.unsubscribe" }?["params"] == ["subscriptionId": "events-1"])
    #expect(
      releases.first { $0["method"] == "session.tabs.unsubscribe" }?["params"]
        == ["worktree": "id:w1", "subscriptionId": .string(tabs.requestId)])

    // A streaming request answered by a plain reply never opened.
    await #expect(throws: ConnectionError.streamEndedBeforeReady) {
      try await consumeFirst(await connection.subscribe("plain.subscribe"))
    }
    await connection.close()
  }

  @Test func failsRequestsWhenClosed() async throws {
    let host = FakeHost { _, _ in }
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    let pending = Task { try await connection.request("never.answered") }
    try await Task.sleep(for: .milliseconds(50))
    await connection.close()
    await #expect(throws: ConnectionError.self) {
      _ = try await pending.value
    }
  }
}
