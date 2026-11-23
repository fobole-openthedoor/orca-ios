import Foundation

/// A project the Tasks screen can read work items from: a `repo.list` row that is a git repository, not a folder.
public struct TaskRepo: Sendable, Equatable, Identifiable {
  public var id: String
  public var displayName: String
  /// The same project on another host (an SSH twin) shares this key, so one read covers both.
  public var projectKey: String
  /// The SSH connection of a remote project; nil for a local one.
  public var connectionId: String?
  public var addedAt: Double

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let displayName = json["displayName"]?.stringValue,
      json["kind"]?.stringValue != "folder"
    else { return nil }
    self.id = id
    self.displayName = displayName
    connectionId = json["connectionId"]?.stringValue
    addedAt = json["addedAt"]?.doubleValue ?? 0
    projectKey = json["gitRemoteIdentity"]?["canonicalKey"]?.stringValue.map { "remote:\($0)" } ?? "repo:\(id)"
  }
}

/// A GitHub issue or pull request as `github.listWorkItems` lists it.
public struct GitHubWorkItem: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable { case issue, pr }

  public var id: String
  public var kind: Kind
  public var number: Int
  public var title: String
  /// `open`, `closed`, `merged` or `draft`.
  public var state: String
  public var url: String
  /// ISO 8601.
  public var updatedAt: String?
  public var labels: [String]
  public var author: String?
  public var repoId: String
  public var repoName: String

  init?(_ json: JSONValue, repo: TaskRepo) {
    guard let number = json["number"]?.intValue, let title = json["title"]?.stringValue else { return nil }
    kind = json["type"]?.stringValue == "pr" ? .pr : .issue
    self.number = number
    self.title = title
    id = json["id"]?.stringValue ?? "\(repo.id):\(kind.rawValue):\(number)"
    state = json["state"]?.stringValue ?? "open"
    url = json["url"]?.stringValue ?? ""
    updatedAt = json["updatedAt"]?.stringValue
    labels = (json["labels"]?.arrayValue ?? []).compactMap(\.stringValue)
    author = json["author"]?.stringValue
    repoId = repo.id
    repoName = repo.displayName
  }

  public var updatedDate: Date? {
    guard let updatedAt else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: updatedAt) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: updatedAt)
  }
}

/// One work item's page, from `github.workItemDetails`.
public struct GitHubWorkItemDetails: Sendable, Equatable {
  public struct Comment: Sendable, Equatable, Identifiable {
    public var id: String
    public var author: String
    public var body: String
    /// ISO 8601.
    public var createdAt: String?
    public var isBot: Bool
  }

  public var body: String
  public var labels: [String]
  public var assignees: [String]
  public var comments: [Comment]
  public var reviewDecision: String?
}

/// The work-item lists the official Tasks screen offers for GitHub, with the search each sends.
public enum GitHubTaskPreset: String, Sendable, CaseIterable {
  case issues
  case myIssues = "my-issues"
  case prs
  case myPRs = "my-prs"
  case review

  public var query: String {
    switch self {
    case .issues: "is:issue is:open"
    case .myIssues: "assignee:@me is:issue is:open"
    case .prs: "is:pr is:open"
    case .myPRs: "author:@me is:pr is:open"
    case .review: "review-requested:@me is:pr is:open"
    }
  }

  public var isPullRequests: Bool { self == .prs || self == .myPRs || self == .review }

  /// The search sent for typed text: kept as written when it names its own scope, else scoped to this kind.
  public func scoped(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return query }
    let lowered = trimmed.lowercased()
    if lowered.contains("is:issue") || lowered.contains("is:pr") || lowered.contains("type:issue")
      || lowered.contains("type:pr")
    {
      return trimmed
    }
    return "\(isPullRequests ? "is:pr" : "is:issue") \(trimmed)"
  }
}

extension HostAPI {
  /// The projects Tasks reads, one per project: a local checkout is preferred over its SSH twin.
  public func taskRepos() async throws -> [TaskRepo] {
    let reply = try await connection.request("repo.list", [:])
    var byProject: [String: TaskRepo] = [:]
    var order: [String] = []
    for repo in (reply["repos"]?.arrayValue ?? []).compactMap(TaskRepo.init) {
      guard let current = byProject[repo.projectKey] else {
        byProject[repo.projectKey] = repo
        order.append(repo.projectKey)
        continue
      }
      let local = repo.connectionId == nil, currentLocal = current.connectionId == nil
      if (local && !currentLocal) || (local == currentLocal && repo.addedAt < current.addedAt) {
        byProject[repo.projectKey] = repo
      }
    }
    return order.compactMap { byProject[$0] }
  }

  /// One repository's issues or pull requests matching a GitHub search (`github.listWorkItems`). `page` starts at 1.
  public func githubWorkItems(in repo: TaskRepo, query: String, limit: Int, page: Int = 1) async throws
    -> [GitHubWorkItem]
  {
    let reply = try await connection.request(
      "github.listWorkItems",
      [
        "repo": .string("id:\(repo.id)"), "limit": .number(Double(limit)), "query": .string(query),
        "page": .number(Double(page)),
      ])
    return (reply["items"]?.arrayValue ?? []).compactMap { GitHubWorkItem($0, repo: repo) }
  }

  /// The body, labels, assignees and discussion of one issue or pull request (`github.workItemDetails`).
  public func githubWorkItemDetails(_ item: GitHubWorkItem) async throws -> GitHubWorkItemDetails? {
    let reply = try await connection.request(
      "github.workItemDetails",
      [
        "repo": .string("id:\(item.repoId)"), "number": .number(Double(item.number)),
        "type": .string(item.kind.rawValue),
      ])
    guard case .object = reply else { return nil }
    let comments = (reply["comments"]?.arrayValue ?? []).compactMap { json -> GitHubWorkItemDetails.Comment? in
      guard let body = json["body"]?.stringValue else { return nil }
      let id = json["id"]?.stringValue ?? json["id"]?.doubleValue.map { String(Int($0)) } ?? UUID().uuidString
      return GitHubWorkItemDetails.Comment(
        id: id, author: json["author"]?.stringValue ?? "", body: body, createdAt: json["createdAt"]?.stringValue,
        isBot: json["isBot"]?.boolValue ?? false)
    }
    return GitHubWorkItemDetails(
      body: reply["body"]?.stringValue ?? "",
      labels: (reply["item"]?["labels"]?.arrayValue ?? []).compactMap(\.stringValue),
      assignees: (reply["assignees"]?.arrayValue ?? []).compactMap(\.stringValue),
      comments: comments,
      reviewDecision: reply["item"]?["reviewDecision"]?.stringValue)
  }

  /// Makes a workspace for an issue or pull request in its repository, linked to it as the desktop links one,
  /// and returns the new workspace's id.
  public func createWorktree(for item: GitHubWorkItem, name: String, displayName: String) async throws -> String? {
    var params: [String: JSONValue] = [
      "repo": .string("id:\(item.repoId)"), "name": .string(name), "displayName": .string(displayName),
      "displayNameKind": "user", "activate": .bool(true),
    ]
    params[item.kind == .pr ? "linkedPR" : "linkedIssue"] = .number(Double(item.number))
    let result = try await connection.request("worktree.create", .object(params), timeout: .seconds(60))
    return result["worktree"]?["id"]?.stringValue
  }
}
