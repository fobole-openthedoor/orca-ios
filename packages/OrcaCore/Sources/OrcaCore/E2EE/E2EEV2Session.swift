import Foundation

/// One sealed frame: a nonce both sides can predict, then a secretbox over header + payload.
/// Mirrors `mobile-e2ee-v2-framing.ts` in stablyai/orca.
enum E2EEV2Frame {
  enum Direction: UInt8 {
    case mobileToDesktop = 0
    case desktopToMobile = 1
  }

  enum PayloadKind: UInt8 {
    case text = 0
    case binary = 1
  }

  static let sessionIdLength = 32
  static let headerLength = sessionIdLength + 1 + 1 + 8
  static let frameVersion: UInt8 = 2

  static func seal(payload: [UInt8], key: [UInt8], sessionId: [UInt8], direction: Direction, kind: PayloadKind, counter: UInt64) -> [UInt8] {
    let nonce = nonce(sessionId: sessionId, direction: direction, kind: kind, counter: counter)
    let plaintext = header(sessionId: sessionId, direction: direction, kind: kind, counter: counter) + payload
    return nonce + NaCl.secretbox(message: plaintext, nonce: nonce, key: key)
  }

  /// Nil unless the frame is the next one this direction and kind expects.
  static func open(frame: [UInt8], key: [UInt8], sessionId: [UInt8], direction: Direction, kind: PayloadKind, expectedCounter: UInt64) -> [UInt8]? {
    guard frame.count >= NaCl.nonceLength + NaCl.macLength + headerLength else {
      return nil
    }
    let nonce = nonce(sessionId: sessionId, direction: direction, kind: kind, counter: expectedCounter)
    guard
      NaCl.constantTimeEquals(Array(frame[0..<NaCl.nonceLength]), nonce),
      let plaintext = NaCl.secretboxOpen(box: frame[NaCl.nonceLength...], nonce: nonce, key: key)
    else {
      return nil
    }
    let expectedHeader = header(sessionId: sessionId, direction: direction, kind: kind, counter: expectedCounter)
    guard NaCl.constantTimeEquals(Array(plaintext[0..<headerLength]), expectedHeader) else {
      return nil
    }
    return Array(plaintext[headerLength...])
  }

  private static func header(sessionId: [UInt8], direction: Direction, kind: PayloadKind, counter: UInt64) -> [UInt8] {
    sessionId + [direction.rawValue, kind.rawValue] + bigEndian(counter)
  }

  private static func nonce(sessionId: [UInt8], direction: Direction, kind: PayloadKind, counter: UInt64) -> [UInt8] {
    // Fresh per-socket keys make this layout unique without another random draw.
    Array(sessionId[0..<12]) + [frameVersion, direction.rawValue, kind.rawValue, 0] + bigEndian(counter)
  }

  private static func bigEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64(56 - $0 * 8)) }
  }
}

public enum E2EEError: Error, Equatable {
  case invalidHostPublicKey
  case notReady
}

/// The phone's side of one socket's E2EE v2 session: hello, ready, then ordered sealed frames.
/// Mirrors `paired-e2ee-v2-client-session.ts` in stablyai/orca. Not thread-safe; its owner serialises use.
public final class E2EEV2ClientSession {
  private let hello: E2EEV2Hello
  private let clientSecretKey: [UInt8]
  private let pinnedDesktopPublicKey: [UInt8]
  private var schedule: E2EEV2KeySchedule?
  private var inboundCounter: UInt64 = 0
  private var outboundCounter: UInt64 = 0

  public init(
    desktopPublicKeyB64: String,
    transport: E2EETransport,
    relayHostId: String? = nil,
    clientKeyPair: NaCl.KeyPair? = nil,
    clientNonce: [UInt8]? = nil
  ) throws {
    guard let desktopPublicKey = Data(base64Encoded: desktopPublicKeyB64).map(Array.init), desktopPublicKey.count == 32 else {
      throw E2EEError.invalidHostPublicKey
    }
    let keyPair = clientKeyPair ?? NaCl.generateKeyPair()
    let nonce = clientNonce ?? NaCl.randomBytes(32)
    precondition(nonce.count == 32)
    self.clientSecretKey = keyPair.secretKey
    self.pinnedDesktopPublicKey = desktopPublicKey
    self.hello = E2EEV2Hello(
      clientPublicKey: keyPair.publicKey,
      clientNonce: nonce,
      context: E2EEV2Context(transport: transport, relayHostId: relayHostId)
    )
  }

  /// The plaintext hello frame that opens the socket.
  public var helloText: String {
    Self.serialize(hello.json)
  }

  public var isReady: Bool {
    schedule != nil
  }

  /// The transcript hash both sides echo during auth. Nil before the ready is accepted.
  public var transcriptHashB64: String? {
    schedule.map { Base64.encode($0.transcriptHash) }
  }

  /// Accepts the host's plaintext ready frame; false leaves the session unkeyed.
  public func acceptReady(_ text: String) -> Bool {
    guard
      schedule == nil,
      let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
      let ready = E2EEV2Ready.parse(value, for: hello),
      // The host must prove the key pinned at pairing, not just any key.
      NaCl.constantTimeEquals(ready.desktopPublicKey, pinnedDesktopPublicKey),
      let sharedSecret = NaCl.boxBeforeNM(secretKey: clientSecretKey, peerPublicKey: pinnedDesktopPublicKey)
    else {
      return false
    }
    schedule = E2EEV2KeySchedule.derive(
      sharedSecret: sharedSecret,
      transcript: E2EEV2Transcript.encode(hello: hello, ready: ready),
      clientNonce: hello.clientNonce,
      desktopNonce: ready.desktopNonce
    )
    return true
  }

  /// The sealed token-auth frame sent right after the ready.
  public func sealTokenAuth(deviceToken: String) throws -> String {
    guard let transcriptHashB64 else {
      throw E2EEError.notReady
    }
    return try sealText(
      Self.serialize(["type": "e2ee_auth", "v": 2, "transcriptHashB64": transcriptHashB64, "deviceToken": deviceToken])
    )
  }

  /// Whether a decrypted reply is exactly this session's `e2ee_authenticated`.
  public func isAuthenticatedReply(_ plaintext: String) -> Bool {
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any],
      Set(object.keys) == ["type", "v", "transcriptHashB64"],
      object["type"] as? String == "e2ee_authenticated",
      (object["v"] as? NSNumber)?.intValue == 2,
      object["transcriptHashB64"] as? String == transcriptHashB64
    else {
      return false
    }
    return true
  }

  public func sealText(_ plaintext: String) throws -> String {
    Base64.encode(try seal(Array(plaintext.utf8), kind: .text))
  }

  public func sealBinary(_ plaintext: [UInt8]) throws -> [UInt8] {
    try seal(plaintext, kind: .binary)
  }

  /// Nil for a frame that is not authentic or not the next expected one.
  public func openText(_ frameB64: String) -> String? {
    guard let frame = Base64.decodeCanonical(frameB64), let plaintext = open(frame, kind: .text) else {
      return nil
    }
    return String(decoding: plaintext, as: UTF8.self)
  }

  public func openBinary(_ frame: [UInt8]) -> [UInt8]? {
    open(frame, kind: .binary)
  }

  private func seal(_ payload: [UInt8], kind: E2EEV2Frame.PayloadKind) throws -> [UInt8] {
    guard let schedule else {
      throw E2EEError.notReady
    }
    let frame = E2EEV2Frame.seal(
      payload: payload,
      key: schedule.mobileToDesktopKey,
      sessionId: schedule.sessionId,
      direction: .mobileToDesktop,
      kind: kind,
      counter: outboundCounter
    )
    outboundCounter += 1
    return frame
  }

  private func open(_ frame: [UInt8], kind: E2EEV2Frame.PayloadKind) -> [UInt8]? {
    guard let schedule else {
      return nil
    }
    let plaintext = E2EEV2Frame.open(
      frame: frame,
      key: schedule.desktopToMobileKey,
      sessionId: schedule.sessionId,
      direction: .desktopToMobile,
      kind: kind,
      expectedCounter: inboundCounter
    )
    if plaintext != nil {
      inboundCounter += 1
    }
    return plaintext
  }

  private static func serialize(_ object: [String: Any]) -> String {
    // Only ever fed JSON-safe literals, so serialisation cannot fail.
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}
