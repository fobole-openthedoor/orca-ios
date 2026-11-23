import Foundation

/// Something the composer holds until send: an image goes into the message as a block, a file as an
/// `@path` reference in its text. The two upload through different host methods.
public struct OutgoingAttachment: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case image
    case file
  }

  public let id: UUID
  public var kind: Kind
  public var name: String
  public var data: Data

  public init(id: UUID = UUID(), kind: Kind, name: String, data: Data) {
    self.id = id
    self.kind = kind
    self.name = name
    self.data = data
  }
}

public enum AttachmentError: Error, Equatable {
  case tooLarge
  case tooMany
  case unsupportedByHost
  case uploadRefused
}

public enum AttachmentLimits {
  public static let maxImagesPerMessage = 20
  /// 24 MiB of base64 characters.
  public static let maxImageBase64Characters = 24 * 1024 * 1024
  public static let maxFileBytes = 50 * 1024 * 1024
  /// 512 KiB of base64 characters, a multiple of four so every chunk decodes on its own.
  static let chunkCharacters = 512 * 1024
}

extension HostAPI {
  /// Uploads an image and returns its host path, for an `image-ref` block.
  /// `connectionId` is the SSH connection of the workspace's project, nil for a local one.
  public func uploadImage(_ data: Data, fileName: String?, connectionId: String?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
    let base64 = data.base64EncodedString()
    guard base64.count <= AttachmentLimits.maxImageBase64Characters else {
      throw AttachmentError.tooLarge
    }
    var start: [String: JSONValue] = [
      "expectedBase64Length": .number(Double(base64.count)),
      "connectionId": connectionId.map(JSONValue.string) ?? .null,
    ]
    if let fileName {
      start["fileName"] = .string(fileName)
    }
    guard let uploadId = try await connection.request("clipboard.startImageUpload", .object(start))["uploadId"]?.stringValue else {
      throw AttachmentError.uploadRefused
    }
    do {
      // Offsets here count base64 characters.
      try await sendChunks(base64, progress: progress) { offset, chunk in
        _ = try await connection.request(
          "clipboard.appendImageUploadChunk",
          ["uploadId": .string(uploadId), "offset": .number(Double(offset)), "contentBase64": .string(chunk)])
      }
      guard let path = try await connection.request("clipboard.commitImageUpload", ["uploadId": .string(uploadId)]).stringValue else {
        throw AttachmentError.uploadRefused
      }
      return path
    } catch {
      await connection.notify("clipboard.abortImageUpload", ["uploadId": .string(uploadId)])
      throw error
    }
  }

  /// Uploads a file into the chat's attachment store and returns its host path, for an `@path` reference.
  public func uploadFile(_ data: Data, name: String, sessionId: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
    guard data.count <= AttachmentLimits.maxFileBytes else {
      throw AttachmentError.tooLarge
    }
    let start: JSONValue = [
      "sessionId": .string(sessionId), "name": .string(String(name.prefix(1024))), "byteLength": .number(Double(data.count)),
    ]
    guard let uploadId = try await connection.request("agentSessionAttachment.uploadStart", start)["uploadId"]?.stringValue else {
      throw AttachmentError.uploadRefused
    }
    do {
      // Offsets here count decoded bytes, and even an empty file needs one append.
      try await sendChunks(data.base64EncodedString(), progress: progress) { offset, chunk in
        _ = try await connection.request(
          "agentSessionAttachment.uploadAppend",
          ["uploadId": .string(uploadId), "offset": .number(Double(offset / 4 * 3)), "contentBase64": .string(chunk)])
      }
      guard let path = try await connection.request("agentSessionAttachment.uploadCommit", ["uploadId": .string(uploadId)])["path"]?.stringValue else {
        throw AttachmentError.uploadRefused
      }
      return path
    } catch {
      await connection.notify("agentSessionAttachment.uploadAbort", ["uploadId": .string(uploadId)])
      throw error
    }
  }

  private func sendChunks(_ base64: String, progress: (@Sendable (Double) -> Void)?, send: (_ characterOffset: Int, _ chunk: String) async throws -> Void) async throws {
    let characters = Array(base64.utf8)
    var offset = 0
    repeat {
      let end = min(offset + AttachmentLimits.chunkCharacters, characters.count)
      try await send(offset, String(decoding: characters[offset..<end], as: UTF8.self))
      offset = end
      progress?(characters.isEmpty ? 1 : Double(offset) / Double(characters.count))
    } while offset < characters.count
  }
}

/// Builds what a send carries.
public enum ChatMessageBody {
  /// A file reference as agents read it: bare when it can be, quoted when the path needs it.
  public static func fileReference(_ path: String) -> String {
    if !path.contains(where: { $0.isWhitespace || $0 == "@" }) {
      return "@\(path)"
    }
    if !path.contains("\"") {
      return "@\"\(path)\""
    }
    if !path.contains("'") {
      return "@'\(path)'"
    }
    return "@\"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""
  }

  /// The user's text with file references on a new line after it.
  public static func text(_ text: String, filePaths: [String]) -> String {
    let trimmed = String(text.reversed().drop(while: \.isWhitespace).reversed())
    let references = filePaths.map(fileReference).joined(separator: " ")
    if references.isEmpty {
      return trimmed
    }
    return trimmed.allSatisfy(\.isWhitespace) ? references : trimmed + "\n" + references
  }

  /// The `body` field of `agentSession.send`: text first, then one block per image. Nil when there is nothing to send.
  public static func send(text: String, filePaths: [String], imagePaths: [String]) -> JSONValue? {
    let text = Self.text(text, filePaths: filePaths)
    var blocks: [JSONValue] = []
    if !text.allSatisfy(\.isWhitespace) {
      blocks.append(["type": "text", "text": .string(text)])
    }
    blocks += imagePaths.map { ["type": "image-ref", "path": .string($0)] }
    guard !blocks.isEmpty else {
      return nil
    }
    return ["kind": "message", "role": "user", "blocks": .array(blocks)]
  }
}
