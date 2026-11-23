import Foundation

/// A terminal stream's binary frame: a 16-byte little-endian header, then the payload.
/// Mirrors `src/shared/terminal/stream/terminal-stream-protocol.ts` in stablyai/orca.
public struct TerminalFrame: Sendable, Equatable {
  public static let kind: UInt8 = 0x74
  public static let version: UInt8 = 1
  public static let headerLength = 16

  public enum Opcode: UInt8, Sendable {
    case output = 1
    case snapshotStart = 2
    case snapshotChunk = 3
    case snapshotEnd = 4
    case resized = 5
    case error = 6
    case metadata = 12
    case outputSpan = 15
  }

  public let opcode: UInt8
  public let streamId: UInt32
  public let sequence: UInt64
  public let payload: [UInt8]

  /// Nil for any other binary frame.
  public init?(_ bytes: [UInt8]) {
    guard bytes.count >= Self.headerLength, bytes[0] == Self.kind, bytes[1] == Self.version else {
      return nil
    }
    func u32(_ offset: Int) -> UInt32 {
      UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    opcode = bytes[2]
    streamId = u32(4)
    sequence = UInt64(u32(8)) << 32 | UInt64(u32(12))
    payload = Array(bytes[Self.headerLength...])
  }
}

/// What a terminal stream tells its screen.
public enum TerminalEvent: Sendable, Equatable {
  /// The whole screen and scrollback, as escape sequences to feed into a cleared emulator.
  case snapshot(serialized: [UInt8], meta: JSONValue)
  /// Live output bytes, in order.
  case output([UInt8])
  /// The host PTY changed size.
  case resized(meta: JSONValue)
  case metadata(JSONValue)
  /// The stream can no longer be trusted; resubscribe for a fresh snapshot.
  case failed(message: String)
}

/// Turns one stream's frames into events, reassembling the chunked snapshot.
public struct TerminalFrameDecoder: Sendable {
  public let streamId: UInt32
  private var snapshotMeta: JSONValue?
  private var snapshotBytes: [UInt8] = []

  public init(streamId: UInt32) {
    self.streamId = streamId
  }

  /// Nil for another stream's frame, or one that only adds to a snapshot in progress.
  public mutating func decode(_ frame: TerminalFrame) -> TerminalEvent? {
    guard frame.streamId == streamId else {
      return nil
    }
    switch TerminalFrame.Opcode(rawValue: frame.opcode) {
    case .output:
      return .output(frame.payload)
    case .outputSpan:
      guard let data = Self.json(frame.payload)?["data"]?.stringValue else {
        return .failed(message: "Unreadable terminal output span.")
      }
      return .output(Array(data.utf8))
    case .snapshotStart:
      snapshotMeta = Self.json(frame.payload) ?? .object([:])
      snapshotBytes = []
      return nil
    case .snapshotChunk:
      guard snapshotMeta != nil else {
        return .failed(message: "Terminal snapshot chunk without a start.")
      }
      snapshotBytes += frame.payload
      return nil
    case .snapshotEnd:
      guard let meta = snapshotMeta else {
        return .failed(message: "Terminal snapshot end without a start.")
      }
      let serialized = snapshotBytes
      snapshotMeta = nil
      snapshotBytes = []
      // A snapshot the host labels `resized` is the screen redrawn at its new size.
      return .snapshot(serialized: serialized, meta: meta)
    case .resized:
      return .resized(meta: Self.json(frame.payload) ?? .object([:]))
    case .metadata:
      return .metadata(Self.json(frame.payload) ?? .object([:]))
    case .error:
      return .failed(message: String(decoding: frame.payload, as: UTF8.self))
    case nil:
      // An opcode this build cannot read: resubscribing gets a fresh snapshot instead of a torn screen.
      return .failed(message: "Unsupported terminal stream frame (opcode \(frame.opcode)).")
    }
  }

  private static func json(_ payload: [UInt8]) -> JSONValue? {
    JSONValue.parse(String(decoding: payload, as: UTF8.self))
  }
}
