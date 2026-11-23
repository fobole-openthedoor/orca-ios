import Foundation

/// A Linear or Jira issue as their task lists read it: a row, its grouping keys, and a link.
public struct TrackerIssue: Sendable, Equatable, Identifiable {
  public enum Provider: String, Sendable { case linear, jira }

  public var provider: Provider
  public var id: String
  /// `ENG-123` or `ABC-45`.
  public var identifier: String
  public var title: String
  public var url: String
  /// The workflow state's name.
  public var state: String?
  /// Linear's state type (`started`, `completed`…) or Jira's status category key (`new`, `indeterminate`, `done`).
  public var stateType: String?
  /// Linear's state colour, `#rrggbb`.
  public var stateColor: String?
  /// The Linear team key or the Jira project key.
  public var group: String?
  /// The Linear team id and name; the Jira project name.
  public var teamId: String?
  public var teamName: String?
  /// ISO 8601.
  public var updatedAt: String?
  /// Linear's 0 (none) to 4 (low).
  public var priority: Int
  /// Jira's priority name.
  public var priorityName: String?
  public var assignee: String?
  public var assigneeId: String?
  public var labels: [String]
  public var description: String?
  /// The Linear workspace or the Jira site the issue came from.
  public var workspaceId: String?
  public var workspaceName: String?
  /// Linear's project; Jira's issue type.
  public var projectName: String?
  public var typeName: String?
  /// Linear's sub-issues, as `identifier title` pairs with links.
  public var children: [(identifier: String, title: String, url: String)]

  public static func == (lhs: TrackerIssue, rhs: TrackerIssue) -> Bool {
    lhs.provider == rhs.provider && lhs.id == rhs.id && lhs.title == rhs.title && lhs.state == rhs.state
      && lhs.updatedAt == rhs.updatedAt && lhs.assignee == rhs.assignee && lhs.labels == rhs.labels
      && lhs.description == rhs.description && lhs.priority == rhs.priority && lhs.workspaceId == rhs.workspaceId
      && lhs.children.map(\.identifier) == rhs.children.map(\.identifier)
  }

  public init?(linear json: JSONValue) {
    guard let id = json["id"]?.stringValue, let identifier = json["identifier"]?.stringValue,
      let title = json["title"]?.stringValue
    else { return nil }
    provider = .linear
    self.id = id
    self.identifier = identifier
    self.title = title
    url = json["url"]?.stringValue ?? ""
    state = json["state"]?["name"]?.stringValue
    stateType = json["state"]?["type"]?.stringValue
    stateColor = json["state"]?["color"]?.stringValue
    group = json["team"]?["key"]?.stringValue
    teamId = json["team"]?["id"]?.stringValue
    teamName = json["team"]?["name"]?.stringValue
    updatedAt = json["updatedAt"]?.stringValue
    priority = json["priority"]?.intValue ?? 0
    priorityName = nil
    assignee = json["assignee"]?["displayName"]?.stringValue
    assigneeId = json["assignee"]?["id"]?.stringValue
    labels = (json["labels"]?.arrayValue ?? []).compactMap(\.stringValue)
    description = json["description"]?.stringValue
    workspaceId = json["workspaceId"]?.stringValue
    workspaceName = json["workspaceName"]?.stringValue
    projectName = json["project"]?["name"]?.stringValue
    typeName = nil
    children = (json["subIssues"]?.arrayValue ?? []).compactMap { child in
      guard let identifier = child["identifier"]?.stringValue, let title = child["title"]?.stringValue else {
        return nil
      }
      return (identifier, title, child["url"]?.stringValue ?? "")
    }
  }

  public init?(jira json: JSONValue) {
    guard let key = json["key"]?.stringValue, let title = json["title"]?.stringValue else { return nil }
    provider = .jira
    id = json["id"]?.stringValue ?? key
    identifier = key
    self.title = title
    url = json["url"]?.stringValue ?? ""
    state = json["status"]?["name"]?.stringValue
    stateType = json["status"]?["categoryKey"]?.stringValue
    stateColor = nil
    group = json["project"]?["key"]?.stringValue
    teamId = json["project"]?["id"]?.stringValue
    teamName = json["project"]?["name"]?.stringValue
    updatedAt = json["updatedAt"]?.stringValue
    priority = 0
    priorityName = json["priority"]?["name"]?.stringValue
    assignee = json["assignee"]?["displayName"]?.stringValue
    assigneeId = json["assignee"]?["accountId"]?.stringValue
    labels = (json["labels"]?.arrayValue ?? []).compactMap(\.stringValue)
    description = json["description"]?.stringValue
    workspaceId = json["siteId"]?.stringValue
    workspaceName = json["siteName"]?.stringValue
    projectName = json["project"]?["name"]?.stringValue
    typeName = json["issueType"]?["name"]?.stringValue
    children = []
  }

  /// A list reply: a bare array, or one wrapped in `items` or `issues`.
  static func rows(_ reply: JSONValue) -> [JSONValue] {
    reply.arrayValue ?? reply["items"]?.arrayValue ?? reply["issues"]?.arrayValue ?? []
  }

  public var updatedDate: Date? { TaskDates.parse(updatedAt) }
}

/// One comment under a Linear or Jira issue.
public struct TrackerComment: Sendable, Equatable, Identifiable {
  public var id: String
  public var author: String
  public var body: String
  /// ISO 8601.
  public var createdAt: String?

  init?(_ json: JSONValue) {
    guard let body = json["body"]?.stringValue else { return nil }
    id = json["id"]?.stringValue ?? json["id"]?.doubleValue.map { String(Int($0)) } ?? UUID().uuidString
    author = json["user"]?["displayName"]?.stringValue ?? json["author"]?.stringValue ?? ""
    self.body = body
    createdAt = json["createdAt"]?.stringValue
  }

  public var createdDate: Date? { TaskDates.parse(createdAt) }
}

enum TaskDates {
  static func parse(_ text: String?) -> Date? {
    guard let text else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

/// Linear's ways to order and group a list (task-list/mobile-tasks-options.tsx).
public enum LinearOrder: String, Sendable, CaseIterable { case priority, updated, identifier }

public enum LinearGrouping: String, Sendable, CaseIterable { case none, status, assignee, priority, team }

extension TrackerIssue {
  /// Priority first with "none" last, then newest activity; or newest activity; or identifier in number order.
  public static func sorted(_ issues: [TrackerIssue], by order: LinearOrder) -> [TrackerIssue] {
    switch order {
    case .identifier:
      return issues.sorted {
        $0.identifier.compare($1.identifier, options: [.numeric, .caseInsensitive]) == .orderedAscending
      }
    case .priority, .updated:
      return issues.enumerated().sorted { a, b in
        let ra = order == .updated ? 0 : a.element.priorityRank
        let rb = order == .updated ? 0 : b.element.priorityRank
        if ra != rb { return ra < rb }
        let da = a.element.updatedDate ?? .distantPast, db = b.element.updatedDate ?? .distantPast
        if da != db { return da > db }
        return a.offset < b.offset
      }.map(\.element)
    }
  }

  /// Sections in first-seen order of an already sorted list; `none` is one section keyed `all`.
  public static func grouped(_ sorted: [TrackerIssue], by grouping: LinearGrouping) -> [(key: String, issues: [TrackerIssue])] {
    guard grouping != .none else { return sorted.isEmpty ? [] : [("all", sorted)] }
    var order: [String] = []
    var sections: [String: [TrackerIssue]] = [:]
    for issue in sorted {
      let key = issue.groupKey(grouping)
      if sections[key] == nil { order.append(key) }
      sections[key, default: []].append(issue)
    }
    return order.map { ($0, sections[$0] ?? []) }
  }

  /// Linear's 1 (urgent) … 4 (low), with 0 (no priority) after them.
  public var priorityRank: Int { priority == 0 ? 5 : priority }

  public func groupKey(_ grouping: LinearGrouping) -> String {
    switch grouping {
    case .none: "all"
    case .status: "status:\(state ?? "")"
    case .assignee: "assignee:\(assigneeId ?? assignee ?? "unassigned")"
    case .priority: "priority:\(priority)"
    case .team: "team:\(teamId ?? group ?? "")"
    }
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

  /// Linear issues for one of the official filters (`all`, `assigned`, `created`, `completed`), or matching a search,
  /// from one workspace (`all` for every one) when given.
  public func linearIssues(filter: String, query: String = "", limit: Int = 50, workspaceId: String? = nil) async throws
    -> [TrackerIssue]
  {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var params: [String: JSONValue] = ["limit": .number(Double(limit))]
    if let workspaceId { params["workspaceId"] = .string(workspaceId) }
    if trimmed.isEmpty {
      params["filter"] = .string(filter)
    } else {
      params["query"] = .string(trimmed)
    }
    let reply = try await connection.request(trimmed.isEmpty ? "linear.listIssues" : "linear.searchIssues", .object(params))
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

  /// Jira issues for one of the official filters (`assigned`, `reported`, `all`, `done`), or matching a JQL search,
  /// from one site (`all` for every one) when given.
  public func jiraIssues(filter: String, query: String = "", limit: Int = 50, siteId: String? = nil) async throws
    -> [TrackerIssue]
  {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var params: [String: JSONValue] = ["limit": .number(Double(limit))]
    if let siteId { params["siteId"] = .string(siteId) }
    if trimmed.isEmpty {
      params["filter"] = .string(filter)
    } else {
      params["jql"] = .string(trimmed)
    }
    let reply = try await connection.request(trimmed.isEmpty ? "jira.listIssues" : "jira.searchIssues", .object(params))
    return TrackerIssue.rows(reply).compactMap(TrackerIssue.init(jira:))
  }
}
