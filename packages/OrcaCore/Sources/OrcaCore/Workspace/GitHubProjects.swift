import Foundation

/// A GitHub Project by its owner and number (shared/github/projects/project-identity.ts).
public struct GitHubProjectRef: Sendable, Equatable, Hashable {
  public var owner: String
  /// `organization` or `user`.
  public var ownerType: String
  public var number: Int
  /// An Enterprise host; nil for github.com.
  public var host: String?

  public init(owner: String, ownerType: String, number: Int, host: String? = nil) {
    self.owner = owner
    self.ownerType = ownerType
    self.number = number
    let trimmed = host?.trimmingCharacters(in: .whitespaces).lowercased()
    self.host = trimmed.flatMap { $0.isEmpty || $0 == "github.com" ? nil : $0 }
  }

  init?(_ json: JSONValue?) {
    guard let owner = json?["owner"]?.stringValue, let ownerType = json?["ownerType"]?.stringValue,
      ownerType == "organization" || ownerType == "user", let number = json?["number"]?.intValue
    else { return nil }
    self.init(owner: owner, ownerType: ownerType, number: number, host: json?["host"]?.stringValue)
  }

  /// The settings key: github.com keeps the legacy `ownerType:owner:number` shape.
  public var key: String {
    let base = "\(ownerType):\(owner.lowercased()):\(number)"
    return host.map { "\($0):\(base)" } ?? base
  }

  /// Project calls pin github.com too, so the desktop's GH_HOST can't redirect them.
  public var apiHost: String { host ?? "github.com" }

  /// Identity fields only: the settings schema refuses anything else.
  var json: JSONValue {
    var fields: [String: JSONValue] = [
      "owner": .string(owner), "ownerType": .string(ownerType), "number": .number(Double(number)),
    ]
    if let host { fields["host"] = .string(host) }
    return .object(fields)
  }

  /// `owner/12`, or a project URL (`…/orgs/owner/projects/12[/views/3]`), as Add by URL accepts.
  public static func parseInput(_ input: String) -> (owner: String, number: Int, host: String?, viewNumber: Int?)? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let owner = #"[A-Za-z0-9][A-Za-z0-9_-]*"#
    if trimmed.range(of: "^\(owner)/\\d+$", options: .regularExpression) != nil {
      let parts = trimmed.split(separator: "/")
      guard let number = Int(parts[1]), number > 0 else { return nil }
      return (String(parts[0]), number, nil, nil)
    }
    guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http", url.user == nil,
      url.password == nil, let host = url.host, !host.isEmpty
    else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    let hasView = parts.count == 6 && parts[4] == "views"
    guard parts.count == 4 || hasView, parts[0] == "orgs" || parts[0] == "users",
      parts[1].range(of: "^\(owner)$", options: .regularExpression) != nil, parts[2] == "projects",
      let number = Int(parts[3]), number > 0
    else { return nil }
    var view: Int?
    if hasView {
      guard let viewNumber = Int(parts[5]), viewNumber > 0 else { return nil }
      view = viewNumber
    }
    return (parts[1], number, host.lowercased(), view)
  }
}

/// The projects Tasks remembers (`settings.githubProjects`): pinned, recently opened, and each one's last view.
public struct GitHubProjectSettings: Sendable, Equatable {
  public var pinned: [GitHubProjectRef] = []
  /// Newest first, with when each was opened.
  public var recent: [(ref: GitHubProjectRef, lastOpenedAt: String)] = []
  public var lastViewByProject: [String: String] = [:]
  public var activeProject: GitHubProjectRef?

  public static func == (lhs: GitHubProjectSettings, rhs: GitHubProjectSettings) -> Bool {
    lhs.pinned == rhs.pinned && lhs.recent.map(\.ref) == rhs.recent.map(\.ref)
      && lhs.lastViewByProject == rhs.lastViewByProject && lhs.activeProject == rhs.activeProject
  }

  public init() {}

  init(_ json: JSONValue?) {
    pinned = (json?["pinned"]?.arrayValue ?? []).compactMap(GitHubProjectRef.init)
    recent = (json?["recent"]?.arrayValue ?? []).compactMap { row in
      GitHubProjectRef(row).map { ($0, row["lastOpenedAt"]?.stringValue ?? "") }
    }
    for (key, value) in json?["lastViewByProject"]?.objectValue ?? [:] {
      if let viewId = value["viewId"]?.stringValue { lastViewByProject[key] = viewId }
    }
    activeProject = GitHubProjectRef(json?["activeProject"])
  }

  public var json: JSONValue {
    [
      "pinned": .array(pinned.map(\.json)),
      "recent": .array(
        recent.map { entry in
          guard case .object(var fields) = entry.ref.json else { return entry.ref.json }
          fields["lastOpenedAt"] = .string(entry.lastOpenedAt)
          return .object(fields)
        }),
      "lastViewByProject": .object(lastViewByProject.mapValues { ["viewId": .string($0)] }),
      "activeProject": activeProject?.json ?? .null,
    ]
  }

  /// Opening a project's view: it becomes the active project, first among the recent ten, with this view kept.
  public func opening(_ project: GitHubProjectRef, viewId: String, at date: Date = Date()) -> GitHubProjectSettings {
    var next = self
    let stamp = ISO8601DateFormatter().string(from: date)
    next.recent = Array(([(project, stamp)] + recent.filter { $0.ref.key != project.key }).prefix(10))
    next.lastViewByProject[project.key] = viewId
    next.activeProject = project
    return next
  }
}

/// A project the account can open (`github.project.listAccessible`).
public struct GitHubProjectSummary: Sendable, Equatable, Identifiable {
  public var ref: GitHubProjectRef
  public var title: String
  public var id: String { ref.key }
}

/// A project view (`github.project.listViews`); only table views open on a phone.
public struct GitHubProjectView: Sendable, Equatable, Identifiable {
  public var id: String
  public var number: Int
  public var name: String
  /// `TABLE_LAYOUT`, `BOARD_LAYOUT` or `ROADMAP_LAYOUT`.
  public var layout: String

  init?(_ json: JSONValue?) {
    guard let id = json?["id"]?.stringValue else { return nil }
    self.id = id
    number = json?["number"]?.intValue ?? 0
    name = json?["name"]?.stringValue ?? ""
    layout = json?["layout"]?.stringValue ?? ""
  }

  public var isTable: Bool { layout == "TABLE_LAYOUT" }
}

/// A field of a project view.
public struct GitHubProjectField: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  /// `TEXT`, `NUMBER`, `DATE`, `SINGLE_SELECT`, `ITERATION`, `ASSIGNEES`, `LABELS`, `TITLE`, `REPOSITORY`…
  public var dataType: String
  /// Single-select options and iterations, in the project's order, as `(id, name)`.
  public var choices: [(id: String, name: String)]

  public static func == (lhs: GitHubProjectField, rhs: GitHubProjectField) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.dataType == rhs.dataType
  }

  init?(_ json: JSONValue?) {
    guard let id = json?["id"]?.stringValue, let name = json?["name"]?.stringValue else { return nil }
    self.id = id
    self.name = name
    dataType = json?["dataType"]?.stringValue ?? ""
    let options = (json?["options"]?.arrayValue ?? []).compactMap { option -> (String, String)? in
      guard let id = option["id"]?.stringValue else { return nil }
      return (id, option["name"]?.stringValue ?? "")
    }
    let iterations = (json?["iterations"]?.arrayValue ?? []).compactMap { iteration -> (String, String)? in
      guard let id = iteration["id"]?.stringValue else { return nil }
      return (id, iteration["title"]?.stringValue ?? "")
    }
    choices = options + iterations
  }
}

/// One project item's value for a field.
public enum GitHubProjectFieldValue: Sendable, Equatable {
  case text(String)
  case number(Double)
  case date(String)
  /// A single-select option or an iteration: its id and name.
  case choice(id: String, name: String)
  case list([String])

  init?(_ json: JSONValue) {
    switch json["kind"]?.stringValue {
    case "text": self = .text(json["text"]?.stringValue ?? "")
    case "number": self = .number(json["number"]?.doubleValue ?? 0)
    case "date": self = .date(json["date"]?.stringValue ?? "")
    case "single-select":
      self = .choice(id: json["optionId"]?.stringValue ?? "", name: json["name"]?.stringValue ?? "")
    case "iteration":
      self = .choice(id: json["iterationId"]?.stringValue ?? "", name: json["title"]?.stringValue ?? "")
    case "labels": self = .list((json["labels"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
    case "users": self = .list((json["users"]?.arrayValue ?? []).compactMap { $0["login"]?.stringValue })
    default: return nil
    }
  }

  public var label: String {
    switch self {
    case .text(let text): text
    case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
    case .date(let date): date
    case .choice(_, let name): name
    case .list(let names): names.joined(separator: ", ")
    }
  }
}

/// One project item (an issue, pull request or draft).
public struct GitHubProjectRow: Sendable, Equatable, Identifiable {
  public var id: String
  /// `ISSUE`, `PULL_REQUEST`, `DRAFT_ISSUE` or `REDACTED`.
  public var itemType: String
  public var number: Int?
  public var title: String
  public var url: String?
  /// `OPEN`, `CLOSED` or `MERGED`.
  public var state: String?
  public var isDraft: Bool
  /// `owner/repo`.
  public var repository: String?
  public var labels: [String]
  public var assignees: [String]
  public var issueType: String?
  public var values: [String: GitHubProjectFieldValue]
  /// ISO 8601.
  public var updatedAt: String?
  public var position: Int

  init?(_ json: JSONValue, index: Int) {
    guard let id = json["id"]?.stringValue else { return nil }
    let content = json["content"]
    self.id = id
    itemType = json["itemType"]?.stringValue ?? "ISSUE"
    number = content?["number"]?.intValue
    title = content?["title"]?.stringValue ?? ""
    url = content?["url"]?.stringValue
    state = content?["state"]?.stringValue
    isDraft = content?["isDraft"]?.boolValue ?? false
    repository = content?["repository"]?.stringValue
    labels = (content?["labels"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    assignees = (content?["assignees"]?.arrayValue ?? []).compactMap { $0["login"]?.stringValue }
    issueType = content?["issueType"]?["name"]?.stringValue
    var values: [String: GitHubProjectFieldValue] = [:]
    for (fieldId, value) in json["fieldValuesByFieldId"]?.objectValue ?? [:] {
      values[fieldId] = GitHubProjectFieldValue(value)
    }
    self.values = values
    updatedAt = json["updatedAt"]?.stringValue
    position = json["position"]?.intValue ?? index
  }

  public var updatedDate: Date? { TaskDates.parse(updatedAt) }

  /// The issue or pull request behind the row, in the project here that points at its repository; nil for a draft.
  public func workItem(in repo: TaskRepo) -> GitHubWorkItem? {
    guard let number, itemType == "ISSUE" || itemType == "PULL_REQUEST" else { return nil }
    let state = (state ?? "open").lowercased()
    return GitHubWorkItem(
      [
        "number": .number(Double(number)), "title": .string(title),
        "type": itemType == "PULL_REQUEST" ? "pr" : "issue",
        "state": .string(itemType == "PULL_REQUEST" && isDraft && state == "open" ? "draft" : state),
        "url": .string(url ?? ""), "updatedAt": updatedAt.map(JSONValue.string) ?? .null,
        "labels": .array(labels.map(JSONValue.string)),
      ], repo: repo)
  }

  /// The row's value for a field, from the item itself for built-in fields; nil when empty.
  public func value(for field: GitHubProjectField) -> String? {
    let text: String? =
      switch field.dataType {
      case "TITLE": title
      case "ASSIGNEES": assignees.joined(separator: ", ")
      case "LABELS": labels.joined(separator: ", ")
      case "ISSUE_TYPE": issueType
      case "REPOSITORY": repository
      default: values[field.id]?.label
      }
    guard let text, !text.isEmpty else { return nil }
    return text
  }
}

/// A view's rows with its fields, grouping and sort (`github.project.viewTable`).
public struct GitHubProjectTable: Sendable, Equatable {
  public var projectId: String
  public var projectTitle: String
  public var projectURL: String?
  public var view: GitHubProjectView
  /// The view's own search.
  public var filter: String
  public var fields: [GitHubProjectField]
  public var groupBy: GitHubProjectField?
  /// The view's sort: a field and whether it runs descending.
  public var sortBy: (field: GitHubProjectField, descending: Bool)?
  public var rows: [GitHubProjectRow]

  public static func == (lhs: GitHubProjectTable, rhs: GitHubProjectTable) -> Bool {
    lhs.projectId == rhs.projectId && lhs.view == rhs.view && lhs.filter == rhs.filter && lhs.rows == rhs.rows
  }

  init?(_ data: JSONValue?) {
    guard let data, let projectId = data["project"]?["id"]?.stringValue,
      let view = GitHubProjectView(data["selectedView"])
    else { return nil }
    self.projectId = projectId
    projectTitle = data["project"]?["title"]?.stringValue ?? ""
    projectURL = data["project"]?["url"]?.stringValue
    self.view = view
    let selected = data["selectedView"]
    filter = selected?["filter"]?.stringValue ?? ""
    fields = (selected?["fields"]?.arrayValue ?? []).compactMap(GitHubProjectField.init)
    groupBy = (selected?["groupByFields"]?.arrayValue ?? []).compactMap(GitHubProjectField.init).first
    sortBy = (selected?["sortByFields"]?.arrayValue ?? []).compactMap { sort in
      GitHubProjectField(sort["field"]).map { ($0, sort["direction"]?.stringValue == "DESC") }
    }.first
    rows = (data["rows"]?.arrayValue ?? []).enumerated().compactMap { GitHubProjectRow($0.element, index: $0.offset) }
  }

  /// Fields that can show on a row: everything but the title and repository the row already shows.
  public var summaryFields: [GitHubProjectField] {
    fields.filter { $0.dataType != "TITLE" && $0.dataType != "REPOSITORY" }
  }

  /// Where hidden-field choices are kept: per project and view.
  public var visibilityKey: String { "\(projectId):\(view.id)" }

  /// Rows in the view's order, or by `field` when one overrides it; empty values sort last either way.
  public func sortedRows(by override: (fieldId: String, descending: Bool)? = nil) -> [GitHubProjectRow] {
    let sort: (field: GitHubProjectField, descending: Bool)? =
      override.flatMap { o in fields.first { $0.id == o.fieldId }.map { ($0, o.descending) } } ?? sortBy
    guard let sort else { return rows.sorted { $0.position < $1.position } }
    let order = Dictionary(sort.field.choices.enumerated().map { ($0.element.id, $0.offset) }) { a, _ in a }
    return rows.sorted { a, b in
      let cmp = Self.compare(a, b, field: sort.field, order: order)
      if cmp != 0 {
        let filled = a.value(for: sort.field) != nil && b.value(for: sort.field) != nil
        return filled && sort.descending ? cmp > 0 : cmp < 0
      }
      return a.position < b.position
    }
  }

  /// The view's grouping, in the field's own option order (alphabetical for free values), with the empty group last.
  public func groups(_ rows: [GitHubProjectRow]) -> [(key: String, label: String, rows: [GitHubProjectRow])] {
    guard let field = groupBy else { return [("all", "", rows)] }
    let order = Dictionary(field.choices.enumerated().map { ($0.element.id, $0.offset) }) { a, _ in a }
    var buckets: [String: (label: String, hint: Double, rows: [GitHubProjectRow])] = [:]
    for row in rows {
      let key: String, label: String, hint: Double
      if case .choice(let id, let name)? = row.values[field.id] {
        (key, label, hint) = (id, name, Double(order[id] ?? Int.max - 1))
      } else if let text = row.value(for: field) {
        if case .number(let number)? = row.values[field.id] {
          (key, label, hint) = ("raw:\(text)", text, number)
        } else {
          (key, label, hint) = ("raw:\(text)", text, 0)
        }
      } else {
        (key, label, hint) = ("__empty__", "No \(field.name)", .infinity)
      }
      buckets[key, default: (label, hint, [])].rows.append(row)
    }
    let byChoice = field.dataType == "SINGLE_SELECT" || field.dataType == "ITERATION" || field.dataType == "NUMBER"
    return buckets.sorted { a, b in
      if a.key == "__empty__" { return false }
      if b.key == "__empty__" { return true }
      if byChoice, a.value.hint != b.value.hint { return a.value.hint < b.value.hint }
      return a.value.label.localizedStandardCompare(b.value.label) == .orderedAscending
    }.map { ($0.key, $0.value.label, $0.value.rows) }
  }

  /// Negative when `a` sorts first; empty values after filled ones.
  private static func compare(_ a: GitHubProjectRow, _ b: GitHubProjectRow, field: GitHubProjectField, order: [String: Int])
    -> Int
  {
    let av = a.value(for: field), bv = b.value(for: field)
    guard let av, let bv else { return av == nil && bv == nil ? 0 : (av == nil ? 1 : -1) }
    switch (a.values[field.id], b.values[field.id]) {
    case (.choice(let ia, _)?, .choice(let ib, _)?):
      let ra = order[ia] ?? Int.max, rb = order[ib] ?? Int.max
      return ra == rb ? 0 : (ra < rb ? -1 : 1)
    case (.number(let na)?, .number(let nb)?):
      return na == nb ? 0 : (na < nb ? -1 : 1)
    default:
      switch av.localizedStandardCompare(bv) {
      case .orderedAscending: return -1
      case .orderedDescending: return 1
      case .orderedSame: return 0
      }
    }
  }
}

extension HostAPI {
  /// The projects the account can open, and the owners that failed to load (`github.project.listAccessible`).
  public func githubProjects() async throws -> (projects: [GitHubProjectSummary], failures: [(owner: String, message: String)]) {
    let reply = try await connection.request("github.project.listAccessible", [:], timeout: .seconds(60))
    try Self.throwProjectError(reply)
    let projects = (reply["projects"]?.arrayValue ?? []).compactMap { row -> GitHubProjectSummary? in
      guard let ref = GitHubProjectRef(row), let title = row["title"]?.stringValue else { return nil }
      return GitHubProjectSummary(ref: ref, title: title)
    }
    let failures = (reply["partialFailures"]?.arrayValue ?? []).map {
      ($0["owner"]?.stringValue ?? "", $0["message"]?.stringValue ?? "")
    }
    return (projects, failures)
  }

  public func githubProjectViews(_ project: GitHubProjectRef) async throws -> [GitHubProjectView] {
    let reply = try await connection.request(
      "github.project.listViews",
      [
        "owner": .string(project.owner), "host": .string(project.apiHost), "ownerType": .string(project.ownerType),
        "projectNumber": .number(Double(project.number)),
      ])
    try Self.throwProjectError(reply)
    return (reply["views"]?.arrayValue ?? []).compactMap(GitHubProjectView.init)
  }

  /// A view's rows (`github.project.viewTable`), searched with `query` in place of the view's own filter when given.
  public func githubProjectTable(_ project: GitHubProjectRef, viewId: String, query: String? = nil) async throws
    -> GitHubProjectTable?
  {
    var params: [String: JSONValue] = [
      "owner": .string(project.owner), "host": .string(project.apiHost), "ownerType": .string(project.ownerType),
      "projectNumber": .number(Double(project.number)), "viewId": .string(viewId),
    ]
    if let query { params["queryOverride"] = .string(query) }
    let reply = try await connection.request("github.project.viewTable", .object(params), timeout: .seconds(60))
    try Self.throwProjectError(reply)
    return GitHubProjectTable(reply["data"])
  }

  /// Resolves a pasted URL or `owner/number` (`github.project.resolveRef`) to a project and, for a view URL, its view.
  public func resolveGitHubProject(_ input: String, host: String?) async throws -> (ref: GitHubProjectRef, viewNumber: Int?) {
    let reply = try await connection.request(
      "github.project.resolveRef", ["input": .string(input), "host": .string(host ?? "github.com")])
    try Self.throwProjectError(reply)
    guard let ref = GitHubProjectRef(reply) else {
      throw RPCError(code: "github_project_unresolved", message: "Failed to add project.", data: nil)
    }
    return (ref, reply["viewNumber"]?.intValue)
  }

  private static func throwProjectError(_ reply: JSONValue) throws {
    if reply["ok"]?.boolValue == false {
      throw RPCError(
        code: "github_project_failed", message: reply["error"]?["message"]?.stringValue ?? "GitHub Projects failed",
        data: nil)
    }
  }
}
