import Foundation

/// The sources the Tasks screen reads (shared/work-items/task-providers.ts).
public enum TaskProvider: String, Sendable, CaseIterable {
  case github, gitlab, linear, jira

  public var label: String {
    switch self {
    case .github: "GitHub"
    case .gitlab: "GitLab"
    case .linear: "Linear"
    case .jira: "Jira"
    }
  }
}

/// What Tasks opens on (screen-state/task-queries.ts): the desktop's task settings, the view it last showed, and
/// which optional sources this desktop has.
public struct TaskHydration: Sendable, Equatable {
  public var defaultTaskSource: TaskProvider?
  /// `issues`, `my-issues`, `prs`, `my-prs`, `review` or `all`.
  public var defaultTaskViewPreset: String?
  public var visibleTaskProviders: [TaskProvider]
  /// nil: every repository.
  public var defaultRepoSelection: [String]?
  /// nil: every team.
  public var defaultLinearTeamSelection: [String]?
  public var githubProjects: GitHubProjectSettings
  /// `ui.taskResumeState` as the desktop keeps it; written back whole with changes.
  public var resume: [String: JSONValue]
  public var glabInstalled: Bool
  public var linearConnected: Bool

  public init(settings: JSONValue?, ui: JSONValue?, glabInstalled: Bool, linearConnected: Bool) {
    defaultTaskSource = settings?["defaultTaskSource"]?.stringValue.flatMap(TaskProvider.init)
    defaultTaskViewPreset = settings?["defaultTaskViewPreset"]?.stringValue
    var visible: [TaskProvider] = []
    for value in settings?["visibleTaskProviders"]?.arrayValue ?? [] {
      if let provider = value.stringValue.flatMap(TaskProvider.init), !visible.contains(provider) {
        visible.append(provider)
      }
    }
    visibleTaskProviders = visible.isEmpty ? TaskProvider.allCases : visible
    defaultRepoSelection = settings?["defaultRepoSelection"]?.arrayValue?.compactMap(\.stringValue)
    defaultLinearTeamSelection = settings?["defaultLinearTeamSelection"]?.arrayValue?.compactMap(\.stringValue)
    githubProjects = GitHubProjectSettings(settings?["githubProjects"])
    resume = ui?["taskResumeState"]?.objectValue ?? [:]
    self.glabInstalled = glabInstalled
    self.linearConnected = linearConnected
  }

  /// The sources shown: GitLab needs `glab`, Linear a connection, but a Linear the user chose stays so it can be
  /// connected; Jira always shows as its own setup entry point.
  public var availableProviders: [TaskProvider] {
    var available = visibleTaskProviders.filter { provider in
      switch provider {
      case .github, .jira: true
      case .gitlab: glabInstalled
      case .linear: linearConnected
      }
    }
    if available.isEmpty { available = [.github] }
    if visibleTaskProviders.contains(.linear), !available.contains(.linear) { available.append(.linear) }
    return available
  }

  /// The source to open on: the default when it is shown, else the first shown.
  public var initialProvider: TaskProvider {
    let available = availableProviders
    if let defaultTaskSource, available.contains(defaultTaskSource) { return defaultTaskSource }
    return available.first ?? .github
  }

  /// The GitHub list to open on: the last one picked, else the desktop's default preset.
  public var githubPreset: GitHubTaskPreset {
    if case .string(let saved)? = resume["githubItemsPreset"], let preset = GitHubTaskPreset(rawValue: saved) {
      return preset
    }
    return defaultTaskViewPreset.flatMap(GitHubTaskPreset.init) ?? .issues
  }

  /// A search typed over the preset (the preset is then saved as null), else the preset's own query.
  public var githubQuery: String {
    if resume["githubItemsPreset"]?.isNull == true { return resume["githubItemsQuery"]?.stringValue ?? "" }
    return githubPreset.query
  }

  public var githubProjectMode: Bool { resume["githubMode"]?.stringValue == "project" }
}

/// A Linear workspace the connected account can read.
public struct LinearWorkspace: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
}

/// `linear.status`: the account's workspaces and which one Tasks reads (`all` for every one).
public struct LinearAccount: Sendable, Equatable {
  public var connected: Bool
  public var workspaces: [LinearWorkspace]
  public var selectedWorkspaceId: String?

  public init(_ json: JSONValue) {
    connected = json["connected"]?.boolValue ?? false
    workspaces = (json["workspaces"]?.arrayValue ?? []).compactMap { row in
      guard let id = row["id"]?.stringValue else { return nil }
      return LinearWorkspace(
        id: id, name: row["organizationName"]?.stringValue ?? row["displayName"]?.stringValue ?? id)
    }
    selectedWorkspaceId =
      json["selectedWorkspaceId"]?.stringValue ?? json["activeWorkspaceId"]?.stringValue ?? workspaces.first?.id
  }
}

public struct LinearTeam: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var key: String
  public var workspaceId: String?
  public var workspaceName: String?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let name = json["name"]?.stringValue else { return nil }
    self.id = id
    self.name = name
    key = json["key"]?.stringValue ?? ""
    workspaceId = json["workspaceId"]?.stringValue
    workspaceName = json["workspaceName"]?.stringValue
  }
}

/// A Jira site the desktop has connected.
public struct JiraSite: Sendable, Equatable, Identifiable {
  public var id: String
  public var siteUrl: String
  public var displayName: String

  /// The site's name, or its host when it has none.
  public var label: String {
    let name = displayName.trimmingCharacters(in: .whitespaces)
    if !name.isEmpty { return name }
    var url = siteUrl
    for prefix in ["https://", "http://"] where url.hasPrefix(prefix) { url.removeFirst(prefix.count) }
    while url.hasSuffix("/") { url.removeLast() }
    return url
  }
}

/// `jira.status` (providers/jira/jira-mobile-connection.ts): the sites and which one Tasks reads (`all` for every one).
public struct JiraAccount: Sendable, Equatable {
  public var connected: Bool
  public var sites: [JiraSite]
  public var selection: String?

  public init(_ json: JSONValue) {
    connected = json["connected"]?.boolValue ?? false
    guard connected else {
      sites = []
      selection = nil
      return
    }
    sites = (json["sites"]?.arrayValue ?? []).compactMap { row in
      guard let id = row["id"]?.stringValue, let url = row["siteUrl"]?.stringValue else { return nil }
      return JiraSite(id: id, siteUrl: url, displayName: row["displayName"]?.stringValue ?? "")
    }
    let ids = Set(sites.map(\.id))
    if let selected = json["selectedSiteId"]?.stringValue, selected == "all" || ids.contains(selected) {
      selection = selected
    } else if let active = json["activeSiteId"]?.stringValue, ids.contains(active) {
      selection = active
    } else {
      selection = sites.first?.id
    }
  }
}

/// How a typed Jira search is sent (shared/jira/jira-search-input-jql.ts): JQL when it reads as JQL, else an issue
/// key, else a text match.
public enum JiraSearchInput {
  private static let operators = try! NSRegularExpression(
    pattern: [
      "[=~<>]",
      #"(?:^|[^\w-])(?:was|changed)(?![\w-])"#,
      #"(?:^|[^\w-])in(?:\s+[a-z_][\w.]*|\s*"[^"]+"|\s*'[^']+')?\s*\("#,
      #"(?:^|[^\w-])is\s+(?:not\s+)?(?:empty|null)(?![\w-])"#,
      #"^order\s+by\b"#,
    ].joined(separator: "|"), options: [.caseInsensitive])

  public static func mayBeJql(_ input: String) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return operators.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
  }

  /// `key = "ABC-12"` when the whole input is an issue key.
  public static func keyJql(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: #"^[A-Za-z][A-Za-z0-9_]*-\d+$"#, options: .regularExpression) != nil else { return nil }
    return "key = \"\(trimmed.uppercased())\""
  }

  /// `text ~ "words*"`, with Lucene syntax spaced out; empty when no words remain.
  public static func textJql(_ input: String) -> String {
    let words = input.replacingOccurrences(of: #"[+\-&|!(){}\[\]^"~*?:\\/]"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces).lowercased()
    guard !words.isEmpty else { return "" }
    let last = words.split(separator: " ").last.map(String.init) ?? words
    let wildcard = last.range(of: #"^[\p{L}\p{N}']+$"#, options: .regularExpression) != nil
    return "text ~ \"\(words)\(wildcard ? "*" : "")\""
  }

  /// Jira's reason when it refused a request as malformed (`Error 400: …`), else nil.
  public static func badRequestReason(_ error: Error) -> String? {
    let message = (error as? RPCError)?.message ?? error.localizedDescription
    guard let range = message.range(of: #"\bError (\d{3}):\s*"#, options: .regularExpression) else { return nil }
    let head = message[range]
    guard head.contains("400") else { return nil }
    return String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// A GitLab todo (`gitlab.todos`).
public struct GitLabTodo: Sendable, Equatable, Identifiable {
  public var id: Int
  public var actionName: String
  public var targetType: String?
  public var targetIid: Int?
  public var targetTitle: String?
  public var targetUrl: String
  public var projectPath: String
  /// ISO 8601.
  public var updatedAt: String

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.intValue, let action = json["actionName"]?.stringValue,
      let url = json["targetUrl"]?.stringValue, let path = json["projectPath"]?.stringValue,
      let updatedAt = json["updatedAt"]?.stringValue
    else { return nil }
    self.id = id
    actionName = action
    targetType = json["targetType"]?.stringValue
    targetIid = json["targetIid"]?.intValue
    targetTitle = json["targetTitle"]?.stringValue
    targetUrl = url
    projectPath = path
    self.updatedAt = updatedAt
  }

  /// `!12` for a merge request, `#12` for an issue.
  public var targetRef: String {
    guard let targetIid else { return "" }
    return targetType == "MergeRequest" ? "!\(targetIid)" : "#\(targetIid)"
  }

  public var updatedDate: Date? { TaskDates.parse(updatedAt) }
}

/// An `owner/repo` on GitHub.
public struct GitHubOwnerRepo: Sendable, Equatable {
  public var owner: String
  public var repo: String

  init?(_ json: JSONValue?) {
    guard let owner = json?["owner"]?.stringValue, let repo = json?["repo"]?.stringValue else { return nil }
    self.owner = owner
    self.repo = repo
  }

  public var slug: String { "\(owner)/\(repo)" }
}

/// Where one repository's issues and pull requests are read: a fork can read issues from its upstream or itself.
public struct GitHubIssueSources: Sendable, Equatable {
  public var issues: GitHubOwnerRepo?
  public var prs: GitHubOwnerRepo?
  public var upstreamCandidate: GitHubOwnerRepo?

  init?(_ json: JSONValue?) {
    guard case .object = json else { return nil }
    issues = GitHubOwnerRepo(json?["issues"])
    prs = GitHubOwnerRepo(json?["prs"])
    upstreamCandidate = GitHubOwnerRepo(json?["upstreamCandidate"])
  }

  /// Upstream and origin differ, so picking one matters.
  public var hasChoice: Bool {
    guard let prs, let upstreamCandidate else { return false }
    return prs.owner.lowercased() != upstreamCandidate.owner.lowercased()
      || prs.repo.lowercased() != upstreamCandidate.repo.lowercased()
  }
}

/// GitHub's page sizes for a read across repositories (shared/work-items/work-item-pagination.ts).
public enum GitHubTaskPaging {
  public static let perRepoFetchLimit = 36
  public static let crossRepoDisplayLimit = 100
  /// GitHub search refuses pages past its first 1000 results.
  public static let searchResultWindow = 1000

  public static func perRepoLimit(repoCount: Int) -> Int {
    max(1, min(perRepoFetchLimit, crossRepoDisplayLimit / max(1, repoCount)))
  }

  /// The largest repository's page count, capped at what GitHub search can reach.
  public static func countedTotalPages(_ counts: [Int], perRepoLimit: Int) -> Int {
    let limit = max(1, perRepoLimit)
    let reachable = max(1, Int((Double(searchResultWindow) / Double(limit)).rounded(.up)))
    return counts.reduce(0) { max($0, min(Int((Double($1) / Double(limit)).rounded(.up)), reachable)) }
  }
}

extension HostAPI {
  /// Settings, resume state and source availability in one batch, as Tasks hydrates. Only settings must answer.
  public func taskHydration() async throws -> TaskHydration {
    async let settings = connection.request("settings.get", [:])
    async let ui = try? connection.request("ui.get", [:])
    async let preflight = try? connection.request("preflight.check", [:])
    async let linear = try? connection.request("linear.status", [:])
    let settingsReply = try await settings
    let (uiReply, preflightReply, linearReply) = await (ui, preflight, linear)
    return TaskHydration(
      settings: settingsReply["settings"], ui: uiReply?["ui"],
      glabInstalled: preflightReply?["glab"]?["installed"]?.boolValue ?? false,
      linearConnected: linearReply?["connected"]?.boolValue ?? false)
  }

  /// Saves the view to reopen on (`ui.set` `taskResumeState`); the desktop keeps the whole object.
  public func setTaskResumeState(_ state: [String: JSONValue]) async throws {
    _ = try await connection.request("ui.set", ["taskResumeState": .object(state)])
  }

  /// Saves task preferences (`settings.update`): `defaultTaskSource`, `defaultRepoSelection`, `defaultTaskViewPreset`,
  /// `defaultLinearTeamSelection`, `githubProjects`.
  public func updateTaskSettings(_ patch: [String: JSONValue]) async throws {
    _ = try await connection.request("settings.update", .object(patch))
  }

  // MARK: GitHub

  /// One page of a repository's issues or pull requests, with where its issues are read from.
  public func githubWorkItemPage(in repo: TaskRepo, query: String, limit: Int, page: Int) async throws
    -> (items: [GitHubWorkItem], sources: GitHubIssueSources?)
  {
    let reply = try await connection.request(
      "github.listWorkItems",
      [
        "repo": .string("id:\(repo.id)"), "limit": .number(Double(limit)), "query": .string(query),
        "page": .number(Double(page)),
      ])
    return (
      (reply["items"]?.arrayValue ?? []).compactMap { GitHubWorkItem($0, repo: repo) },
      GitHubIssueSources(reply["sources"])
    )
  }

  /// How many items match in one repository (`github.countWorkItems`), for the page count.
  public func countGitHubWorkItems(in repo: TaskRepo, query: String) async throws -> Int {
    try await connection.request(
      "github.countWorkItems", ["repo": .string("id:\(repo.id)"), "query": .string(query)], timeout: .seconds(30)
    ).intValue ?? 0
  }

  /// Reads and files a fork's issues from `upstream` or `origin` (`repo.update`).
  public func setIssueSourcePreference(repoId: String, _ preference: String) async throws {
    _ = try await connection.request(
      "repo.update",
      ["repo": .string("id:\(repoId)"), "updates": ["issueSourcePreference": .string(preference)]],
      timeout: .seconds(15))
  }

  /// The GitHub `owner/repo` a project points at (`github.repoSlug`), nil when it has none.
  public func githubRepoSlug(repoId: String) async throws -> GitHubOwnerRepo? {
    GitHubOwnerRepo(try await connection.request("github.repoSlug", ["repo": .string("id:\(repoId)")]))
  }

  // MARK: GitLab

  /// One repository's GitLab issues and merge requests (`gitlab.listWorkItems`); merge requests read as `.pr`.
  /// Returns the host's in-band error, except for a project GitLab doesn't know.
  public func gitlabWorkItems(in repo: TaskRepo, state: String, query: String, page: Int = 1, perPage: Int = 50)
    async throws -> (items: [GitHubWorkItem], error: String?)
  {
    var params: [String: JSONValue] = [
      "repo": .string("id:\(repo.id)"), "state": .string(state), "page": .number(Double(page)),
      "perPage": .number(Double(perPage)),
    ]
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { params["query"] = .string(trimmed) }
    let reply = try await connection.request("gitlab.listWorkItems", .object(params))
    if let error = reply["error"], let type = error["type"]?.stringValue, type != "not_found" {
      return ([], error["message"]?.stringValue ?? type)
    }
    let items = (reply["items"]?.arrayValue ?? []).compactMap { row -> GitHubWorkItem? in
      guard case .object(var fields) = row else { return nil }
      if fields["type"]?.stringValue == "mr" { fields["type"] = "pr" }
      return GitHubWorkItem(.object(fields), repo: repo)
    }
    return (items, nil)
  }

  /// The signed-in GitLab user's pending todos, read through one repository's host (`gitlab.todos`).
  public func gitlabTodos(via repo: TaskRepo) async throws -> [GitLabTodo] {
    let reply = try await connection.request("gitlab.todos", ["repo": .string("id:\(repo.id)")])
    return (reply.arrayValue ?? []).compactMap(GitLabTodo.init)
  }

  // MARK: Linear

  public func linearAccount() async throws -> LinearAccount {
    LinearAccount(try await connection.request("linear.status", [:]))
  }

  public func linearTeams(workspaceId: String?) async throws -> [LinearTeam] {
    let params: JSONValue = workspaceId.map { ["workspaceId": .string($0)] } ?? [:]
    return (try await connection.request("linear.listTeams", params).arrayValue ?? []).compactMap(LinearTeam.init)
  }

  /// Points the desktop's Linear reads at one workspace, or `all` (`linear.selectWorkspace`).
  public func selectLinearWorkspace(_ workspaceId: String) async throws {
    _ = try await connection.request("linear.selectWorkspace", ["workspaceId": .string(workspaceId)])
  }

  /// One Linear issue with its description and sub-issues (`linear.getIssue`); nil when it is gone.
  public func linearIssue(id: String, workspaceId: String?) async throws -> TrackerIssue? {
    var params: [String: JSONValue] = ["id": .string(id)]
    if let workspaceId { params["workspaceId"] = .string(workspaceId) }
    return TrackerIssue(linear: try await connection.request("linear.getIssue", .object(params), timeout: .seconds(30)))
  }

  /// A Linear issue's comments (`linear.issueComments`); a refusal reads as none.
  public func linearComments(issueId: String, workspaceId: String?) async -> [TrackerComment] {
    var params: [String: JSONValue] = ["issueId": .string(issueId)]
    if let workspaceId { params["workspaceId"] = .string(workspaceId) }
    let reply = try? await connection.request("linear.issueComments", .object(params), timeout: .seconds(30))
    return (reply?.arrayValue ?? []).compactMap(TrackerComment.init)
  }

  /// Files a Linear issue in a team (`linear.createIssue`) and returns its id, identifier and link.
  public func createLinearIssue(team: LinearTeam, title: String, description: String) async throws
    -> (id: String, identifier: String, url: String)
  {
    var params: [String: JSONValue] = ["teamId": .string(team.id), "title": .string(title)]
    let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
    if !body.isEmpty { params["description"] = .string(body) }
    if let workspaceId = team.workspaceId { params["workspaceId"] = .string(workspaceId) }
    let reply = try await connection.request("linear.createIssue", .object(params))
    guard reply["ok"]?.boolValue != false, let id = reply["id"]?.stringValue,
      let identifier = reply["identifier"]?.stringValue
    else {
      throw RPCError(
        code: "linear_create_issue_failed", message: reply["error"]?.stringValue ?? "Failed to create Linear issue",
        data: nil)
    }
    return (id, identifier, reply["url"]?.stringValue ?? "")
  }

  // MARK: Jira

  public func jiraAccount() async throws -> JiraAccount {
    JiraAccount(try await connection.request("jira.status", [:]))
  }

  /// What a user typed, searched as Jira does (shared/jira/jira-issue-input-search.ts): JQL first when it reads as
  /// JQL, falling back to a text match when Jira refuses it (the refusal's reason is returned); else a key, else
  /// text.
  public func searchJira(_ input: String, limit: Int = 50, siteId: String?) async throws
    -> (issues: [TrackerIssue], jqlRejection: String?)
  {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let search: (String) async throws -> [TrackerIssue] = { jql in
      try await self.jiraIssues(filter: "all", query: jql, limit: limit, siteId: siteId)
    }
    if !JiraSearchInput.mayBeJql(trimmed) {
      if let keyJql = JiraSearchInput.keyJql(trimmed) {
        let issues: [TrackerIssue]
        do {
          issues = try await search(keyJql)
        } catch {
          guard JiraSearchInput.badRequestReason(error) != nil else { throw error }
          issues = []
        }
        if !issues.isEmpty { return (issues, nil) }
      }
      let text = JiraSearchInput.textJql(trimmed)
      return (text.isEmpty ? [] : try await search(text), nil)
    }
    do {
      return (try await search(trimmed), nil)
    } catch {
      let text = JiraSearchInput.textJql(trimmed)
      guard let reason = JiraSearchInput.badRequestReason(error), !text.isEmpty else { throw error }
      do {
        return (try await search(text), reason)
      } catch let textError {
        throw JiraSearchInput.badRequestReason(textError) == nil ? textError : error
      }
    }
  }

  /// One Jira issue (`jira.getIssue`).
  public func jiraIssue(key: String, siteId: String?) async throws -> TrackerIssue? {
    var params: [String: JSONValue] = ["key": .string(key)]
    if let siteId { params["siteId"] = .string(siteId) }
    return TrackerIssue(jira: try await connection.request("jira.getIssue", .object(params), timeout: .seconds(30)))
  }

  /// A Jira issue's comments (`jira.issueComments`); a refusal reads as none.
  public func jiraComments(key: String, siteId: String?) async -> [TrackerComment] {
    var params: [String: JSONValue] = ["key": .string(key)]
    if let siteId { params["siteId"] = .string(siteId) }
    let reply = try? await connection.request("jira.issueComments", .object(params), timeout: .seconds(30))
    return (reply?.arrayValue ?? []).compactMap(TrackerComment.init)
  }
}
