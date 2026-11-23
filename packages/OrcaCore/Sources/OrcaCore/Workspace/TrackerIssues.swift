import Foundation

/// A Linear or Jira issue as their task lists read it: enough for a row and a link.
public struct TrackerIssue: Sendable, Equatable, Identifiable {
  public var id: String
  /// `ENG-123` or `ABC-45`.
  public var identifier: String
  public var title: String
  public var url: String
  /// The workflow state's name.
  public var state: String?
  /// The Linear team key or the Jira project key.
  public var group: String?
  /// ISO 8601.
  public var updatedAt: String?

  init?(linear json: JSONValue) {
    guard let id = json["id"]?.stringValue, let identifier = json["identifier"]?.stringValue,
      let title = json["title"]?.stringValue
    else { return nil }
    self.id = id
    self.identifier = identifier
    self.title = title
    url = json["url"]?.stringValue ?? ""
    state = json["state"]?["name"]?.stringValue
    group = json["team"]?["key"]?.stringValue
    updatedAt = json["updatedAt"]?.stringValue
  }

  init?(jira json: JSONValue) {
    guard let key = json["key"]?.stringValue, let title = json["title"]?.stringValue else { return nil }
    id = json["id"]?.stringValue ?? key
    identifier = key
    self.title = title
    url = json["url"]?.stringValue ?? ""
    state = json["status"]?["name"]?.stringValue
    group = json["project"]?["key"]?.stringValue
    updatedAt = json["updatedAt"]?.stringValue
  }

  /// A list reply: a bare array, or one wrapped in `items` or `issues`.
  static func rows(_ reply: JSONValue) -> [JSONValue] {
    reply.arrayValue ?? reply["items"]?.arrayValue ?? reply["issues"]?.arrayValue ?? []
  }
}

extension HostAPI {
  /// Whether this desktop has a Linear account connected (`linear.status`).
  public func linearConnected() async throws -> Bool {
    try await connection.request("linear.status", [:])["connected"]?.boolValue ?? false
  }

  /// Connects a Linear account with a personal API key (`linear.connect`); throws the host's reason when refused.
  public func connectLinear(apiKey: String) async throws {
    let reply = try await connection.request("linear.connect", ["apiKey": .string(apiKey)])
    if reply["ok"]?.boolValue == false {
      throw RPCError(
        code: "linear_connect_failed", message: reply["error"]?.stringValue ?? "Failed to connect Linear", data: nil)
    }
  }

  /// Linear issues for one of the official filters (`all`, `assigned`, `created`, `completed`), or matching a search.
  public func linearIssues(filter: String, query: String = "", limit: Int = 50) async throws -> [TrackerIssue] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let reply =
      trimmed.isEmpty
      ? try await connection.request("linear.listIssues", ["filter": .string(filter), "limit": .number(Double(limit))])
      : try await connection.request(
        "linear.searchIssues", ["query": .string(trimmed), "limit": .number(Double(limit))])
    return TrackerIssue.rows(reply).compactMap(TrackerIssue.init(linear:))
  }

  /// Files a GitHub issue in a project (`github.createIssue`) and returns its number; throws the host's reason when
  /// refused.
  @discardableResult
  public func createGitHubIssue(repoId: String, title: String, body: String) async throws -> Int? {
    let reply = try await connection.request(
      "github.createIssue", ["repo": .string("id:\(repoId)"), "title": .string(title), "body": .string(body)])
    if reply["ok"]?.boolValue == false {
      throw RPCError(
        code: "github_create_issue_failed", message: reply["error"]?.stringValue ?? "Failed to create GitHub issue",
        data: nil)
    }
    return reply["number"]?.intValue
  }

  /// Whether this desktop has Jira connected (`jira.status`).
  public func jiraConnected() async throws -> Bool {
    try await connection.request("jira.status", [:])["connected"]?.boolValue ?? false
  }

  /// Jira issues for one of the official filters (`assigned`, `reported`, `all`, `done`), or matching a JQL search.
  public func jiraIssues(filter: String, query: String = "", limit: Int = 50) async throws -> [TrackerIssue] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let reply =
      trimmed.isEmpty
      ? try await connection.request("jira.listIssues", ["filter": .string(filter), "limit": .number(Double(limit))])
      : try await connection.request("jira.searchIssues", ["jql": .string(trimmed), "limit": .number(Double(limit))])
    return TrackerIssue.rows(reply).compactMap(TrackerIssue.init(jira:))
  }
}
