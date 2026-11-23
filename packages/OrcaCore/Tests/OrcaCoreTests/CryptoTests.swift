import Foundation
import Testing

@testable import OrcaCore

func hex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

func unhex(_ string: String) -> [UInt8] {
  var bytes = [UInt8]()
  var index = string.startIndex
  while index < string.endIndex {
    let next = string.index(index, offsetBy: 2)
    bytes.append(UInt8(string[index..<next], radix: 16)!)
    index = next
  }
  return bytes
}

@Suite struct NaClTests {
  // Reference boxes from libsodium (PyNaCl), key 00…1f, nonce 64…7b, message[i] = i*7+3.
  static let key = (0..<32).map { UInt8($0) }
  static let nonce = (100..<124).map { UInt8($0) }
  static let boxes: [Int: String] = [
    0: "f49572d6194281e3c87fbb4e2106932c",
    1: "5c7befd74364db52540bb64387ced80801",
    15: "8650d974f4e323ac9ad298879e840e4901b388d12590e3dd8bbf6ac460dac6",
    16: "f6e3776e5e01fea8e7639042aae2370601b388d12590e3dd8bbf6ac460dac674",
    17: "4895d901f6e2ba5d8190cba05ee3ee7001b388d12590e3dd8bbf6ac460dac6744d",
    63: "704a154588c50774536379f686c0f72101b388d12590e3dd8bbf6ac460dac6744dd0b92f6b30d6bf0dbefb54cd451c544b8505e0b03196f0ee343e52372d982992cacf707df044db8873caa47c1c2b",
    64: "1b9eadc717c0630430bb48a27b48858001b388d12590e3dd8bbf6ac460dac6744dd0b92f6b30d6bf0dbefb54cd451c544b8505e0b03196f0ee343e52372d982992cacf707df044db8873caa47c1c2bd8",
    65: "a2a66489445243db467dee0a4938c9fa01b388d12590e3dd8bbf6ac460dac6744dd0b92f6b30d6bf0dbefb54cd451c544b8505e0b03196f0ee343e52372d982992cacf707df044db8873caa47c1c2bd880",
    200: "bbad21955f5496feee0cfa1413356f3401b388d12590e3dd8bbf6ac460dac6744dd0b92f6b30d6bf0dbefb54cd451c544b8505e0b03196f0ee343e52372d982992cacf707df044db8873caa47c1c2bd880419db517daa57e428d16e257ddc8bf67adcc4fe8a92666f9e9f0a7ff68705a596358c3501ff713d899967b4ba290346b35b762f81d7d4d0bde57c3837fa3403d8a9c80a868b0bdf6e1e2e80a1705b990d1f71722316f38803b9e3221769cace2155a50a2575ef309424a96ee06272b2f7817f51617da1e4e6935a363772b7cf327d31590c841a0",
  ]

  static func message(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
  }

  @Test func secretboxMatchesLibsodium() {
    for (count, expected) in Self.boxes {
      let box = NaCl.secretbox(message: Self.message(count), nonce: Self.nonce, key: Self.key)
      #expect(hex(box) == expected, "length \(count)")
    }
  }

  @Test func secretboxOpenRoundTripsAndRejectsTampering() {
    for (count, expected) in Self.boxes {
      let box = unhex(expected)
      #expect(NaCl.secretboxOpen(box: box[...], nonce: Self.nonce, key: Self.key) == Self.message(count))
      for position in [0, box.count - 1] {
        var tampered = box
        tampered[position] ^= 1
        #expect(NaCl.secretboxOpen(box: tampered[...], nonce: Self.nonce, key: Self.key) == nil)
      }
    }
    #expect(NaCl.secretboxOpen(box: [1, 2, 3], nonce: Self.nonce, key: Self.key) == nil)
  }

  @Test func poly1305MatchesRFC8439() {
    let key = unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
    let tag = Poly1305.tag(message: Array("Cryptographic Forum Research Group".utf8)[...], key: key[...])
    #expect(hex(tag) == "a8061dc1305136c6c22b8baf0c0127a9")
  }

  @Test func boxBeforeNMMatchesTheNaClPaper() {
    let aliceSecret = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    let bobPublic = unhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    let shared = NaCl.boxBeforeNM(secretKey: aliceSecret, peerPublicKey: bobPublic)
    #expect(shared.map(hex) == "1b27556473e985d462cd51197a9a46c76009549eac6474f206c4ee0844f68389")
  }

  @Test func boxBeforeNMIsSymmetric() {
    let phone = NaCl.generateKeyPair()
    let desktop = NaCl.generateKeyPair()
    let left = NaCl.boxBeforeNM(secretKey: phone.secretKey, peerPublicKey: desktop.publicKey)
    let right = NaCl.boxBeforeNM(secretKey: desktop.secretKey, peerPublicKey: phone.publicKey)
    #expect(left != nil && left == right)
  }
}
