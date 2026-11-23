import Foundation
import Testing

@testable import OrcaCore

@Suite struct CompressedFrameTests {
  // Frames built with Python's gzip: a 3 KB JSON reply and 2 KB of binary.
  static let textFrame = "7a01dc0b00001f8b08000000000002ffab56ca4c51b2522a2a48d63554d251cacf56b22a292a4dd5512a4a2d2ecd29014a558c8251300a46c1281805a360148c8251300a063d50aa050005a2be6cdc0b0000"
  static let binaryFrame = "7a02000800001f8b08000000000002ff6360646266616563e7e0e4e2e6e1e5e3171014121611151397909492969195935750545256515553d7d0d4d2d6d1d5d33730343236313533b7b0b4b2b6b1b5b37770747276717573f7f0f4f2f6f1f5f30f080c0a0e090d0b8f888c8a8e898d8b4f484c4a4e494d4bcfc8cccacec9cdcb2f282c2a2e292d2bafa8acaaaea9adab6f686c6a6e696d6befe8eceaeee9edeb9f3071d2e42953a74d9f3173d6ec3973e7cd5fb070d1e2254b972d5fb172d5ea356bd7addfb071d3e62d5bb76ddfb173d7ee3d7bf7ed3f70f0d0e123478f1d3f71f2d4e93367cf9dbf70f1d2e52b57af5dbf71f3d6ed3b77efdd7ff0f0d1e3274f9f3d7ff1f2d5eb376fdfbdfff0f1d3e72f5fbf7dfff1f3d7ef3f7ffffd6718f5ffa8ff47fd3feaff51ff8ffa7f04fa1f0058dd5e9f00080000"

  @Test func inflatesTextAndBinaryFrames() throws {
    guard case .text(let text) = try CompressedFrame.inflate(unhex(Self.textFrame)) else {
      Issue.record("expected text")
      return
    }
    #expect(text == #"{"id":"rpc-1","ok":true,"result":""# + String(repeating: "x", count: 3000) + #""}"#)

    let expected = (0..<8).flatMap { _ in (0...255).map { UInt8($0) } }
    #expect(try CompressedFrame.inflate(unhex(Self.binaryFrame)) == .binary(expected))
  }

  @Test func passesOtherFramesThroughAndRefusesCorruptOnes() throws {
    // 0x74 is a terminal frame.
    #expect(try CompressedFrame.inflate([0x74, 1, 0, 0, 0, 0, 9, 9]) == nil)
    #expect(try CompressedFrame.inflate([0x7a, 1]) == nil)

    var wrongLength = unhex(Self.binaryFrame)
    wrongLength[2] ^= 1
    #expect(throws: CompressedFrame.Failure.corrupt) { try CompressedFrame.inflate(wrongLength) }

    var truncated = unhex(Self.binaryFrame)
    truncated.removeLast(4)
    #expect(throws: CompressedFrame.Failure.corrupt) { try CompressedFrame.inflate(truncated) }

    #expect(throws: CompressedFrame.Failure.oversized) {
      try CompressedFrame.inflate([0x7a, 1, 0xff, 0xff, 0xff, 0x7f, 0, 0])
    }
  }
}
