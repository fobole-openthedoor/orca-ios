import Foundation

/// One commit of `git.history`.
public struct GitHistoryItem: Sendable, Equatable, Identifiable {
  public var id: String
  public var parentIds: [String]
  /// Empty for a commit without a message.
  public var subject: String
  /// The whole message, subject included.
  public var message: String?
  public var shortId: String
  public var author: String
  /// Milliseconds since 1970; nil for an undated commit.
  public var timestamp: Double?
  public var insertions: Int
  public var deletions: Int
  /// On a branch-only page: whether origin has it. Nil when the host can't say.
  public var pushed: Bool?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let parents = json["parentIds"]?.arrayValue else { return nil }
    self.id = id
    parentIds = parents.compactMap(\.stringValue)
    subject = json["subject"]?.stringValue ?? ""
    message = json["message"]?.stringValue
    shortId = json["displayId"]?.stringValue ?? String(id.prefix(7))
    author = json["author"]?.stringValue ?? ""
    timestamp = json["timestamp"]?.doubleValue
    insertions = json["statistics"]?["insertions"]?.intValue ?? 0
    deletions = json["statistics"]?["deletions"]?.intValue ?? 0
    pushed = json["pushed"]?.boolValue
  }

  /// The message below the subject without Co-authored-by trailers, and who co-authored it
  /// (mobile-git-history.ts buildMobileCommitDetail).
  public var bodyAndCoAuthors: (body: String, coAuthors: [String]) {
    let lines = (message ?? subject).components(separatedBy: .newlines).dropFirst()
    var coAuthors: [String] = []
    let body = lines.filter { line in
      guard let match = line.range(of: "^co-authored-by:\\s*", options: [.regularExpression, .caseInsensitive]) else {
        return true
      }
      let name = line[match.upperBound...]
        .replacingOccurrences(of: "\\s*<[^>]*>\\s*$", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
      if !name.isEmpty { coAuthors.append(name) }
      return name.isEmpty
    }
    return (body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), coAuthors)
  }
}

/// A page of `git.history`. With a base, the host lists the branch's own commits and how it stands.
public struct GitHistoryPage: Sendable, Equatable {
  public struct BranchRange: Sendable, Equatable {
    public var baseRef: String
    /// `remote branches` for a base that can be rebased onto; a local base has nothing to fetch from.
    public var baseRefCategory: String?
    public var ahead: Int
    public var behind: Int
    public var unpushed: Int

    public var canUpdateFromBase: Bool { baseRefCategory == "remote branches" }
  }

  public var items: [GitHistoryItem]
  public var hasMore: Bool
  public var branch: BranchRange?
  /// The offset the host applied; nil from an older host that ignores paging and repeats page one.
  public var skip: Int?

  init(_ json: JSONValue) {
    items = (json["items"]?.arrayValue ?? []).compactMap(GitHistoryItem.init)
    hasMore = json["hasMore"]?.boolValue ?? false
    if let range = json["branch"], let base = range["baseRef"]?["name"]?.stringValue {
      branch = BranchRange(
        baseRef: base, baseRefCategory: range["baseRef"]?["category"]?.stringValue,
        ahead: range["ahead"]?.intValue ?? 0, behind: range["behind"]?.intValue ?? 0,
        unpushed: range["unpushed"]?.intValue ?? 0)
    }
    skip = json["skip"]?.intValue
  }

  /// Whether another page can be asked for: only a host that echoed `skip` pages.
  public var canPage: Bool { skip != nil && hasMore }
}

/// One file a commit changed (`git.commitCompare`).
public struct GitChangedFile: Sendable, Equatable {
  public var path: String
  public var status: String
  public var oldPath: String?
  public var added: Int?
  public var removed: Int?

  init?(_ json: JSONValue) {
    guard let path = json["path"]?.stringValue else { return nil }
    self.path = path
    status = json["status"]?.stringValue ?? "modified"
    oldPath = json["oldPath"]?.stringValue
    added = json["added"]?.intValue
    removed = json["removed"]?.intValue
  }
}

/// `git.branchCompare`'s summary: how many commits the branch has over its base.
public struct GitBranchCompareSummary: Sendable, Equatable {
  public var baseRef: String
  /// `ready`, `invalid-base`, `unborn-head`, `no-merge-base`, `loading` or `error`.
  public var status: String
  public var commitsAhead: Int?

  init?(_ json: JSONValue?) {
    guard let json, let baseRef = json["baseRef"]?.stringValue else { return nil }
    self.baseRef = baseRef
    status = json["status"]?.stringValue ?? "error"
    commitsAhead = json["commitsAhead"]?.intValue
  }
}

extension HostAPI {
  public static let historyPageSize = 50

  private func worktreeParams(_ worktreeId: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(extra.merging(["worktree": .string("id:\(worktreeId)")]) { $1 })
  }

  /// `git.history`; with a base, only the branch's commits since it (`branchOnly`), `skip` rows in.
  public func gitHistory(worktreeId: String, baseRef: String?, skip: Int = 0) async throws -> GitHistoryPage {
    var params: [String: JSONValue] = [
      "limit": .number(Double(Self.historyPageSize)), "skip": .number(Double(skip)),
    ]
    if let baseRef {
      params["baseRef"] = .string(baseRef)
      params["branchOnly"] = true
    }
    return GitHistoryPage(
      try await connection.request("git.history", worktreeParams(worktreeId, params), timeout: .seconds(60)))
  }

  /// The files one commit changed against its first parent.
  public func gitCommitFiles(worktreeId: String, commitId: String) async throws -> [GitChangedFile] {
    let reply = try await connection.request(
      "git.commitCompare", worktreeParams(worktreeId, ["commitId": .string(commitId)]), timeout: .seconds(60))
    if reply["summary"]?["status"]?.stringValue == "error" {
      throw PullRequestReplyError.refused(reply["summary"]?["errorMessage"]?.stringValue ?? "Failed to load commit files")
    }
    return (reply["entries"]?.arrayValue ?? []).compactMap(GitChangedFile.init)
  }

  public func gitBranchCompare(worktreeId: String, baseRef: String) async throws -> GitBranchCompareSummary? {
    GitBranchCompareSummary(
      try await connection.request(
        "git.branchCompare", worktreeParams(worktreeId, ["baseRef": .string(baseRef)]), timeout: .seconds(60)
      )["summary"])
  }

  /// The base PRs and rebases target (mobile-branch-base-ref.ts): the workspace's own, else the repo's
  /// pinned one, else the repo's default; nil when the repo has none.
  public func effectiveBaseRef(worktreeId: String, repoId: String) async -> String? {
    async let worktree = try? connection.request("worktree.show", ["worktree": .string("id:\(worktreeId)")])
    async let repos = try? connection.request("repo.list", [:])
    let (shown, list) = await (worktree, repos)
    if let base = shown?["worktree"]?["baseRef"]?.stringValue, !base.isEmpty { return base }
    let repo = (list?["repos"]?.arrayValue ?? []).first { $0["id"]?.stringValue == repoId }
    if let base = repo?["worktreeBaseRef"]?.stringValue, !base.isEmpty { return base }
    let fallback = try? await connection.request("repo.baseRefDefault", ["repo": .string("id:\(repoId)")])
    return fallback?["defaultBaseRef"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }
      .flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Rebases the branch onto its remote base (`git.rebaseFromBase`).
  public func gitRebaseFromBase(worktreeId: String, baseRef: String) async throws {
    _ = try await connection.request(
      "git.rebaseFromBase", worktreeParams(worktreeId, ["baseRef": .string(baseRef)]), timeout: .seconds(120))
  }

  /// `git.generateCommitMessage` from what is staged, written by the host's agent; nil when cancelled.
  public func generateCommitMessage(worktreeId: String) async throws -> String? {
    let reply = try await connection.request(
      "git.generateCommitMessage", worktreeParams(worktreeId), timeout: .seconds(300))
    if reply["success"]?.boolValue == true, let message = reply["message"]?.stringValue, !message.isEmpty {
      return message
    }
    if reply["canceled"]?.boolValue == true { return nil }
    throw PullRequestReplyError.refused(reply["error"]?.stringValue ?? "No commit message generated")
  }

  public func cancelGenerateCommitMessage(worktreeId: String) async {
    _ = try? await connection.request("git.cancelGenerateCommitMessage", worktreeParams(worktreeId))
  }
}
