import Foundation
import Testing

@testable import OrcaCore

struct FakeDirector: RelayDirector {
  let cellUrl: String

  func resolve(_ endpoint: RelayEndpoint, resumeToken: String) async throws -> RelayEndpoint {
    var moved = endpoint
    moved.cellUrl = cellUrl
    moved.assignmentEpoch += 1
    return moved
  }
}

final class RelayUpdates: @unchecked Sendable {
  private let lock = NSLock()
  private var updates: [(RelayEndpoint, RelayCredentialBundle)] = []

  func record(_ endpoint: RelayEndpoint, _ bundle: RelayCredentialBundle) {
    lock.withLock { updates.append((endpoint, bundle)) }
  }

  var last: (RelayEndpoint, RelayCredentialBundle)? {
    lock.withLock { updates.last }
  }
}

@Suite struct RelayTests {
  static let endpoint = RelayEndpoint(
    directorUrl: "https://director.test", cellUrl: "https://cell-1.test", assignmentEpoch: 1, relayHostId: "AbCdEf0123_-xyZ9")
  static let farFuture = Date().timeIntervalSince1970 * 1000 + 60 * 24 * 3600 * 1000

  static func bundle(expiresAt: Double = farFuture, grace: Bool = false) -> RelayCredentialBundle {
    RelayCredentialBundle(
      current: RelayCredential(token: "current-token", hash: RelayCrypto.hash("current-token"), version: 2, expiresAt: expiresAt),
      grace: grace ? RelayCredential(token: "grace-token", hash: RelayCrypto.hash("grace-token"), version: 1, expiresAt: farFuture) : nil)
  }

  static func configuration(_ host: FakeHost, bundle: RelayCredentialBundle, updates: RelayUpdates? = nil) -> OrcaConnection.Configuration {
    var configuration = host.configuration()
    configuration.relay = endpoint
    configuration.relayCredential = .resume(bundle)
    configuration.directTimeoutWithRelay = .milliseconds(200)
    configuration.onRelayUpdate = { updates?.record($0, $1) }
    return configuration
  }

  @Test func hashesTheTokenTextAsTheRelayDoes() {
    // base64url(sha256("abc")) without padding.
    #expect(RelayCrypto.hash("abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
    #expect(RelayCrypto.newToken().count == 43)
  }

  @Test func fallsBackToTheRelayAwayFromTheDesktopsNetwork() async throws {
    let host = OrcaConnectionTests.echoHost()
    host.directReachable = false
    let connection = OrcaConnection(configuration: Self.configuration(host, bundle: Self.bundle()), dialer: host)
    await connection.start()
    #expect(try await connection.request("echo", 1) == ["echo": 1])
    #expect(await connection.path == .relay)
    #expect(host.relayCredentials == ["current-token"])
    #expect(host.dialedURLs.last?.absoluteString == "wss://cell-1.test/v1/connect/AbCdEf0123_-xyZ9")
    await connection.close()
  }

  @Test func givesUpOnADirectEndpointThatNeverAnswers() async throws {
    let host = OrcaConnectionTests.echoHost()
    host.directSilent = true
    let connection = OrcaConnection(configuration: Self.configuration(host, bundle: Self.bundle()), dialer: host)
    await connection.start()
    #expect(try await connection.request("echo", 1, timeout: .seconds(5)) == ["echo": 1])
    #expect(await connection.path == .relay)
    await connection.close()
  }

  @Test func prefersTheDirectEndpointWhenItAnswers() async throws {
    let host = OrcaConnectionTests.echoHost()
    let connection = OrcaConnection(configuration: Self.configuration(host, bundle: Self.bundle()), dialer: host)
    await connection.start()
    _ = try await connection.request("echo", 1)
    #expect(await connection.path == .direct)
    #expect(host.relayCredentials.isEmpty)
    await connection.close()
  }

  @Test func triesTheGraceCredentialWhenTheCurrentOneIsRefused() async throws {
    let host = OrcaConnectionTests.echoHost()
    host.directReachable = false
    host.relayAnswer = { (credential: String) -> (kind: String?, refusal: Int?) in
      if credential == "grace-token" {
        return ("resume", nil)
      }
      return (nil, 4401)
    }
    let connection = OrcaConnection(configuration: Self.configuration(host, bundle: Self.bundle(grace: true)), dialer: host)
    await connection.start()
    _ = try await connection.request("echo", 1)
    #expect(host.relayCredentials == ["current-token", "grace-token"])
    await connection.close()
  }

  @Test func followsTheDirectorWhenTheCellMoved() async throws {
    let host = OrcaConnectionTests.echoHost()
    host.directReachable = false
    host.relayAnswer = { [unowned host] (_: String) -> (kind: String?, refusal: Int?) in
      if host.dialedURLs.last?.host == "cell-2.test" {
        return ("resume", nil)
      }
      return (nil, 4409)
    }
    let updates = RelayUpdates()
    let connection = OrcaConnection(
      configuration: Self.configuration(host, bundle: Self.bundle(), updates: updates), dialer: host,
      director: FakeDirector(cellUrl: "https://cell-2.test"))
    await connection.start()
    _ = try await connection.request("echo", 1)
    #expect(host.dialedURLs.last?.host == "cell-2.test")
    #expect(updates.last?.0.cellUrl == "https://cell-2.test")
    await connection.close()
  }

  @Test func rotatesACredentialNearItsExpiry() async throws {
    let installed = LockedBox<JSONValue?>(nil)
    let host = FakeHost { request, socket in
      let params = request["params"] ?? .null
      switch request["method"]?.stringValue {
      case "pairing.provisionRelay":
        installed.set(["v": 1, "reqId": params["reqId"] ?? .null, "authorizationMode": "authenticated-direct", "currentVersion": 3,
                       "resumeExpiresAt": .number(Self.farFuture), "graceExpiresAt": .number(Self.farFuture - 1)])
        socket.succeed(request, installed.get()!)
      case "pairing.getEndpoints":
        var reply: [String: JSONValue] = ["v": 1, "relay": ["v": 1, "directorUrl": "https://director.test", "cellUrl": "https://cell-1.test",
                                                            "assignmentEpoch": 1, "relayHostId": "AbCdEf0123_-xyZ9", "e2eeFraming": 2]]
        if let result = installed.get() {
          reply["installStatus"] = ["v": 1, "reqId": params["installReqId"] ?? .null, "state": "committed", "result": result]
        } else {
          reply["installStatus"] = ["v": 1, "reqId": params["installReqId"] ?? .null, "state": "not-found"]
        }
        socket.succeed(request, .object(reply))
      default:
        socket.succeed(request, .null)
      }
    }
    let updates = RelayUpdates()
    let soon = Date().timeIntervalSince1970 * 1000 + 24 * 3600 * 1000
    let connection = OrcaConnection(configuration: Self.configuration(host, bundle: Self.bundle(expiresAt: soon), updates: updates), dialer: host)
    await connection.start()
    _ = try await connection.request("warmup")
    for _ in 0..<100 where updates.last?.1.current.version != 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    let saved = try #require(updates.last?.1)
    #expect(saved.current.version == 3)
    #expect(saved.current.hash == RelayCrypto.hash(saved.current.token))
    #expect(saved.grace?.token == "current-token")
    #expect(saved.pending == nil)
    let provision = try #require(host.seenRequests.first { $0["method"] == "pairing.provisionRelay" })
    #expect(provision["params"]?["expectedCurrentHash"]?.stringValue == RelayCrypto.hash("current-token"))
    await connection.close()
  }
}

@Suite struct PairingFlowTests {
  @Test func installsARelayCredentialAndExchangesTheScannedCode() async throws {
    let installedHash = LockedBox<String?>(nil)
    let host = FakeHost(acceptedToken: "scanned") { request, socket in
      let params = request["params"] ?? .null
      switch request["method"]?.stringValue {
      case "status.get":
        socket.succeed(request, ["machineName": "Studio", "capabilities": ["pairing.ticket-exchange.v1"]])
      case "pairing.provisionRelay":
        installedHash.set(params["newResumeTokenHash"]?.stringValue)
        socket.succeed(request, ["v": 1, "reqId": params["reqId"] ?? .null, "authorizationMode": "relay-basis", "currentVersion": 1,
                                 "resumeExpiresAt": .number(RelayTests.farFuture)])
      case "pairing.getEndpoints":
        socket.succeed(request, [
          "v": 1,
          "relay": ["v": 1, "directorUrl": "https://director.test", "cellUrl": "https://cell-9.test", "assignmentEpoch": 4,
                    "relayHostId": "AbCdEf0123_-xyZ9", "e2eeFraming": 2],
          "installStatus": ["v": 1, "reqId": params["installReqId"] ?? .null, "state": "committed",
                            "result": ["v": 1, "reqId": params["installReqId"] ?? .null, "authorizationMode": "relay-basis",
                                       "currentVersion": 1, "resumeExpiresAt": .number(RelayTests.farFuture)]],
        ])
      case "pairing.exchangeTicket":
        socket.succeed(request, ["deviceId": "phone-1"])
      default:
        socket.succeed(request, .null)
      }
    }
    // Away from home: only the relay invite gets through.
    host.directReachable = false
    host.relayAnswer = { (credential: String) -> (kind: String?, refusal: Int?) in
      if credential == String(repeating: "i", count: 43) {
        return ("invite", nil)
      }
      return (nil, 4401)
    }
    let offer = PairingOffer(
      endpoint: "ws://192.168.1.20:6768", deviceToken: "scanned", publicKeyB64: host.publicKeyB64,
      relay: .init(directorUrl: "https://director.test", cellUrl: "https://cell-1.test", assignmentEpoch: 3,
                   relayHostId: "AbCdEf0123_-xyZ9", inviteToken: String(repeating: "i", count: 43), inviteExpiresAt: 0))

    let paired = try await PairingFlow.pair(offer, name: "Desktop", dialer: host, timeout: .seconds(5))
    #expect(paired.name == "Studio")
    #expect(paired.relay?.cellUrl == "https://cell-9.test")
    let credentials = try #require(paired.relayCredentials)
    #expect(credentials.current.hash == installedHash.get())
    #expect(credentials.current.hash == RelayCrypto.hash(credentials.current.token))
    #expect(paired.deviceToken.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil)
  }

  @Test func reportsARevokedCode() async throws {
    let host = FakeHost(acceptedToken: "other") { request, socket in socket.succeed(request, .null) }
    let offer = PairingOffer(endpoint: "ws://192.168.1.20:6768", deviceToken: "stale", publicKeyB64: host.publicKeyB64)
    await #expect(throws: PairingError.rejected) {
      try await PairingFlow.pair(offer, name: "Desktop", dialer: host, timeout: .seconds(5))
    }
  }
}
