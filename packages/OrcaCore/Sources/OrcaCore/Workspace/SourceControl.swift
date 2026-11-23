import Foundation

/// One changed file in `git.status` (source-control/git/git-status-reply-schema.ts).
public struct GitStatusEntry: Sendable, Equatable, Hashable {
  /// `staged`, `unstaged` or `untracked`; a row whose area this build doesn't know is dropped.
  public enum Area: String, Sendable {
    case staged, unstaged, untracked
  }

  public var path: String
  /// `modified`, `added`, `deleted`, `renamed`, `untracked`, `copied`; unknown values read as `modified`.
  public var status: String
  public var area: Area
  public var oldPath: String?
  /// `both_modified`, `added_by_us` …
  public var conflictKind: String?
  /// `unresolved` or `resolved_locally`.
  public var conflictStatus: String?
  public var submoduleRoot: String?
  public var added: Int?
  public var removed: Int?

  init?(_ json: JSONValue) {
    guard let path = json["path"]?.stringValue, !path.isEmpty,
      let area = json["area"]?.stringValue.flatMap(Area.init(rawValue:))
    else { return nil }
    self.path = path
    self.area = area
    let status = json["status"]?.stringValue ?? "modified"
    self.status =
      ["modified", "added", "deleted", "renamed", "untracked", "copied"].contains(status) ? status : "modified"
    oldPath = json["oldPath"]?.stringValue
    conflictKind = json["conflictKind"]?.stringValue
    conflictStatus = json["conflictStatus"]?.stringValue
    submoduleRoot = json["submoduleRoot"]?.stringValue
    added = json["added"]?.intValue
    removed = json["removed"]?.intValue
  }

  /// Pinned to the Conflicts section, as desktop pins them.
  public var isConflict: Bool { conflictStatus == "unresolved" || conflictStatus == "resolved_locally" }
  public var canStage: Bool { area != .staged && submoduleRoot == nil }
  public var canUnstage: Bool { area == .staged && submoduleRoot == nil }
  public var canDiscard: Bool { !isConflict && submoduleRoot == nil && area != .staged }
  /// Unresolved conflicts cannot open as stable files.
  public var canOpen: Bool { conflictStatus != "unresolved" }
}

/// `upstreamStatus` in `git.status`.
public struct GitUpstreamStatus: Sendable, Equatable {
  public var hasUpstream: Bool
  public var ahead: Int
  public var behind: Int
  public var upstreamName: String?

  init?(_ json: JSONValue?) {
    guard let json, let hasUpstream = json["hasUpstream"]?.boolValue else { return nil }
    self.hasUpstream = hasUpstream
    ahead = json["ahead"]?.intValue ?? 0
    behind = json["behind"]?.intValue ?? 0
    upstreamName = json["upstreamName"]?.stringValue
  }
}

/// `git.status` for one worktree.
public struct GitStatus: Sendable, Equatable {
  public var entries: [GitStatusEntry]
  /// The checked-out branch without `refs/heads/`; nil on a detached HEAD.
  public var branch: String?
  public var head: String?
  public var upstream: GitUpstreamStatus?
  /// `merge`, `rebase`, `cherry-pick`, `unknown`, or nil when none is in progress.
  public var conflictOperation: String?
  /// The host's own failure reading status, sent with whatever entries it got.
  public var readError: String?

  init(_ json: JSONValue) {
    entries = (json["entries"]?.arrayValue ?? []).compactMap(GitStatusEntry.init)
    let branch = json["branch"]?.stringValue
    self.branch = branch.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
      .flatMap { $0.isEmpty ? nil : $0 }
    head = json["head"]?.stringValue
    upstream = GitUpstreamStatus(json["upstreamStatus"])
    let operation = json["conflictOperation"]?.stringValue
    conflictOperation = operation == nil || operation == "none" ? nil : operation
    readError = json["readError"]?.stringValue
  }
}

/// `git.diff` for one file: both sides, or why there is no text to show.
public enum GitFileDiff: Sendable, Equatable {
  case text(original: String, modified: String)
  case binary
  case tooLarge
}

/// `git.commit`: the host can accept the call and still fail the commit (a hook, nothing staged).
public struct GitCommitOutcome: Sendable, Equatable {
  public var success: Bool
  public var error: String?
}

extension HostAPI {
  private func gitParams(_ worktreeId: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(extra.merging(["worktree": .string("id:\(worktreeId)")]) { $1 })
  }

  /// `git.status` with per-file line counts.
  public func gitStatus(worktreeId: String) async throws -> GitStatus {
    GitStatus(try await connection.request("git.status", gitParams(worktreeId)))
  }

  /// `git.diff`: the staged side compares HEAD with the index, otherwise the index with the working tree.
  public func gitDiff(worktreeId: String, entry: GitStatusEntry) async throws -> GitFileDiff {
    let staged = entry.area == .staged
    var params: [String: JSONValue] = ["filePath": .string(entry.path), "staged": .bool(staged)]
    if staged, let oldPath = entry.oldPath { params["oldPath"] = .string(oldPath) }
    let result = try await connection.request("git.diff", gitParams(worktreeId, params))
    switch result["kind"]?.stringValue {
    case "text":
      return .text(
        original: result["originalContent"]?.stringValue ?? "", modified: result["modifiedContent"]?.stringValue ?? "")
    case "too-large":
      return .tooLarge
    default:
      return result["tooLarge"]?.boolValue == true ? .tooLarge : .binary
    }
  }

  public func gitStage(worktreeId: String, path: String) async throws {
    _ = try await connection.request("git.stage", gitParams(worktreeId, ["filePath": .string(path)]))
  }

  public func gitUnstage(worktreeId: String, path: String) async throws {
    _ = try await connection.request("git.unstage", gitParams(worktreeId, ["filePath": .string(path)]))
  }

  public func gitStage(worktreeId: String, paths: [String]) async throws {
    _ = try await connection.request(
      "git.bulkStage", gitParams(worktreeId, ["filePaths": .array(paths.map(JSONValue.string))]))
  }

  public func gitUnstage(worktreeId: String, paths: [String]) async throws {
    _ = try await connection.request(
      "git.bulkUnstage", gitParams(worktreeId, ["filePaths": .array(paths.map(JSONValue.string))]))
  }

  /// `git.discard`: throws away the file's working-tree changes (deletes it when untracked).
  public func gitDiscard(worktreeId: String, path: String) async throws {
    _ = try await connection.request("git.discard", gitParams(worktreeId, ["filePath": .string(path)]))
  }

  /// `git.commit` of what is staged.
  public func gitCommit(worktreeId: String, message: String) async throws -> GitCommitOutcome {
    let result = try await connection.request(
      "git.commit", gitParams(worktreeId, ["message": .string(message)]), timeout: .seconds(120))
    // A missing or null outcome is a failed commit, as the official client reads it.
    return GitCommitOutcome(
      success: result["success"]?.boolValue ?? false,
      error: result["error"]?.stringValue ?? result["error"]?["message"]?.stringValue)
  }

  /// `git.push`; `publish` pushes a branch that has no upstream yet and sets one.
  public func gitPush(worktreeId: String, publish: Bool = false) async throws {
    _ = try await connection.request(
      "git.push", gitParams(worktreeId, publish ? ["publish": true] : [:]), timeout: .seconds(120))
  }

  public func gitPull(worktreeId: String) async throws {
    _ = try await connection.request("git.pull", gitParams(worktreeId), timeout: .seconds(120))
  }

  public func gitFetch(worktreeId: String) async throws {
    _ = try await connection.request("git.fetch", gitParams(worktreeId), timeout: .seconds(120))
  }
}
