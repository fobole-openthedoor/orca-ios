import CryptoKit
import Foundation

/// The NaCl constructions Orca's hosts use (tweetnacl on the other end).
public enum NaCl {
  public static let keyLength = 32
  public static let nonceLength = 24
  public static let macLength = 16

  public struct KeyPair: Sendable {
    public let publicKey: [UInt8]
    public let secretKey: [UInt8]
  }

  public static func generateKeyPair() -> KeyPair {
    let key = Curve25519.KeyAgreement.PrivateKey()
    return KeyPair(
      publicKey: Array(key.publicKey.rawRepresentation),
      secretKey: Array(key.rawRepresentation)
    )
  }

  public static func randomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  /// `nacl.box.before`: HSalsa20 over the X25519 shared point. Nil for a low-order peer key.
  public static func boxBeforeNM(secretKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
    guard
      let secret = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secretKey),
      let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
      let shared = try? secret.sharedSecretFromKeyAgreement(with: peer)
    else {
      return nil
    }
    let point = shared.withUnsafeBytes { Array($0) }
    return Salsa20.hsalsa20(key: point, input: [UInt8](repeating: 0, count: 16))
  }

  /// `nacl.secretbox`: the 16-byte MAC followed by the ciphertext.
  public static func secretbox(message: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
    precondition(nonce.count == nonceLength && key.count == keyLength)
    // The first 32 keystream bytes are the one-time Poly1305 key.
    var stream = Salsa20.xsalsa20Stream(key: key, nonce: nonce, count: 32 + message.count)
    for index in 0..<message.count {
      stream[32 + index] ^= message[index]
    }
    let mac = Poly1305.tag(message: stream[32...], key: stream[0..<32])
    return mac + stream[32...]
  }

  /// `nacl.secretbox.open`: nil when the box does not authenticate.
  public static func secretboxOpen(box: ArraySlice<UInt8>, nonce: [UInt8], key: [UInt8]) -> [UInt8]? {
    precondition(nonce.count == nonceLength && key.count == keyLength)
    guard box.count >= macLength else {
      return nil
    }
    let mac = box.prefix(macLength)
    let ciphertext = box.dropFirst(macLength)
    var stream = Salsa20.xsalsa20Stream(key: key, nonce: nonce, count: 32 + ciphertext.count)
    let expected = Poly1305.tag(message: ciphertext, key: stream[0..<32])
    guard constantTimeEquals(Array(mac), expected) else {
      return nil
    }
    var index = 32
    for byte in ciphertext {
      stream[index] ^= byte
      index += 1
    }
    return Array(stream[32...])
  }

  public static func constantTimeEquals(_ left: [UInt8], _ right: [UInt8]) -> Bool {
    guard left.count == right.count else {
      return false
    }
    var difference: UInt8 = 0
    for index in 0..<left.count {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }
}

enum Base64 {
  static func encode(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
  }

  /// Nil for anything but canonical padded standard base64.
  static func decodeCanonical(_ value: String, length: Int? = nil) -> [UInt8]? {
    guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else {
      return nil
    }
    if let length, data.count != length {
      return nil
    }
    return Array(data)
  }

  /// Tolerates base64url, missing padding and unused trailing bits, as the pairing code does.
  static func decodeLenient(_ value: String) -> [UInt8]? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.hasSuffix("=") {
      base64.removeLast()
    }
    guard !base64.isEmpty, base64.count % 4 != 1 else {
      return nil
    }
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else {
      return nil
    }
    return Array(data)
  }
}
