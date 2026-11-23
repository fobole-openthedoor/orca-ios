import Foundation

/// What a desktop's pairing QR code or `orca://pair` link carries.
/// Mirrors `src/shared/remote-runtime/pairing/mobile-relay-pairing-offer.ts` in stablyai/orca.
public struct PairingOffer: Sendable, Equatable, Codable {
  public static let version = 2

  public enum Scope: String, Sendable, Codable {
    case mobile
    case runtime
  }

  /// The relay route of an offer. Parsed and kept, though this client only dials direct endpoints so far.
  public struct Relay: Sendable, Equatable, Codable {
    public var directorUrl: String
    public var cellUrl: String
    public var assignmentEpoch: Int
    public var relayHostId: String
    public var inviteToken: String
    public var inviteExpiresAt: Int
  }

  public init(
    endpoint: String, deviceToken: String, publicKeyB64: String, pairedDeviceId: String? = nil, scope: Scope? = nil, relay: Relay? = nil
  ) {
    self.endpoint = endpoint
    self.deviceToken = deviceToken
    self.publicKeyB64 = publicKeyB64
    self.pairedDeviceId = pairedDeviceId
    self.scope = scope
    self.relay = relay
  }

  /// The host's WebSocket URL, e.g. `ws://192.168.1.20:6768`.
  public var endpoint: String
  public var deviceToken: String
  /// The host's pinned Curve25519 public key.
  public var publicKeyB64: String
  public var pairedDeviceId: String?
  public var scope: Scope?
  public var relay: Relay?
}

public enum PairingCode {
  static let codeMaxCharacters = 128 * 1024
  static let inputMaxCharacters = codeMaxCharacters + 1024
  static let endpointMaxCharacters = 16 * 1024
  static let deviceTokenMaxCharacters = 64 * 1024
  static let publicKeyMaxCharacters = 4 * 1024
  static let relayUrlMaxCharacters = 2048
  static let maxInviteTTLMs = 10 * 60 * 1000
  static let inviteExpiryClockSkewMs = 30 * 1000

  /// Parses a scanned, pasted or deep-linked pairing input: an `orca://pair` URL or the bare code.
  public static func parse(_ input: String, now: Date = Date()) -> PairingOffer? {
    guard input.count <= inputMaxCharacters else {
      return nil
    }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    if trimmed.lowercased().hasPrefix("orca://") {
      guard let code = extractCode(fromURL: trimmed) else {
        return nil
      }
      return decode(code, now: now)
    }
    return decode(trimmed, now: now)
  }

  /// The code of an `orca://pair?code=…` or `orca://pair#…` link.
  public static func extractCode(fromURL url: String) -> String? {
    guard url.count <= inputMaxCharacters else {
      return nil
    }
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("orca://") else {
      return nil
    }
    let afterScheme = trimmed.dropFirst("orca://".count)
    let hostEnd = afterScheme.firstIndex(where: { "/?#".contains($0) }) ?? afterScheme.endIndex
    let host = afterScheme[..<hostEnd].lowercased()
    let afterHost = afterScheme[hostEnd...]
    let pathEnd = afterHost.firstIndex(where: { "?#".contains($0) }) ?? afterHost.endIndex
    let path = afterHost[..<pathEnd]
    guard host == "pair", path.isEmpty || path == "/" else {
      return nil
    }
    let rest = afterHost[pathEnd...]
    if let queryStart = rest.firstIndex(of: "?") {
      let query = rest[rest.index(after: queryStart)...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
      var components = URLComponents()
      components.percentEncodedQuery = String(query).replacingOccurrences(of: "+", with: "%20")
      if let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
        return code
      }
    }
    if let hashStart = rest.firstIndex(of: "#") {
      let fragment = rest[rest.index(after: hashStart)...]
      return fragment.isEmpty ? nil : String(fragment)
    }
    return nil
  }

  static func decode(_ code: String, now: Date) -> PairingOffer? {
    guard
      !code.isEmpty,
      code.count <= codeMaxCharacters,
      code.range(of: "^[A-Za-z0-9+/_-]+={0,2}$", options: .regularExpression) != nil,
      let bytes = Base64.decodeLenient(code),
      let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    else {
      return nil
    }
    guard
      (object["v"] as? NSNumber)?.intValue == PairingOffer.version,
      let endpoint = boundedString(object["endpoint"], max: endpointMaxCharacters),
      let deviceToken = boundedString(object["deviceToken"], max: deviceTokenMaxCharacters),
      let publicKeyB64 = boundedString(object["publicKeyB64"], max: publicKeyMaxCharacters)
    else {
      return nil
    }

    var offer = PairingOffer(endpoint: endpoint, deviceToken: deviceToken, publicKeyB64: publicKeyB64)
    if let value = object["pairedDeviceId"] {
      guard let id = boundedString(value, max: 128) else {
        return nil
      }
      offer.pairedDeviceId = id
    }
    if let value = object["scope"] {
      guard let raw = value as? String, let scope = PairingOffer.Scope(rawValue: raw) else {
        return nil
      }
      offer.scope = scope
    }
    if let value = object["relay"] {
      guard let relay = decodeRelay(value, now: now) else {
        return nil
      }
      // Relay routes are mobile-only, and relayHostId derives from the decoded key bytes.
      guard offer.scope != .runtime, Base64.decodeCanonical(publicKeyB64, length: 32) != nil else {
        return nil
      }
      offer.relay = relay
    }
    return offer
  }

  private static func decodeRelay(_ value: Any, now: Date) -> PairingOffer.Relay? {
    guard
      let object = value as? [String: Any],
      (object["v"] as? NSNumber)?.intValue == 1,
      (object["e2eeFraming"] as? NSNumber)?.intValue == 2,
      let directorUrl = object["directorUrl"] as? String, isCanonicalHTTPSOrigin(directorUrl),
      let cellUrl = object["cellUrl"] as? String, isCanonicalHTTPSOrigin(cellUrl),
      let assignmentEpoch = integer(object["assignmentEpoch"]), assignmentEpoch >= 0,
      let relayHostId = object["relayHostId"] as? String,
      relayHostId.range(of: "^[A-Za-z0-9_-]{16}$", options: .regularExpression) != nil,
      let inviteToken = object["inviteToken"] as? String,
      inviteToken.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
      let inviteExpiresAt = integer(object["inviteExpiresAt"])
    else {
      return nil
    }
    let nowMs = Int(now.timeIntervalSince1970 * 1000)
    guard inviteExpiresAt > nowMs, inviteExpiresAt <= nowMs + maxInviteTTLMs + inviteExpiryClockSkewMs else {
      return nil
    }
    return PairingOffer.Relay(
      directorUrl: directorUrl,
      cellUrl: cellUrl,
      assignmentEpoch: assignmentEpoch,
      relayHostId: relayHostId,
      inviteToken: inviteToken,
      inviteExpiresAt: inviteExpiresAt
    )
  }

  private static func boundedString(_ value: Any?, max: Int) -> String? {
    guard let string = value as? String, !string.isEmpty, string.count <= max else {
      return nil
    }
    return string
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !number.isJSONBoolean else {
      return nil
    }
    let double = number.doubleValue
    guard double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else {
      return nil
    }
    return number.intValue
  }

  private static func isCanonicalHTTPSOrigin(_ value: String) -> Bool {
    guard
      value.utf8.count <= relayUrlMaxCharacters,
      let components = URLComponents(string: value),
      components.scheme == "https",
      let host = components.host, !host.isEmpty,
      components.path.isEmpty, components.query == nil, components.fragment == nil,
      components.user == nil, components.password == nil
    else {
      return false
    }
    // An origin never spells out the default port, and its host is lower case.
    return components.port != 443 && host == host.lowercased()
  }
}
