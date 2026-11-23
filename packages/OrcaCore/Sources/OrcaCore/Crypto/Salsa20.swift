// Salsa20/20, HSalsa20 and the XSalsa20 keystream, as NaCl defines them.
// CryptoKit has no XSalsa20-Poly1305, and Orca's hosts speak tweetnacl's secretbox.

enum Salsa20 {
  // "expand 32-byte k"
  private static let sigma: (UInt32, UInt32, UInt32, UInt32) = (
    0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574
  )

  /// One 64-byte keystream block for a 32-byte key, 8-byte nonce and block counter.
  static func block(key: [UInt32], nonce0: UInt32, nonce1: UInt32, counter: UInt64, into out: inout [UInt8], at offset: Int) {
    var state = [UInt32](repeating: 0, count: 16)
    state[0] = sigma.0
    state[1] = key[0]
    state[2] = key[1]
    state[3] = key[2]
    state[4] = key[3]
    state[5] = sigma.1
    state[6] = nonce0
    state[7] = nonce1
    state[8] = UInt32(truncatingIfNeeded: counter)
    state[9] = UInt32(truncatingIfNeeded: counter >> 32)
    state[10] = sigma.2
    state[11] = key[4]
    state[12] = key[5]
    state[13] = key[6]
    state[14] = key[7]
    state[15] = sigma.3
    var mixed = state
    rounds(&mixed)
    for index in 0..<16 {
      let word = mixed[index] &+ state[index]
      out[offset + index * 4] = UInt8(truncatingIfNeeded: word)
      out[offset + index * 4 + 1] = UInt8(truncatingIfNeeded: word >> 8)
      out[offset + index * 4 + 2] = UInt8(truncatingIfNeeded: word >> 16)
      out[offset + index * 4 + 3] = UInt8(truncatingIfNeeded: word >> 24)
    }
  }

  /// HSalsa20: a 32-byte subkey from a 32-byte key and 16 input bytes.
  static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
    precondition(key.count == 32 && input.count == 16)
    let keyWords = words(key)
    let inputWords = words(input)
    var state = [UInt32](repeating: 0, count: 16)
    state[0] = sigma.0
    state[1] = keyWords[0]
    state[2] = keyWords[1]
    state[3] = keyWords[2]
    state[4] = keyWords[3]
    state[5] = sigma.1
    state[6] = inputWords[0]
    state[7] = inputWords[1]
    state[8] = inputWords[2]
    state[9] = inputWords[3]
    state[10] = sigma.2
    state[11] = keyWords[4]
    state[12] = keyWords[5]
    state[13] = keyWords[6]
    state[14] = keyWords[7]
    state[15] = sigma.3
    rounds(&state)
    var out = [UInt8]()
    out.reserveCapacity(32)
    for index in [0, 5, 10, 15, 6, 7, 8, 9] {
      let word = state[index]
      out.append(UInt8(truncatingIfNeeded: word))
      out.append(UInt8(truncatingIfNeeded: word >> 8))
      out.append(UInt8(truncatingIfNeeded: word >> 16))
      out.append(UInt8(truncatingIfNeeded: word >> 24))
    }
    return out
  }

  /// `count` bytes of XSalsa20 keystream for a 32-byte key and 24-byte nonce.
  static func xsalsa20Stream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
    precondition(key.count == 32 && nonce.count == 24)
    let subkey = words(hsalsa20(key: key, input: Array(nonce[0..<16])))
    let tail = words(Array(nonce[16..<24]))
    let blocks = (count + 63) / 64
    var stream = [UInt8](repeating: 0, count: blocks * 64)
    for index in 0..<blocks {
      block(key: subkey, nonce0: tail[0], nonce1: tail[1], counter: UInt64(index), into: &stream, at: index * 64)
    }
    stream.removeLast(blocks * 64 - count)
    return stream
  }

  static func words(_ bytes: [UInt8]) -> [UInt32] {
    var result = [UInt32](repeating: 0, count: bytes.count / 4)
    for index in 0..<result.count {
      result[index] =
        UInt32(bytes[index * 4])
        | UInt32(bytes[index * 4 + 1]) << 8
        | UInt32(bytes[index * 4 + 2]) << 16
        | UInt32(bytes[index * 4 + 3]) << 24
    }
    return result
  }

  @inline(__always)
  private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
    (value << count) | (value >> (32 - count))
  }

  private static func rounds(_ state: inout [UInt32]) {
    var x0 = state[0], x1 = state[1], x2 = state[2], x3 = state[3]
    var x4 = state[4], x5 = state[5], x6 = state[6], x7 = state[7]
    var x8 = state[8], x9 = state[9], x10 = state[10], x11 = state[11]
    var x12 = state[12], x13 = state[13], x14 = state[14], x15 = state[15]
    for _ in 0..<10 {
      // Column round.
      x4 ^= rotl(x0 &+ x12, 7)
      x8 ^= rotl(x4 &+ x0, 9)
      x12 ^= rotl(x8 &+ x4, 13)
      x0 ^= rotl(x12 &+ x8, 18)
      x9 ^= rotl(x5 &+ x1, 7)
      x13 ^= rotl(x9 &+ x5, 9)
      x1 ^= rotl(x13 &+ x9, 13)
      x5 ^= rotl(x1 &+ x13, 18)
      x14 ^= rotl(x10 &+ x6, 7)
      x2 ^= rotl(x14 &+ x10, 9)
      x6 ^= rotl(x2 &+ x14, 13)
      x10 ^= rotl(x6 &+ x2, 18)
      x3 ^= rotl(x15 &+ x11, 7)
      x7 ^= rotl(x3 &+ x15, 9)
      x11 ^= rotl(x7 &+ x3, 13)
      x15 ^= rotl(x11 &+ x7, 18)
      // Row round.
      x1 ^= rotl(x0 &+ x3, 7)
      x2 ^= rotl(x1 &+ x0, 9)
      x3 ^= rotl(x2 &+ x1, 13)
      x0 ^= rotl(x3 &+ x2, 18)
      x6 ^= rotl(x5 &+ x4, 7)
      x7 ^= rotl(x6 &+ x5, 9)
      x4 ^= rotl(x7 &+ x6, 13)
      x5 ^= rotl(x4 &+ x7, 18)
      x11 ^= rotl(x10 &+ x9, 7)
      x8 ^= rotl(x11 &+ x10, 9)
      x9 ^= rotl(x8 &+ x11, 13)
      x10 ^= rotl(x9 &+ x8, 18)
      x12 ^= rotl(x15 &+ x14, 7)
      x13 ^= rotl(x12 &+ x15, 9)
      x14 ^= rotl(x13 &+ x12, 13)
      x15 ^= rotl(x14 &+ x13, 18)
    }
    state[0] = x0; state[1] = x1; state[2] = x2; state[3] = x3
    state[4] = x4; state[5] = x5; state[6] = x6; state[7] = x7
    state[8] = x8; state[9] = x9; state[10] = x10; state[11] = x11
    state[12] = x12; state[13] = x13; state[14] = x14; state[15] = x15
  }
}
