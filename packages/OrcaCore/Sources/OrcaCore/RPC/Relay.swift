import CryptoKit
import Foundation

/// Where a host's relay sessions are served: a director that assigns hosts to cells, and the cell assigned now.
/// Mirrors `MobileRelayEndpointSchema` in stablyai/orca.
public struct RelayEndpoint: Sendable, Equatable, Codable {
  public var directorUrl: String
  public var cellUrl: String
  public var assignmentEpoch: Int
  public var relayHostId: String

  public init(directorUrl: String, cellUrl: String, assignmentEpoch: Int, relayHostId: String) {
    self.directorUrl = directorUrl
    self.cellUrl = cellUrl
    self.assignmentEpoch = assignmentEpoch
    self.relayHostId = relayHostId
  }

  init(offer: PairingOffer.Relay) {
    self.init(
      directorUrl: offer.directorUrl, cellUrl: offer.cellUrl, assignmentEpoch: offer.assignmentEpoch,
      relayHostId: offer.relayHostId)
  }

  init?(_ json: JSONValue?) {
    guard
      let json,
      let directorUrl = json["directorUrl"]?.stringValue,
      let cellUrl = json["cellUrl"]?.stringValue,
      let assignmentEpoch = json["assignmentEpoch"]?.intValue,
      let relayHostId = json["relayHostId"]?.stringValue
    else {
      return nil
    }
    self.init(directorUrl: directorUrl, cellUrl: cellUrl, assignmentEpoch: assignmentEpoch, relayHostId: relayHostId)
  }

  /// The phone-connect route on the cell, or on the director when a cell is unknown.
  func connectURL(base: String? = nil) -> URL? {
    guard var components = URLComponents(string: base ?? cellUrl) else {
      return nil
    }
    components.scheme = "wss"
    components.percentEncodedPath = "/v1/connect/" + (relayHostId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relayHostId)
    return components.url
  }
}

/// A resume token the relay accepts for this phone. The relay stores only its hash.
public struct RelayCredential: Sendable, Equatable, Codable {
  public var token: String
  public var hash: String
  public var version: Int
  /// Milliseconds since 1970.
  public var expiresAt: Double
}

/// The phone's relay credentials: the current one, the previous one while the relay still honours it,
/// and one being installed, kept until the host has authoritatively committed it.
public struct RelayCredentialBundle: Sendable, Equatable, Codable {
  public struct Pending: Sendable, Equatable, Codable {
    public var token: String
    public var hash: String
    public var reqId: String
  }

  public var current: RelayCredential
  public var grace: RelayCredential?
  public var pending: Pending?

  public init(current: RelayCredential, grace: RelayCredential? = nil, pending: Pending? = nil) {
    self.current = current
    self.grace = grace
    self.pending = pending
  }

  /// Rotated when it has a week or less left, or when an install was interrupted.
  static let rotationWindowMs: Double = 7 * 24 * 60 * 60 * 1000

  func needsRotation(nowMs: Double) -> Bool {
    pending != nil || current.expiresAt - nowMs <= Self.rotationWindowMs
  }

  init(installed pending: Pending, result: JSONValue) {
    current = RelayCredential(
      token: pending.token, hash: pending.hash, version: result["currentVersion"]?.intValue ?? 1,
      expiresAt: result["resumeExpiresAt"]?.doubleValue ?? 0)
  }

  /// The bundle once the host has committed `pending`; the old current stays as grace while the host honours it.
  func installing(_ pending: Pending, result: JSONValue) -> RelayCredentialBundle {
    var next = RelayCredentialBundle(installed: pending, result: result)
    if let graceExpiresAt = result["graceExpiresAt"]?.doubleValue {
      var grace = current
      grace.expiresAt = graceExpiresAt
      next.grace = grace
    }
    return next
  }

  /// Extends the expiry the relay just confirmed for the credential that was used.
  mutating func applyConfirmation(_ confirmation: JSONValue, usedVersion: Int) {
    let acceptedAs = confirmation["acceptedAs"]?.stringValue
    if acceptedAs == "current", confirmation["renewed"]?.boolValue == true, current.version == usedVersion,
      confirmation["currentVersion"]?.intValue == usedVersion, let expiry = confirmation["resumeExpiresAt"]?.doubleValue
    {
      current.expiresAt = expiry
    } else if acceptedAs == "grace", grace?.version == usedVersion, let expiry = confirmation["graceExpiresAt"]?.doubleValue {
      grace?.expiresAt = expiry
    }
  }

  /// The credentials worth offering the relay, best first.
  func usable(nowMs: Double) -> [RelayCredential] {
    [current, grace].compactMap { $0 }.filter { $0.expiresAt > nowMs }
  }
}

public enum RelayCredentialSource: Sendable, Equatable {
  /// The single-use invite from a pairing offer.
  case invite(String)
  case resume(RelayCredentialBundle)
}

/// Close codes a relay cell uses for the phone's socket.
public enum RelayCloseCode: Int, Sendable {
  case badCredential = 4401
  case hostOffline = 4404
  case peerDropped = 4408
  case wrongCell = 4409
  case limitExceeded = 4429
  case draining = 4503
}

public enum RelayError: Error, Sendable, Equatable {
  /// The cell refused or closed with one of its codes.
  case closed(code: Int)
  case invalidHello
  case directorRefused(status: Int)
  case noUsableCredential
}

enum RelayCrypto {
  static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// A fresh bearer token: 32 random bytes, base64url.
  static func newToken() -> String {
    base64URL(NaCl.randomBytes(32))
  }

  static func newRequestId(_ prefix: String) -> String {
    prefix + "-" + base64URL(NaCl.randomBytes(16))
  }

  /// The relay hashes the serialised token text, not its decoded bytes.
  static func hash(_ token: String) -> String {
    base64URL(Array(SHA256.hash(data: Data(token.utf8))))
  }
}

/// Asks the director which cell serves a host now.
public protocol RelayDirector: Sendable {
  func resolve(_ endpoint: RelayEndpoint, resumeToken: String) async throws -> RelayEndpoint
}

public struct HTTPRelayDirector: RelayDirector {
  private let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func resolve(_ endpoint: RelayEndpoint, resumeToken: String) async throws -> RelayEndpoint {
    guard let url = URL(string: "/v1/resolve", relativeTo: URL(string: endpoint.directorUrl)) else {
      throw RelayError.directorRefused(status: 0)
    }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = Data(
      (["v": 1, "relayHostId": .string(endpoint.relayHostId), "resumeToken": .string(resumeToken)] as JSONValue).serialized().utf8)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status), data.count <= 64 * 1024 else {
      throw RelayError.directorRefused(status: status)
    }
    let reply = JSONValue.parse(String(decoding: data, as: UTF8.self))
    guard
      let cellUrl = reply?["cellUrl"]?.stringValue, cellUrl.hasPrefix("https://"),
      let epoch = reply?["assignmentEpoch"]?.intValue
    else {
      throw RelayError.directorRefused(status: status)
    }
    var resolved = endpoint
    resolved.cellUrl = cellUrl
    resolved.assignmentEpoch = epoch
    return resolved
  }
}

/// The plaintext exchange that opens a relay socket, before the end-to-end handshake inside it.
enum RelayHandshake {
  static func auth(credential: String) -> String {
    (["type": "relay-auth", "v": 1, "mode": "connect", "credential": .string(credential)] as JSONValue).serialized()
  }

  struct Hello: Equatable {
    var kind: String
    var leaseExpiresAt: Double?
  }

  /// The accepted hello, or a refusal carrying the cell's code.
  static func readHello(_ text: String) throws -> Hello {
    guard let hello = JSONValue.parse(text), hello["type"]?.stringValue == "relay-hello", let ok = hello["ok"]?.boolValue else {
      throw RelayError.invalidHello
    }
    guard ok else {
      throw RelayError.closed(code: hello["code"]?.intValue ?? 4000)
    }
    guard let kind = hello["credentialKind"]?.stringValue else {
      throw RelayError.invalidHello
    }
    return Hello(kind: kind, leaseExpiresAt: hello["leaseExpiresAt"]?.doubleValue)
  }
}
