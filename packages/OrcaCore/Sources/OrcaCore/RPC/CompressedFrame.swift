import Foundation
import zlib

/// A text or binary frame the host gzipped and sealed as one binary frame: a 6-byte header
/// (kind, inflated payload kind, little-endian inflated length) and one gzip member.
/// Mirrors `paired-e2ee-compressed-frame.ts` in stablyai/orca.
enum CompressedFrame {
  /// A host only compresses for a socket that advertised this.
  static let clientCapability = "transport.compressed-frames.v1"

  static let kind: UInt8 = 0x7a
  static let headerLength = 6
  static let maxTextBytes = 4 * 1024 * 1024
  static let maxBinaryBytes = 8 * 1024 * 1024

  enum Inflated: Equatable {
    case text(String)
    case binary([UInt8])
  }

  enum Failure: Error {
    case oversized
    case corrupt
  }

  /// Nil for any other binary frame, which callers pass through unchanged. Throws on a corrupt one.
  static func inflate(_ frame: [UInt8]) throws -> Inflated? {
    guard frame.count >= headerLength, frame[0] == kind, frame[1] == 1 || frame[1] == 2 else {
      return nil
    }
    let isText = frame[1] == 1
    let length = Int(frame[2]) | Int(frame[3]) << 8 | Int(frame[4]) << 16 | Int(frame[5]) << 24
    // The host never sends a frame above its outbound cap, so a larger claim is a corrupt frame.
    guard length <= (isText ? maxTextBytes : maxBinaryBytes) else {
      throw Failure.oversized
    }
    let bytes = try gunzip(frame[headerLength...], expectedLength: length)
    return isText ? .text(String(decoding: bytes, as: UTF8.self)) : .binary(bytes)
  }

  private static func gunzip(_ gzipped: ArraySlice<UInt8>, expectedLength: Int) throws -> [UInt8] {
    var stream = z_stream()
    // 16 + MAX_WBITS selects the gzip wrapper.
    guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw Failure.corrupt
    }
    defer {
      inflateEnd(&stream)
    }
    // One byte past the claim lets a member that inflates larger fail the length check, not overrun.
    var output = [UInt8](repeating: 0, count: expectedLength + 1)
    var input = Array(gzipped)
    let status = input.withUnsafeMutableBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        stream.next_in = inputBuffer.baseAddress
        stream.avail_in = uInt(inputBuffer.count)
        stream.next_out = outputBuffer.baseAddress
        stream.avail_out = uInt(outputBuffer.count)
        return zlib.inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, Int(stream.total_out) == expectedLength else {
      throw Failure.corrupt
    }
    output.removeLast()
    return output
  }
}
