import OrcaCore
import UIKit

/// One issue or pull request (tasks/item-detail/mobile-tasks-item-detail-drawer.tsx): its state and details, the
/// description and discussion as plain text, a link to GitHub, and Create Workspace to start work on it.
final class TaskDetailViewController: UITableViewController {
  var onOpenWorkspace: ((HostSession, String) -> Void)?

  private enum Row {
    case header
    case detail(String, String)
    case body(String)
    case placeholder(String)
    case comment(GitHubWorkItemDetails.Comment)
    case action(String, Lucide, () -> Void)
  }

  private let session: HostSession
  private let item: GitHubWorkItem
  private var details: GitHubWorkItemDetails?
  private var loading = true
  private var loadError: String?
  private var sections: [(title: String?, rows: [Row])] = []
  private var creating = false

  init(session: HostSession, item: GitHubWorkItem) {
    self.session = session
    self.item = item
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "#\(item.number)"
    navigationItem.subtitle = item.repoName
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.load() })
    let create = UIBarButtonItem(
      title: String(localized: "tasks.projectDetailDrawer.createWorkspace", defaultValue: "Create Workspace"),
      style: .prominent, target: nil, action: nil)
    create.tintColor = Palette.createActionFill
    create.primaryAction = UIAction(title: create.title ?? "") { [weak self] _ in self?.promptCreateWorkspace() }
    navigationItem.rightBarButtonItem = create
    rebuild()
    load()
  }

  private func load() {
    let api = session.api
    let item = item
    Task {
      do {
        details = try await api.githubWorkItemDetails(item)
        loadError = nil
      } catch {
        loadError = TasksViewController.message(error)
      }
      loading = false
      refreshControl?.endRefreshing()
      rebuild()
    }
  }

  private func rebuild() {
    let glyph = TaskStateGlyph(item)
    var detailRows: [Row] = [
      .detail(String(localized: "tasks.itemDetailContent.status", defaultValue: "Status"), glyph.label),
      .detail(
        String(localized: "tasks.itemDetailContent.type", defaultValue: "Type"),
        item.kind == .pr
          ? String(localized: "tasks.projectDetailDrawer.pullRequest", defaultValue: "Pull request")
          : String(localized: "tasks.projectDetailDrawer.issue", defaultValue: "Issue")),
      .detail(String(localized: "tasks.options.repository", defaultValue: "Repository"), item.repoName),
    ]
    let labels = details?.labels ?? item.labels
    if !labels.isEmpty {
      detailRows.append(
        .detail(String(localized: "tasks.itemFieldEditors.labels", defaultValue: "Labels"), labels.joined(separator: ", ")))
    }
    if let assignees = details?.assignees, !assignees.isEmpty {
      detailRows.append(
        .detail(
          String(localized: "tasks.itemDetailContent.assignees", defaultValue: "Assignees"),
          assignees.joined(separator: ", ")))
    }
    sections = [
      (nil, [.header]),
      (String(localized: "tasks.itemDetailContent.details", defaultValue: "Details"), detailRows),
    ]
    let description = String(localized: "tasks.itemDetailContent.description", defaultValue: "Description")
    let discussion = String(localized: "tasks.itemDetailContent.discussion", defaultValue: "Discussion")
    if let details {
      let body = Self.plainText(details.body)
      sections.append(
        (
          description,
          [
            body.isEmpty
              ? .placeholder(String(localized: "tasks.itemReviewSections.noDescription", defaultValue: "No description."))
              : .body(body)
          ]
        ))
      sections.append(
        (
          details.comments.isEmpty ? discussion : "\(discussion) \(details.comments.count)",
          details.comments.isEmpty
            ? [.placeholder(String(localized: "tasks.itemDetailContent.noComments", defaultValue: "No comments."))]
            : details.comments.map(Row.comment)
        ))
    } else if loading {
      sections.append(
        (description, [.placeholder(String(localized: "tasks.itemDetailContent.loading", defaultValue: "Loading details…"))]))
    } else if let loadError {
      sections.append((description, [.placeholder(loadError)]))
    }
    if let url = URL(string: item.url), !item.url.isEmpty {
      sections.append(
        (
          nil,
          [
            .action(
              String(localized: "tasks.projectDetailDrawer.openInGitHub", defaultValue: "Open in GitHub"), .externalLink
            ) { UIApplication.shared.open(url) },
            .action(String(localized: "tasks.itemActions.copyGitHubLink", defaultValue: "Copy GitHub link"), .copy) {
              [item] in UIPasteboard.general.string = item.url
            },
          ]
        ))
    }
    tableView.reloadData()
  }

  /// A body as text: HTML comments (issue templates' hints) dropped, Markdown left as written.
  static func plainText(_ body: String) -> String {
    body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Create workspace

  /// The workspace name the desktop seeds for a linked item: its title as a slug.
  private var suggestedName: String {
    let slug = item.title.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let trimmed = String(slug.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "\(item.kind == .pr ? "pr" : "issue")-\(item.number)" : trimmed
  }

  private func promptCreateWorkspace() {
    guard !creating else { return }
    let alert = UIAlertController(
      title: String(localized: "tasks.workspaceCreateDrawer.title", defaultValue: "Create Workspace"),
      message: "\(item.repoName) #\(item.number)", preferredStyle: .alert)
    alert.addTextField { [suggestedName] field in
      field.text = suggestedName
      field.placeholder = String(localized: "tasks.workspaceCreateDrawer.workspaceName", defaultValue: "Workspace Name")
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    let create = UIAlertAction(
      title: String(localized: "tasks.projectDetailDrawer.createWorkspace", defaultValue: "Create Workspace"),
      style: .default
    ) { [weak self, weak alert] _ in
      let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
      self?.createWorkspace(name: name)
    }
    alert.addAction(create)
    alert.preferredAction = create
    present(alert, animated: true)
  }

  private func createWorkspace(name: String) {
    guard !name.isEmpty else {
      showError(String(localized: "tasks.workspaceCreateProjection.nameRequired", defaultValue: "Name is required."))
      return
    }
    guard name.count <= 80 else {
      showError(
        String(localized: "tasks.workspaceCreateProjection.nameTooLong", defaultValue: "Name must be 80 characters or fewer."))
      return
    }
    creating = true
    navigationItem.rightBarButtonItem?.isEnabled = false
    navigationItem.rightBarButtonItem?.title = String(localized: "tasks.itemActions.creating", defaultValue: "Creating...")
    let session = session
    let item = item
    Task {
      defer {
        creating = false
        navigationItem.rightBarButtonItem?.isEnabled = true
        navigationItem.rightBarButtonItem?.title = String(
          localized: "tasks.projectDetailDrawer.createWorkspace", defaultValue: "Create Workspace")
      }
      do {
        let id = try await session.api.createWorktree(for: item, name: name, displayName: item.title)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await session.refresh()
        if let id, let onOpenWorkspace { onOpenWorkspace(session, id) }
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        showError(TasksViewController.message(error))
      }
    }
  }

  private func showError(_ message: String) {
    let alert = UIAlertController(
      title: String(localized: "tasks.worktreeCreateRetry.createFailed", defaultValue: "Failed to create workspace"),
      message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
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
      let glyph = TaskStateGlyph(item)
      var content = UIListContentConfiguration.subtitleCell()
      content.text = item.title
      content.textProperties.font = .systemFont(ofSize: Typography.titleSize, weight: .semibold)
      content.textProperties.numberOfLines = 0
      var meta = [glyph.label]
      if let author = item.author, !author.isEmpty { meta.append(author) }
      if let date = item.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) {
        meta.append(age)
      }
      content.secondaryText = meta.joined(separator: " · ")
      content.secondaryTextProperties.color = Palette.textSecondary
      content.textToSecondaryTextVerticalPadding = Spacing.xs
      content.image = glyph.icon.image(size: 20)
      content.imageProperties.tintColor = glyph.color
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
    case .comment(let comment):
      var content = UIListContentConfiguration.subtitleCell()
      var heading = comment.author
      if let created = comment.createdAt.flatMap(Self.date),
        let age = RelativeTime.short(created.timeIntervalSince1970 * 1000)
      {
        heading += " · \(age)"
      }
      content.text = heading
      content.textProperties.font = .systemFont(ofSize: 13, weight: .semibold)
      content.textProperties.color = Palette.textSecondary
      content.secondaryText = Self.plainText(comment.body)
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
    if case .action(_, _, let run) = sections[indexPath.section].rows[indexPath.row] { run() }
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
  ) -> UIContextMenuConfiguration? {
    let text: String
    switch sections[indexPath.section].rows[indexPath.row] {
    case .body(let body): text = body
    case .comment(let comment): text = comment.body
    case .header: text = item.title
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

  private static func date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
