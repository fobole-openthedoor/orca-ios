import OrcaCore
import UIKit

/// One Linear or Jira issue (tasks/item-detail/mobile-tasks-item-detail-drawer.tsx): its status and details, the
/// description, Linear's sub-issues and the discussion as plain text, and links out.
final class TrackerIssueDetailViewController: UITableViewController {
  private enum Row {
    case header
    case detail(String, String)
    case body(String)
    case placeholder(String)
    case child(identifier: String, title: String, url: String)
    case comment(TrackerComment)
    case action(String, Lucide, () -> Void)
  }

  private let session: HostSession
  private var issue: TrackerIssue
  private var comments: [TrackerComment] = []
  private var loaded = false
  private var loading = true
  private var loadError: String?
  private var sections: [(title: String?, rows: [Row])] = []

  init(session: HostSession, issue: TrackerIssue) {
    self.session = session
    self.issue = issue
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = issue.identifier
    navigationItem.subtitle = issue.provider == .linear ? (issue.teamName ?? "Linear") : (issue.projectName ?? "Jira")
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.load() })
    if let url = URL(string: issue.url), !issue.url.isEmpty {
      let open = UIBarButtonItem(
        image: Lucide.externalLink.image(size: 20), primaryAction: UIAction { _ in UIApplication.shared.open(url) })
      open.accessibilityLabel = String(localized: "common.open", defaultValue: "Open")
      navigationItem.rightBarButtonItem = open
    }
    rebuild()
    load()
  }

  private func load() {
    let api = session.api
    let issue = issue
    Task {
      do {
        switch issue.provider {
        case .linear:
          async let detail = api.linearIssue(id: issue.id, workspaceId: issue.workspaceId)
          async let thread = api.linearComments(issueId: issue.id, workspaceId: issue.workspaceId)
          guard let found = try await detail else { throw Self.notFound }
          self.issue = Self.keepingList(issue, found)
          comments = await thread
        case .jira:
          async let detail = api.jiraIssue(key: issue.identifier, siteId: issue.workspaceId)
          async let thread = api.jiraComments(key: issue.identifier, siteId: issue.workspaceId)
          guard let found = try await detail else { throw Self.notFound }
          self.issue = Self.keepingList(issue, found)
          comments = await thread
        }
        loaded = true
        loadError = nil
      } catch {
        loadError = TasksViewController.message(error)
      }
      loading = false
      refreshControl?.endRefreshing()
      rebuild()
    }
  }

  private static let notFound = TaskMessage("Details not found")

  /// The detail read with what only the list row knew (its workspace or site) kept.
  private static func keepingList(_ row: TrackerIssue, _ detail: TrackerIssue) -> TrackerIssue {
    var merged = detail
    merged.workspaceId = detail.workspaceId ?? row.workspaceId
    merged.workspaceName = detail.workspaceName ?? row.workspaceName
    return merged
  }

  private func rebuild() {
    let assignee = String(localized: "tasks.itemDetailContent.assignee", defaultValue: "Assignee")
    let project = String(localized: "tasks.itemDetailContent.project", defaultValue: "Project")
    var details: [Row] = [
      .detail(
        String(localized: "tasks.itemDetailContent.type", defaultValue: "Type"),
        issue.provider == .jira
          ? (issue.typeName ?? String(localized: "tasks.projectDetailDrawer.issue", defaultValue: "Issue"))
          : String(localized: "tasks.projectDetailDrawer.issue", defaultValue: "Issue")),
      .detail(String(localized: "tasks.itemDetailContent.status", defaultValue: "Status"), issue.state ?? "—"),
    ]
    switch issue.provider {
    case .linear:
      details.append(
        .detail(
          String(localized: "tasks.itemDetailContent.priority", defaultValue: "Priority"), Self.priorityLabel(issue.priority)))
      if let team = issue.teamName {
        details.append(.detail(String(localized: "tasks.options.team", defaultValue: "Team"), team))
      }
      if let name = issue.assignee { details.append(.detail(assignee, name)) }
      if let name = issue.projectName { details.append(.detail(project, name)) }
    case .jira:
      if let name = issue.assignee { details.append(.detail(assignee, name)) }
      if let name = issue.priorityName {
        details.append(.detail(String(localized: "tasks.itemDetailContent.priority", defaultValue: "Priority"), name))
      }
      if let name = issue.projectName ?? issue.group { details.append(.detail(project, name)) }
    }
    if !issue.labels.isEmpty {
      details.append(
        .detail(
          String(localized: "tasks.itemFieldEditors.labels", defaultValue: "Labels"), issue.labels.joined(separator: ", ")))
    }
    sections = [
      (nil, [.header]),
      (String(localized: "tasks.itemDetailContent.details", defaultValue: "Details"), details),
    ]
    let description = String(localized: "tasks.itemDetailContent.description", defaultValue: "Description")
    let discussion = String(localized: "tasks.itemDetailContent.discussion", defaultValue: "Discussion")
    if loaded {
      let body = TaskDetailViewController.plainText(issue.description ?? "")
      sections.append(
        (
          description,
          [
            body.isEmpty
              ? .placeholder(String(localized: "tasks.itemReviewSections.noDescription", defaultValue: "No description."))
              : .body(body)
          ]
        ))
      if issue.provider == .linear {
        sections.append(
          (
            String(localized: "tasks.itemDetailContent.subIssues", defaultValue: "Sub-issues"),
            issue.children.isEmpty
              ? [.placeholder(String(localized: "tasks.itemDetailContent.noSubIssues", defaultValue: "No sub-issues."))]
              : issue.children.map { .child(identifier: $0.identifier, title: $0.title, url: $0.url) }
          ))
      }
      sections.append(
        (
          comments.isEmpty ? discussion : "\(discussion) \(comments.count)",
          comments.isEmpty
            ? [.placeholder(String(localized: "tasks.itemDetailContent.noComments", defaultValue: "No comments."))]
            : comments.map(Row.comment)
        ))
    } else if loading {
      sections.append(
        (description, [.placeholder(String(localized: "tasks.itemDetailContent.loading", defaultValue: "Loading details…"))]))
    } else if let loadError {
      sections.append((description, [.placeholder(loadError)]))
    }
    if let url = URL(string: issue.url), !issue.url.isEmpty {
      sections.append(
        (
          nil,
          [
            .action(String(localized: "common.open", defaultValue: "Open"), .externalLink) {
              UIApplication.shared.open(url)
            },
            .action(
              issue.provider == .linear
                ? String(localized: "tasks.itemActions.copyLinearLink", defaultValue: "Copy Linear link")
                : String(localized: "tasks.itemActions.copyLink", defaultValue: "Copy link"), .copy
            ) { [issue] in UIPasteboard.general.string = issue.url },
          ]
        ))
    }
    tableView.reloadData()
  }

  /// hosted-review/mobile-tasks-hosted-review.ts LINEAR_PRIORITY_LABELS, English there too.
  static func priorityLabel(_ priority: Int) -> String {
    switch priority {
    case 0: "None"
    case 1: "Urgent"
    case 2: "High"
    case 3: "Medium"
    case 4: "Low"
    default: "P\(priority)"
    }
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].title
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    cell.selectionStyle = .none
    cell.accessoryType = .none
    switch sections[indexPath.section].rows[indexPath.row] {
    case .header:
      var content = UIListContentConfiguration.subtitleCell()
      content.text = issue.title
      content.textProperties.font = .systemFont(ofSize: Typography.titleSize, weight: .semibold)
      content.textProperties.numberOfLines = 0
      var meta = [issue.identifier]
      if let state = issue.state { meta.append(state) }
      if let date = issue.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) {
        meta.append(age)
      }
      content.secondaryText = meta.joined(separator: " · ")
      content.secondaryTextProperties.color = Palette.textSecondary
      content.textToSecondaryTextVerticalPadding = Spacing.xs
      content.image = TrackerIssueGlyph(issue).icon.image(size: 20)
      content.imageProperties.tintColor = TrackerIssueGlyph(issue).color
      cell.contentConfiguration = content
    case .detail(let title, let value):
      var content = UIListContentConfiguration.valueCell()
      content.text = title
      content.secondaryText = value
      content.secondaryTextProperties.numberOfLines = 2
      cell.contentConfiguration = content
    case .body(let text):
      var content = UIListContentConfiguration.cell()
      content.text = text
      content.textProperties.font = .systemFont(ofSize: 15)
      content.textProperties.numberOfLines = 0
      cell.contentConfiguration = content
    case .placeholder(let text):
      var content = UIListContentConfiguration.cell()
      content.text = text
      content.textProperties.color = Palette.textSecondary
      content.textProperties.numberOfLines = 0
      cell.contentConfiguration = content
    case .child(let identifier, let title, _):
      var content = UIListContentConfiguration.subtitleCell()
      content.text = title
      content.secondaryText = identifier
      content.secondaryTextProperties.color = Palette.textSecondary
      cell.contentConfiguration = content
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .comment(let comment):
      var content = UIListContentConfiguration.subtitleCell()
      var heading = comment.author
      if let created = comment.createdDate,
        let age = RelativeTime.short(created.timeIntervalSince1970 * 1000)
      {
        heading += heading.isEmpty ? age : " · \(age)"
      }
      content.text = heading
      content.textProperties.font = .systemFont(ofSize: 13, weight: .semibold)
      content.textProperties.color = Palette.textSecondary
      content.secondaryText = TaskDetailViewController.plainText(comment.body)
      content.secondaryTextProperties.font = .systemFont(ofSize: 15)
      content.secondaryTextProperties.color = Palette.textPrimary
      content.secondaryTextProperties.numberOfLines = 0
      content.textToSecondaryTextVerticalPadding = Spacing.xs
      cell.contentConfiguration = content
    case .action(let title, let icon, _):
      var content = UIListContentConfiguration.cell()
      content.text = title
      content.textProperties.color = Palette.accentBlue
      content.image = icon.image(size: 18)
      content.imageProperties.tintColor = Palette.accentBlue
      cell.contentConfiguration = content
      cell.selectionStyle = .default
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .action(_, _, let run): run()
    case .child(let identifier, let title, let url):
      // A sub-issue opens on what the parent knows of it; its page reads the rest by identifier.
      guard
        let child = TrackerIssue(linear: [
          "id": .string(identifier), "identifier": .string(identifier), "title": .string(title), "url": .string(url),
          "workspaceId": issue.workspaceId.map(JSONValue.string) ?? .null,
        ])
      else { return }
      navigationController?.pushViewController(
        TrackerIssueDetailViewController(session: session, issue: child), animated: true)
    default: break
    }
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
  ) -> UIContextMenuConfiguration? {
    let text: String
    switch sections[indexPath.section].rows[indexPath.row] {
    case .body(let body): text = body
    case .comment(let comment): text = comment.body
    case .header: text = issue.title
    default: return nil
    }
    return UIContextMenuConfiguration(actionProvider: { _ in
      UIMenu(children: [
        UIAction(title: String(localized: "common.copy", defaultValue: "Copy"), image: Lucide.copy.image(size: 18)) { _ in
          UIPasteboard.general.string = text
        }
      ])
    })
  }
}

/// A Linear issue's state dot in its own colour; Jira's status by category.
struct TrackerIssueGlyph {
  let icon: Lucide
  let color: UIColor

  init(_ issue: TrackerIssue) {
    switch (issue.provider, issue.stateType) {
    case (.linear, _):
      icon = issue.stateType == "completed" ? .circleCheck : (issue.stateType == "canceled" ? .circleX : .circleDot)
      color = issue.stateColor.flatMap { UIColor(hex: $0) } ?? Palette.textSecondary
    case (.jira, "done"):
      (icon, color) = (.circleCheck, Palette.statusGreen)
    case (.jira, "indeterminate"):
      (icon, color) = (.circleDot, Palette.accentBlue)
    case (.jira, _):
      (icon, color) = (.circleDot, Palette.textSecondary)
    }
  }
}
