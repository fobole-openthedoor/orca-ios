// Poly1305 one-time authenticator, 26-bit limbs (after poly1305-donna-32).

enum Poly1305 {
  static func tag(message: ArraySlice<UInt8>, key: ArraySlice<UInt8>) -> [UInt8] {
    precondition(key.count == 32)
    let key = Array(key)
    let limbMask: UInt32 = 0x3ff_ffff

    let r0 = le32(key, 0) & 0x3ff_ffff
    let r1 = (le32(key, 3) >> 2) & 0x3ff_ff03
    let r2 = (le32(key, 6) >> 4) & 0x3ff_c0ff
    let r3 = (le32(key, 9) >> 6) & 0x3f0_3fff
    let r4 = (le32(key, 12) >> 8) & 0x00f_ffff
    let s1 = r1 &* 5, s2 = r2 &* 5, s3 = r3 &* 5, s4 = r4 &* 5

    var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0

    var block = [UInt8](repeating: 0, count: 16)
    var position = message.startIndex
    while position < message.endIndex {
      let remaining = message.endIndex - position
      var highBit: UInt32 = 1 << 24
      if remaining >= 16 {
        for index in 0..<16 {
          block[index] = message[position + index]
        }
        position += 16
      } else {
        // The last short block is padded with a 1 byte, then zeros, and carries no high bit.
        for index in 0..<16 {
          block[index] = index < remaining ? message[position + index] : 0
        }
        block[remaining] = 1
        highBit = 0
        position = message.endIndex
      }

      h0 &+= le32(block, 0) & limbMask
      h1 &+= (le32(block, 3) >> 2) & limbMask
      h2 &+= (le32(block, 6) >> 4) & limbMask
      h3 &+= (le32(block, 9) >> 6) & limbMask
      h4 &+= (le32(block, 12) >> 8) | highBit

      let d0 = mul(h0, r0) &+ mul(h1, s4) &+ mul(h2, s3) &+ mul(h3, s2) &+ mul(h4, s1)
      var d1 = mul(h0, r1) &+ mul(h1, r0) &+ mul(h2, s4) &+ mul(h3, s3) &+ mul(h4, s2)
      var d2 = mul(h0, r2) &+ mul(h1, r1) &+ mul(h2, r0) &+ mul(h3, s4) &+ mul(h4, s3)
      var d3 = mul(h0, r3) &+ mul(h1, r2) &+ mul(h2, r1) &+ mul(h3, r0) &+ mul(h4, s4)
      var d4 = mul(h0, r4) &+ mul(h1, r3) &+ mul(h2, r2) &+ mul(h3, r1) &+ mul(h4, r0)

      var carry = UInt32(truncatingIfNeeded: d0 >> 26)
      h0 = UInt32(truncatingIfNeeded: d0) & limbMask
      d1 &+= UInt64(carry)
      carry = UInt32(truncatingIfNeeded: d1 >> 26)
      h1 = UInt32(truncatingIfNeeded: d1) & limbMask
      d2 &+= UInt64(carry)
      carry = UInt32(truncatingIfNeeded: d2 >> 26)
      h2 = UInt32(truncatingIfNeeded: d2) & limbMask
      d3 &+= UInt64(carry)
      carry = UInt32(truncatingIfNeeded: d3 >> 26)
      h3 = UInt32(truncatingIfNeeded: d3) & limbMask
      d4 &+= UInt64(carry)
      carry = UInt32(truncatingIfNeeded: d4 >> 26)
      h4 = UInt32(truncatingIfNeeded: d4) & limbMask
      h0 &+= carry &* 5
      carry = h0 >> 26
      h0 &= limbMask
      h1 &+= carry
    }

    // Fully carry h.
    var carry = h1 >> 26
    h1 &= limbMask
    h2 &+= carry
    carry = h2 >> 26
    h2 &= limbMask
    h3 &+= carry
    carry = h3 >> 26
    h3 &= limbMask
    h4 &+= carry
    carry = h4 >> 26
    h4 &= limbMask
    h0 &+= carry &* 5
    carry = h0 >> 26
    h0 &= limbMask
    h1 &+= carry

    // Compute h + -p, and select it when h >= p.
    var g0 = h0 &+ 5
    carry = g0 >> 26
    g0 &= limbMask
    var g1 = h1 &+ carry
    carry = g1 >> 26
    g1 &= limbMask
    var g2 = h2 &+ carry
    carry = g2 >> 26
    g2 &= limbMask
    var g3 = h3 &+ carry
    carry = g3 >> 26
    g3 &= limbMask
    var g4 = h4 &+ carry &- (1 << 26)

    var select = (g4 >> 31) &- 1
    g0 &= select
    g1 &= select
    g2 &= select
    g3 &= select
    g4 &= select
    select = ~select
    h0 = (h0 & select) | g0
    h1 = (h1 & select) | g1
    h2 = (h2 & select) | g2
    h3 = (h3 & select) | g3
    h4 = (h4 & select) | g4

    // h %= 2^128, then add the pad.
    let w0 = h0 | (h1 << 26)
    let w1 = (h1 >> 6) | (h2 << 20)
    let w2 = (h2 >> 12) | (h3 << 14)
    let w3 = (h3 >> 18) | (h4 << 8)

    var sum = UInt64(w0) &+ UInt64(le32(key, 16))
    let t0 = UInt32(truncatingIfNeeded: sum)
    sum = UInt64(w1) &+ UInt64(le32(key, 20)) &+ (sum >> 32)
    let t1 = UInt32(truncatingIfNeeded: sum)
    sum = UInt64(w2) &+ UInt64(le32(key, 24)) &+ (sum >> 32)
    let t2 = UInt32(truncatingIfNeeded: sum)
    sum = UInt64(w3) &+ UInt64(le32(key, 28)) &+ (sum >> 32)
    let t3 = UInt32(truncatingIfNeeded: sum)

    var out = [UInt8]()
    out.reserveCapacity(16)
    for word in [t0, t1, t2, t3] {
      out.append(UInt8(truncatingIfNeeded: word))
      out.append(UInt8(truncatingIfNeeded: word >> 8))
      out.append(UInt8(truncatingIfNeeded: word >> 16))
      out.append(UInt8(truncatingIfNeeded: word >> 24))
    }
    return out
  }

  @inline(__always)
  private static func mul(_ left: UInt32, _ right: UInt32) -> UInt64 {
    UInt64(left) &* UInt64(right)
  }

  @inline(__always)
  private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
