import CryptoKit
import Foundation

/// The paired E2EE v2 handshake messages and the transcript both sides hash.
/// Mirrors `src/shared/remote-runtime/e2ee/mobile-e2ee-v2-contract.ts` in stablyai/orca.
public enum E2EETransport: String, Sendable {
  case direct
  case relay
}

struct E2EEV2Context: Equatable {
  static let protocolName = "orca-mobile-e2ee"
  var transport: E2EETransport
  var relayHostId: String?

  var json: [String: Any] {
    var object: [String: Any] = [
      "protocol": Self.protocolName,
      "initiator": "mobile",
      "responder": "desktop",
      "transport": transport.rawValue,
    ]
    if let relayHostId {
      object["relayHostId"] = relayHostId
    }
    return object
  }

  static func parse(_ value: Any?) -> E2EEV2Context? {
    guard
      let object = value as? [String: Any],
      let rawTransport = object["transport"] as? String,
      let transport = E2EETransport(rawValue: rawTransport),
      object["protocol"] as? String == protocolName,
      object["initiator"] as? String == "mobile",
      object["responder"] as? String == "desktop"
    else {
      return nil
    }
    switch transport {
    case .direct:
      guard Set(object.keys) == ["protocol", "initiator", "responder", "transport"] else {
        return nil
      }
      return E2EEV2Context(transport: transport, relayHostId: nil)
    case .relay:
      guard
        Set(object.keys) == ["protocol", "initiator", "responder", "transport", "relayHostId"],
        let relayHostId = object["relayHostId"] as? String,
        relayHostId.range(of: "^[A-Za-z0-9_-]{16}$", options: .regularExpression) != nil
      else {
        return nil
      }
      return E2EEV2Context(transport: transport, relayHostId: relayHostId)
    }
  }
}

struct E2EEV2Hello {
  var clientPublicKey: [UInt8]
  var clientNonce: [UInt8]
  var context: E2EEV2Context

  var json: [String: Any] {
    [
      "type": "e2ee_hello",
      "v": 2,
      "clientPublicKeyB64": Base64.encode(clientPublicKey),
      "clientNonceB64": Base64.encode(clientNonce),
      "capabilities": ["framing": [2], "payloadKinds": ["text", "binary"]],
      "context": context.json,
    ]
  }
}

struct E2EEV2Ready {
  var desktopPublicKey: [UInt8]
  var desktopNonce: [UInt8]

  /// Nil unless `value` is exactly the ready this hello accepts.
  static func parse(_ value: Any, for hello: E2EEV2Hello) -> E2EEV2Ready? {
    guard
      let object = value as? [String: Any],
      Set(object.keys) == ["type", "v", "desktopPublicKeyB64", "clientNonceB64", "desktopNonceB64", "selection", "context"],
      object["type"] as? String == "e2ee_ready",
      isInteger(object["v"], 2),
      let selection = object["selection"] as? [String: Any],
      Set(selection.keys) == ["framing", "payloadKinds"],
      isInteger(selection["framing"], 2),
      selection["payloadKinds"] as? [String] == ["text", "binary"],
      E2EEV2Context.parse(object["context"]) == hello.context,
      object["clientNonceB64"] as? String == Base64.encode(hello.clientNonce),
      let desktopPublicKeyB64 = object["desktopPublicKeyB64"] as? String,
      let desktopPublicKey = Base64.decodeCanonical(desktopPublicKeyB64, length: 32),
      let desktopNonceB64 = object["desktopNonceB64"] as? String,
      let desktopNonce = Base64.decodeCanonical(desktopNonceB64, length: 32)
    else {
      return nil
    }
    return E2EEV2Ready(desktopPublicKey: desktopPublicKey, desktopNonce: desktopNonce)
  }

  private static func isInteger(_ value: Any?, _ expected: Int) -> Bool {
    guard let number = value as? NSNumber, !number.isJSONBoolean else {
      return false
    }
    return number.doubleValue == Double(expected)
  }
}

enum E2EEV2Transcript {
  static let domain = "orca-mobile-e2ee/v2/transcript"

  /// Length-prefixed (name, value) fields, in the fixed order every implementation shares.
  static func encode(hello: E2EEV2Hello, ready: E2EEV2Ready) -> [UInt8] {
    let context = hello.context
    let payloadKinds = stringList(["text", "binary"])
    let contextFields: [(String, [UInt8])] = [
      ("context.protocol", utf8(E2EEV2Context.protocolName)),
      ("context.initiator", utf8("mobile")),
      ("context.responder", utf8("desktop")),
      ("context.transport", utf8(context.transport.rawValue)),
      ("context.relay-host-id", utf8(context.relayHostId ?? "")),
    ]
    var fields: [(String, [UInt8])] = [
      ("domain", utf8(domain)),
      ("mobile-to-desktop.type", utf8("e2ee_hello")),
      ("mobile-to-desktop.version", uint32(2)),
      ("mobile-to-desktop.client-public-key", hello.clientPublicKey),
      ("mobile-to-desktop.client-nonce", hello.clientNonce),
      ("mobile-to-desktop.capabilities.framing", uint32(1) + uint32(2)),
      ("mobile-to-desktop.capabilities.payload-kinds", payloadKinds),
    ]
    fields += contextFields.map { ("mobile-to-desktop." + $0.0, $0.1) }
    fields += [
      ("desktop-to-mobile.type", utf8("e2ee_ready")),
      ("desktop-to-mobile.version", uint32(2)),
      ("desktop-to-mobile.desktop-public-key", ready.desktopPublicKey),
      ("desktop-to-mobile.client-nonce-echo", hello.clientNonce),
      ("desktop-to-mobile.desktop-nonce", ready.desktopNonce),
      ("desktop-to-mobile.selection.framing", uint32(2)),
      ("desktop-to-mobile.selection.payload-kinds", payloadKinds),
    ]
    fields += contextFields.map { ("desktop-to-mobile." + $0.0, $0.1) }

    var out = [UInt8]()
    for (name, value) in fields {
      let nameBytes = utf8(name)
      out += uint32(nameBytes.count) + nameBytes + uint32(value.count) + value
    }
    return out
  }

  private static func stringList(_ values: [String]) -> [UInt8] {
    values.reduce(uint32(values.count)) { $0 + uint32($1.utf8.count) + utf8($1) }
  }

  private static func utf8(_ value: String) -> [UInt8] {
    Array(value.utf8)
  }

  private static func uint32(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
  }
}

/// The per-connection keys both sides derive once the ready is accepted.
struct E2EEV2KeySchedule: Equatable {
  var mobileToDesktopKey: [UInt8]
  var desktopToMobileKey: [UInt8]
  var sessionId: [UInt8]
  var transcriptHash: [UInt8]

  static func derive(sharedSecret: [UInt8], transcript: [UInt8], clientNonce: [UInt8], desktopNonce: [UInt8]) -> E2EEV2KeySchedule {
    precondition(sharedSecret.count == 32 && clientNonce.count == 32 && desktopNonce.count == 32)
    let transcriptHash = Array(SHA256.hash(data: transcript))
    let salt = Array(SHA256.hash(data: Array("orca-mobile-e2ee/v2/salt\0".utf8) + clientNonce + desktopNonce))
    let info = Array("orca-mobile-e2ee/v2/session\0".utf8) + transcriptHash
    let expanded = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: sharedSecret),
      salt: salt,
      info: info,
      outputByteCount: 96
    ).withUnsafeBytes { Array($0) }
    return E2EEV2KeySchedule(
      mobileToDesktopKey: Array(expanded[0..<32]),
      desktopToMobileKey: Array(expanded[32..<64]),
      sessionId: Array(expanded[64..<96]),
      transcriptHash: transcriptHash
    )
  }
}
