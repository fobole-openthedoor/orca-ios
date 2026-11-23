import Foundation

/// One row of a workspace folder (`files.readDir`).
public struct FileDirEntry: Sendable, Equatable, Hashable {
  public var name: String
  public var isDirectory: Bool
  public var isSymlink: Bool

  public init(name: String, isDirectory: Bool, isSymlink: Bool = false) {
    self.name = name
    self.isDirectory = isDirectory
    self.isSymlink = isSymlink
  }

  init?(_ json: JSONValue) {
    guard let name = json["name"]?.stringValue, let isDirectory = json["isDirectory"]?.boolValue else { return nil }
    self.init(name: name, isDirectory: isDirectory, isSymlink: json["isSymlink"]?.boolValue ?? false)
  }

  /// Folders first, then names in natural order, as desktop sorts them (shared/file-listing/file-name-sort.ts).
  public static func precedes(_ a: FileDirEntry, _ b: FileDirEntry) -> Bool {
    if a.isDirectory != b.isDirectory { return a.isDirectory }
    return a.name.localizedStandardCompare(b.name) == .orderedAscending
  }
}

/// One page of a folder. `hasMore` pages on with the last row as the cursor.
public struct FileDirPage: Sendable, Equatable {
  public var entries: [FileDirEntry]
  public var total: Int
  public var hasMore: Bool
}

/// A whole-tree listing from hosts older than `files.readDir` (`files.list`, capped by the host).
public struct FileListing: Sendable, Equatable {
  public var paths: [String]
  public var truncated: Bool

  /// The rows directly inside `folder` ("" is the root), derived from the flat path list.
  public func entries(in folder: String) -> [FileDirEntry] {
    let prefix = folder.isEmpty ? "" : folder + "/"
    var folders = Set<String>()
    var files: [FileDirEntry] = []
    for path in paths where path.hasPrefix(prefix) {
      let rest = path.dropFirst(prefix.count)
      guard !rest.isEmpty else { continue }
      if let slash = rest.firstIndex(of: "/") {
        folders.insert(String(rest[..<slash]))
      } else {
        files.append(FileDirEntry(name: String(rest), isDirectory: false))
      }
    }
    return (folders.map { FileDirEntry(name: $0, isDirectory: true) } + files).sorted(by: FileDirEntry.precedes)
  }
}

/// `files.read` / `files.readPreview`: what a file preview shows.
public enum FilePreviewContent: Sendable, Equatable {
  case text(String, truncated: Bool, byteLength: Int?)
  case image(Data, mimeType: String)
  /// The host read it as binary, so the phone can only share it.
  case binary
}

/// `files.stat`.
public struct FileStat: Sendable, Equatable {
  public var size: Int
  public var isDirectory: Bool
  public var mtime: Double
}

extension HostAPI {
  private func fileParams(_ worktreeId: String, _ relativePath: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(extra.merging(["worktree": .string("id:\(worktreeId)"), "relativePath": .string(relativePath)]) { $1 })
  }

  /// `files.readDir`: one page of a folder ("" is the workspace root), after `after` when paging on.
  /// Hosts older than paging send the whole folder; the rows up to the cursor are dropped then.
  public func readDirectory(worktreeId: String, path: String, after: FileDirEntry? = nil, limit: Int = 500)
    async throws -> FileDirPage
  {
    var extra: [String: JSONValue] = ["limit": .number(Double(limit))]
    if let after { extra["after"] = ["name": .string(after.name), "isDirectory": .bool(after.isDirectory)] }
    let result = try await connection.request("files.readDir", fileParams(worktreeId, path, extra))
    if let rows = result.arrayValue {
      var entries = rows.compactMap(FileDirEntry.init).sorted(by: FileDirEntry.precedes)
      if let after { entries = entries.filter { FileDirEntry.precedes(after, $0) } }
      return FileDirPage(entries: entries, total: entries.count, hasMore: false)
    }
    let entries = (result["entries"]?.arrayValue ?? []).compactMap(FileDirEntry.init)
    return FileDirPage(
      entries: entries, total: result["total"]?.intValue ?? entries.count,
      hasMore: result["hasMore"]?.boolValue ?? false)
  }

  /// `files.list`, for hosts whose mobile allowlist predates `files.readDir`.
  public func listFiles(worktreeId: String) async throws -> FileListing {
    let result = try await connection.request("files.list", ["worktree": .string("id:\(worktreeId)")])
    return FileListing(
      paths: (result["files"]?.arrayValue ?? []).compactMap { $0["relativePath"]?.stringValue },
      truncated: result["truncated"]?.boolValue ?? false)
  }

  /// Reads a file for preview: images through `files.readPreview` (base64), everything else through `files.read`.
  /// A binary file comes back as `.binary`; the host's `binary_file` refusal is folded into that too.
  public func readFilePreview(worktreeId: String, path: String, asImage: Bool) async throws -> FilePreviewContent {
    if asImage {
      let result = try await connection.request("files.readPreview", fileParams(worktreeId, path))
      guard result["isImage"]?.boolValue == true, let base64 = result["content"]?.stringValue,
        let data = Data(base64Encoded: base64), !data.isEmpty
      else { return .binary }
      return .image(data, mimeType: result["mimeType"]?.stringValue ?? "image/png")
    }
    do {
      let result = try await connection.request("files.read", fileParams(worktreeId, path))
      if result["isBinary"]?.boolValue == true { return .binary }
      return .text(
        result["content"]?.stringValue ?? "", truncated: result["truncated"]?.boolValue ?? false,
        byteLength: result["byteLength"]?.intValue)
    } catch let error as RPCError where (error.message + error.code).lowercased().contains("binary_file") {
      return .binary
    }
  }

  /// An image a chat message points at, read the way the official chat reads it: files the agent session
  /// stored as attachments through `agentSessionAttachment.read`, anything else in the workspace through
  /// `files.readChatImage`. Nil when the host won't send it (too large, or a host older than either call).
  public func readChatImage(worktreeId: String, path: String) async throws -> Data? {
    let stored = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("agent-session-attachments")
    let result =
      stored
      ? try await connection.request("agentSessionAttachment.read", ["path": .string(path)])
      : try await connection.request(
        "files.readChatImage", ["worktree": .string("id:\(worktreeId)"), "path": .string(path)])
    guard result["isImage"]?.boolValue == true, let base64 = result["content"]?.stringValue,
      let data = Data(base64Encoded: base64), !data.isEmpty
    else { return nil }
    return data
  }

  public func statFile(worktreeId: String, path: String) async throws -> FileStat {
    let result = try await connection.request("files.stat", fileParams(worktreeId, path))
    return FileStat(
      size: result["size"]?.intValue ?? 0, isDirectory: result["isDirectory"]?.boolValue ?? false,
      mtime: result["mtime"]?.doubleValue ?? 0)
  }

  /// Copies a workspace file to `destination` in `files.readChunk` pieces (as the official media download does),
  /// reporting bytes read so far and the total.
  public func downloadFile(
    worktreeId: String, path: String, to destination: URL, maxBytes: Int = 256 * 1024 * 1024,
    progress: @Sendable (Int, Int) -> Void = { _, _ in }
  ) async throws {
    let stat = try await statFile(worktreeId: worktreeId, path: path)
    guard !stat.isDirectory else { throw FileDownloadError.notAFile }
    guard stat.size <= maxBytes else { throw FileDownloadError.tooLarge }
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    let chunk = 384 * 1024
    var offset = 0
    while offset < stat.size {
      try Task.checkCancellation()
      let length = min(chunk, stat.size - offset)
      let result = try await connection.request(
        "files.readChunk",
        fileParams(worktreeId, path, ["offset": .number(Double(offset)), "length": .number(Double(length))]),
        timeout: .seconds(30))
      guard let base64 = result["contentBase64"]?.stringValue, let data = Data(base64Encoded: base64),
        !data.isEmpty, data.count <= length
      else { throw FileDownloadError.changed }
      try handle.write(contentsOf: data)
      offset += data.count
      progress(offset, stat.size)
      if result["eof"]?.boolValue == true, offset != stat.size { throw FileDownloadError.changed }
    }
  }
}

public enum FileDownloadError: Error, Sendable {
  case notAFile
  case tooLarge
  /// The file changed while it was being read.
  case changed
}
