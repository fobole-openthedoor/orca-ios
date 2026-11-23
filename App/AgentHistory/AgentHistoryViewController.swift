import OrcaCore
import UIKit

/// Agent Session History (agent-history/MobileAgentSessionHistoryPanel.tsx): past agent conversations the
/// desktop found on disk, scoped to this workspace, its project or everything, grouped by folder, with search,
/// sort and an agent filter. A session opens its details: the recent messages and Continue in CLI.
final class AgentHistoryViewController: UITableViewController, UISearchResultsUpdating {
  /// Called with a session's workspace id and native chat session id when it can open as a chat in Orca.
  var onOpenChat: ((_ worktreeId: String, _ sessionId: String) -> Void)?

  enum Scope: Int { case workspace, project, all }
  enum Sort { case updated, created }

  private let session: HostSession
  private let worktreeId: String?
  private var scope: Scope
  private var sort: Sort = .updated
  /// Nil: every agent.
  private var agents: Set<String>?
  private var query = ""
  private var listing: AgentHistoryListing?
  private var loadError: String?
  private var unsupported = false
  private var loading = false
  private var sections: [(title: String, sessions: [AgentHistorySession])] = []
  private let scopeControl = UISegmentedControl()
  private var menuItem: UIBarButtonItem!

  init(session: HostSession, worktreeId: String?) {
    self.session = session
    self.worktreeId = worktreeId
    scope = worktreeId == nil ? .all : .workspace
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var worktree: Worktree? { worktreeId.flatMap { session.worktree(id: $0) } }

  /// Folders the scope covers: the workspace's own, or every workspace of its project and the project's root.
  private var scopePaths: [String] {
    guard let worktree else { return [] }
    switch scope {
    case .workspace: return [worktree.path]
    case .project:
      var paths = session.worktrees.filter { $0.repoId == worktree.repoId }.map(\.path)
      if let root = session.repo(id: worktree.repoId)?.path { paths.append(root) }
      return Array(Set(paths)).sorted()
    case .all: return []
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "agentHistory.panel.title", defaultValue: "Agent Session History")
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.refreshControl = UIRefreshControl(
      frame: .zero, primaryAction: UIAction { [weak self] _ in self?.load(force: true) })
    tableView.refreshControl?.accessibilityLabel = String(
      localized: "agentHistory.panel.refreshSessions", defaultValue: "Refresh agent sessions")

    let search = UISearchController(searchResultsController: nil)
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = String(
      localized: "agentHistory.panel.placeholder", defaultValue: "Search sessions, repo:, path:")
    search.searchBar.autocapitalizationType = .none
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = false

    menuItem = UIBarButtonItem(image: Lucide.slidersHorizontal.image(size: 20), style: .plain, target: nil, action: nil)
    menuItem.accessibilityLabel = String(localized: "agentHistory.filterSheet.title", defaultValue: "Filter & sort")
    navigationItem.rightBarButtonItem = menuItem

    if worktreeId != nil {
      for (index, title) in [
        String(localized: "agentHistory.panel.workspace", defaultValue: "Workspace"),
        String(localized: "agentHistory.panel.project", defaultValue: "Project"),
        String(localized: "agentHistory.panel.all", defaultValue: "All"),
      ].enumerated() {
        scopeControl.insertSegment(withTitle: title, at: index, animated: false)
      }
      scopeControl.selectedSegmentIndex = scope.rawValue
      scopeControl.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          self.scope = Scope(rawValue: self.scopeControl.selectedSegmentIndex) ?? .all
          self.load()
        }, for: .valueChanged)
      scopeControl.translatesAutoresizingMaskIntoConstraints = false
      let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 48))
      header.addSubview(scopeControl)
      NSLayoutConstraint.activate([
        scopeControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Spacing.lg + 4),
        scopeControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -(Spacing.lg + 4)),
        scopeControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      ])
      tableView.tableHeaderView = header
    }
    rebuildMenu()
    load()
  }

  override func updateProperties() {
    super.updateProperties()
    navigationItem.subtitle = worktree?.displayName ?? session.name
    if listing == nil, !loading, session.connectionState == .connected, loadError == nil { load() }
  }

  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text ?? ""
    rebuild()
  }

  private func load(force: Bool = false) {
    guard session.connectionState == .connected else {
      tableView.refreshControl?.endRefreshing()
      showState()
      return
    }
    if let status = session.status, !status.capabilities.isEmpty,
      !status.capabilities.contains(HostAPI.agentHistoryCapability)
    {
      unsupported = true
      tableView.refreshControl?.endRefreshing()
      showState()
      return
    }
    loading = true
    let api = session.api
    let paths = scopePaths
    let scopeOnly = scope != .all
    showState()
    Task {
      do {
        listing = try await api.agentHistory(scopePaths: paths, scopeOnly: scopeOnly, force: force)
        loadError = nil
      } catch {
        loadError = TasksViewController.message(error)
      }
      loading = false
      tableView.refreshControl?.endRefreshing()
      rebuildMenu()
      rebuild()
    }
  }

  // MARK: Filtering

  private func inScope(_ item: AgentHistorySession, paths: [String]) -> Bool {
    guard scope != .all, !paths.isEmpty else { return true }
    let cwds = ([item.cwd].compactMap { $0 } + item.cwdAliases).map(Self.normalized)
    return cwds.contains { cwd in
      paths.map(Self.normalized).contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
    }
  }

  private static func normalized(_ path: String) -> String {
    var path = path.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// The folder heading: the last two parts of the session's folder.
  static func folderLabel(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return String(localized: "common.unknown", defaultValue: "Unknown") }
    let parts = normalized(path).split(separator: "/")
    return parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : parts.first.map(String.init) ?? path
  }

  /// `repo:` matches the folder name, `path:` the folder; other words match the title, messages, branch or agent.
  private func matches(_ item: AgentHistorySession, tokens: [String]) -> Bool {
    tokens.allSatisfy { token in
      if token.hasPrefix("repo:") {
        let value = String(token.dropFirst(5))
        return value.isEmpty || Self.folderLabel(item.cwd).lowercased().contains(value)
      }
      if token.hasPrefix("path:") {
        let value = String(token.dropFirst(5))
        return value.isEmpty || (item.cwd ?? "").lowercased().contains(value)
      }
      let fields = [item.title, item.branch ?? "", item.agentLabel, item.cwd ?? ""] + item.previewMessages.map(\.text)
      return fields.contains { $0.lowercased().contains(token) }
    }
  }

  private func rebuild() {
    let paths = scopePaths
    let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let shown = (listing?.sessions ?? []).filter {
      !$0.isEmpty && !$0.isSubagent && (agents?.contains($0.agent) ?? true) && inScope($0, paths: paths)
        && matches($0, tokens: tokens)
    }.sorted {
      let a = sort == .updated ? $0.updatedDate : $0.createdDate
      let b = sort == .updated ? $1.updatedDate : $1.createdDate
      return (a ?? .distantPast) > (b ?? .distantPast)
    }
    var order: [String] = []
    var groups: [String: [AgentHistorySession]] = [:]
    for item in shown {
      let key = item.cwd.map(Self.normalized) ?? ""
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(item)
    }
    sections = order.map { (Self.folderLabel($0.isEmpty ? nil : $0), groups[$0] ?? []) }
    tableView.reloadData()
    showState()
  }

  private func showState() {
    var config: UIContentUnavailableConfiguration?
    if unsupported {
      config = .empty()
      config?.text = String(localized: "agentHistory.panel.unavailable", defaultValue: "Agent Session History Unavailable")
      config?.secondaryText = String(
        localized: "agentHistory.panel.updateHost", defaultValue: "Update Orca on this host to browse agent session history.")
    } else if session.connectionState != .connected && listing == nil {
      config = .empty()
      config?.image = Lucide.wifiOff.image(size: 34, strokeWidth: 1.6)
      config?.text = String(localized: "agentHistory.useAgentHistoryState.waitingForHost", defaultValue: "Waiting for host…")
    } else if loading && listing == nil {
      config = .loading()
      config?.text = String(localized: "agentHistory.panel.loading", defaultValue: "Loading agent sessions…")
    } else if let loadError, listing == nil {
      config = .empty()
      config?.image = Lucide.circleAlert.image(size: 34, strokeWidth: 1.6)
      config?.text = String(localized: "agentHistory.useAgentHistoryState.loadFailed", defaultValue: "Unable to load agent sessions")
      config?.secondaryText = loadError
      var retry = UIButton.Configuration.glass()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config?.button = retry
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load(force: true) }
    } else if listing != nil, sections.isEmpty {
      config = .empty()
      config?.image = Lucide.history.image(size: 34, strokeWidth: 1.6)
      config?.text = String(localized: "agentHistory.panel.noSessions", defaultValue: "No agent sessions")
      config?.secondaryText =
        !query.trimmingCharacters(in: .whitespaces).isEmpty
        ? String(localized: "agentHistory.panel.noSearchResults", defaultValue: "No sessions match your search.")
        : scope != .all
          ? String(localized: "agentHistory.panel.emptyScope", defaultValue: "No past agent sessions in this scope.") : nil
      if agents != nil {
        var all = UIButton.Configuration.glass()
        all.title = String(localized: "agentHistory.panel.showAllAgents", defaultValue: "Show all agents")
        config?.button = all
        config?.buttonProperties.primaryAction = UIAction { [weak self] _ in
          self?.agents = nil
          self?.rebuildMenu()
          self?.rebuild()
        }
      }
    }
    config?.imageProperties.tintColor = Palette.textMuted
    contentUnavailableConfiguration = config
  }

  private func rebuildMenu() {
    let sortMenu = UIMenu(
      title: String(localized: "agentHistory.filterSheet.sortBy", defaultValue: "Sort by"), options: .displayInline,
      children: [
        (Sort.updated, String(localized: "agentHistory.viewControls.lastUpdated", defaultValue: "Last updated")),
        (Sort.created, String(localized: "agentHistory.viewControls.created", defaultValue: "Created")),
      ].map { value, title in
        UIAction(title: title, state: sort == value ? .on : .off) { [weak self] _ in
          self?.sort = value
          self?.rebuildMenu()
          self?.rebuild()
        }
      })
    let present = Array(Set((listing?.sessions ?? []).map(\.agent))).sorted {
      (AgentHistorySession.agentLabels[$0] ?? $0) < (AgentHistorySession.agentLabels[$1] ?? $1)
    }
    var agentActions: [UIMenuElement] = [
      UIAction(
        title: String(localized: "agentHistory.viewControls.allAgents", defaultValue: "All agents"),
        state: agents == nil ? .on : .off
      ) { [weak self] _ in
        self?.agents = nil
        self?.rebuildMenu()
        self?.rebuild()
      }
    ]
    agentActions += present.map { agent in
      let action = UIAction(
        title: AgentHistorySession.agentLabels[agent] ?? agent,
        image: AgentMark.icon(for: agent)?.image(size: 18) ?? Lucide.squareTerminal.image(size: 18),
        state: agents?.contains(agent) == true ? .on : .off
      ) { [weak self] _ in
        guard let self else { return }
        var picked = self.agents ?? []
        if picked.contains(agent) { picked.remove(agent) } else { picked.insert(agent) }
        self.agents = picked.isEmpty || picked.count == present.count ? nil : picked
        self.rebuildMenu()
        self.rebuild()
      }
      return action
    }
    let agentMenu = UIMenu(
      title: String(localized: "agentHistory.viewControls.agents", defaultValue: "Agents"),
      subtitle: agents.map { $0.compactMap { AgentHistorySession.agentLabels[$0] ?? $0 }.sorted().joined(separator: ", ") }
        ?? String(localized: "agentHistory.viewControls.allAgents", defaultValue: "All agents"),
      image: Lucide.bot.image(size: 18), children: agentActions)
    menuItem.menu = UIMenu(children: [sortMenu, UIMenu(options: .displayInline, children: [agentMenu])])
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].sessions.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].title
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    guard section == sections.count - 1, let skipped = listing?.skippedCount, skipped > 0 else { return nil }
    return String(localized: "agentHistory.panel.skipped", defaultValue: "\(skipped) transcripts skipped")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = sections[indexPath.section].sessions[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    cell.accessoryType = .disclosureIndicator
    cell.contentConfiguration = Self.rowContent(item, currentPath: worktree?.path, showsCurrent: scope != .workspace)
    return cell
  }

  /// A session's row: agent mark, title, then agent · messages · age and the newest message.
  static func rowContent(_ item: AgentHistorySession, currentPath: String?, showsCurrent: Bool)
    -> UIListContentConfiguration
  {
    var content = UIListContentConfiguration.subtitleCell()
    let title =
      item.title.isEmpty
      ? String(localized: "agentHistory.sessionCard.untitledSession", defaultValue: "Untitled session") : item.title
    content.text = title
    content.textProperties.font = .systemFont(ofSize: 16, weight: .medium)
    content.textProperties.numberOfLines = 2
    var meta = [item.agentLabel]
    if item.messageCount > 0 {
      meta.append(
        String(
          localized: "agentHistory.sessionHistoryList.messages", defaultValue: "\(item.messageCount) messages"))
    }
    if let date = item.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) { meta.append(age) }
    if showsCurrent, let currentPath, let cwd = item.cwd,
      cwd == currentPath || cwd.hasPrefix(currentPath.hasSuffix("/") ? currentPath : currentPath + "/")
    {
      meta.append(String(localized: "agentHistory.sessionHistoryList.currentWorktree", defaultValue: "current worktree"))
    }
    var secondary = meta.joined(separator: " · ")
    if let turn = item.latestTurn {
      let line = turn.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
      secondary += "\n" + String(line.prefix(200))
    }
    content.secondaryText = secondary
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.font = .systemFont(ofSize: 13)
    content.secondaryTextProperties.numberOfLines = 3
    content.textToSecondaryTextVerticalPadding = Spacing.xxs
    if let mark = AgentMark.icon(for: item.agent) {
      content.image = mark.image(size: 18)
      content.imageProperties.tintColor = Palette.textPrimary
    } else {
      content.image = Lucide.squareTerminal.image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
    }
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    return content
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    let item = sections[indexPath.section].sessions[indexPath.row]
    let detail = AgentHistoryDetailViewController(item: item)
    detail.onOpenChat = onOpenChat
    navigationController?.pushViewController(detail, animated: true)
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
  ) -> UIContextMenuConfiguration? {
    let item = sections[indexPath.section].sessions[indexPath.row]
    guard !item.resumeCommand.isEmpty else { return nil }
    return UIContextMenuConfiguration(actionProvider: { _ in
      UIMenu(children: [
        UIAction(
          title: String(localized: "agentHistory.sessionHistoryList.continueInCli", defaultValue: "Continue in CLI"),
          subtitle: item.resumeCommand, image: Lucide.copy.image(size: 18)
        ) { _ in UIPasteboard.general.string = item.resumeCommand }
      ])
    })
  }
}

/// One past session: where and when it ran, its recent messages, and the ways to pick it up again.
final class AgentHistoryDetailViewController: UITableViewController {
  var onOpenChat: ((_ worktreeId: String, _ sessionId: String) -> Void)?

  private enum Row {
    case header
    case detail(String, String)
    case message(AgentHistorySession.Message)
    case openChat
    case copyCommand
  }

  private let item: AgentHistorySession
  private var sections: [(title: String?, footer: String?, rows: [Row])] = []

  init(item: AgentHistorySession) {
    self.item = item
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = item.agentLabel
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")

    var details: [Row] = [
      .detail(String(localized: "session.agentChildRow.agent", defaultValue: "Agent"), item.agentLabel)
    ]
    if let cwd = item.cwd { details.append(.detail(String(localized: "components.worktreeListRow.folder", defaultValue: "Folder"), cwd)) }
    if let branch = item.branch, !branch.isEmpty {
      details.append(.detail(String(localized: "session.diffReviewScreenModel.branch", defaultValue: "Branch"), branch))
    }
    if let model = item.model, !model.isEmpty {
      details.append(.detail(String(localized: "chat.sessionOptionCopy.model", defaultValue: "Model"), model))
    }
    if let updated = item.updatedDate {
      details.append(
        .detail(
          String(localized: "tasks.options.updated", defaultValue: "Updated"),
          updated.formatted(date: .abbreviated, time: .shortened)))
    }
    if item.createdAt != nil, let created = item.createdDate {
      details.append(
        .detail(
          String(localized: "agentHistory.viewControls.created", defaultValue: "Created"),
          created.formatted(date: .abbreviated, time: .shortened)))
    }
    var actions: [Row] = []
    if item.structuredSessionId != nil, item.structuredWorkspaceId != nil {
      actions.append(.openChat)
    }
    if !item.resumeCommand.isEmpty { actions.append(.copyCommand) }
    let messages = item.previewMessages.filter {
      ($0.role == "user" || $0.role == "assistant") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    sections = [(nil, nil, [.header])]
    if !actions.isEmpty {
      sections.append(
        (nil, item.sessionId.isEmpty
          ? String(localized: "agentHistory.panel.missingResumeId", defaultValue: "This session is missing a resume id.")
          : nil, actions))
    }
    sections.append((String(localized: "common.details", defaultValue: "Details"), nil, details))
    if !messages.isEmpty {
      sections.append(
        (
          String(localized: "orcaios.agentHistory.recentMessages", defaultValue: "Recent messages"), nil,
          messages.suffix(12).map(Row.message)
        ))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Open chat shows only when the caller can open one.
    if onOpenChat == nil {
      sections = sections.map { ($0.title, $0.footer, $0.rows.filter { if case .openChat = $0 { false } else { true } }) }
        .filter { !$0.rows.isEmpty }
    }
    tableView.reloadData()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].title
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    sections[section].footer
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    cell.selectionStyle = .none
    switch sections[indexPath.section].rows[indexPath.row] {
    case .header:
      var content = AgentHistoryViewController.rowContent(item, currentPath: nil, showsCurrent: false)
      content.textProperties.font = .systemFont(ofSize: Typography.titleSize, weight: .semibold)
      content.textProperties.numberOfLines = 0
      content.secondaryText = content.secondaryText?.components(separatedBy: "\n").first
      cell.contentConfiguration = content
    case .detail(let title, let value):
      var content = UIListContentConfiguration.valueCell()
      content.text = title
      content.secondaryText = value
      content.secondaryTextProperties.numberOfLines = 3
      content.prefersSideBySideTextAndSecondaryText = value.count < 40
      cell.contentConfiguration = content
    case .message(let message):
      var content = UIListContentConfiguration.subtitleCell()
      content.text =
        message.role == "user"
        ? String(localized: "agentHistory.sessionHistoryList.you", defaultValue: "You") : item.agentLabel
      content.textProperties.font = .systemFont(ofSize: 13, weight: .semibold)
      content.textProperties.color = Palette.textSecondary
      content.secondaryText = String(message.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
      content.secondaryTextProperties.font = .systemFont(ofSize: 15)
      content.secondaryTextProperties.color = Palette.textPrimary
      content.secondaryTextProperties.numberOfLines = 0
      content.textToSecondaryTextVerticalPadding = Spacing.xs
      cell.contentConfiguration = content
    case .openChat:
      var content = UIListContentConfiguration.cell()
      content.text = String(localized: "agentHistory.sessionHistoryList.resumeSession", defaultValue: "Resume agent session")
      content.textProperties.color = Palette.accentBlue
      content.image = Lucide.messageSquare.image(size: 18)
      content.imageProperties.tintColor = Palette.accentBlue
      cell.contentConfiguration = content
      cell.selectionStyle = .default
    case .copyCommand:
      var content = UIListContentConfiguration.subtitleCell()
      content.text = String(localized: "agentHistory.sessionHistoryList.continueInCli", defaultValue: "Continue in CLI")
      content.textProperties.color = Palette.accentBlue
      content.secondaryText = item.resumeCommand
      content.secondaryTextProperties.font = Typography.mono(12)
      content.secondaryTextProperties.color = Palette.textSecondary
      content.secondaryTextProperties.numberOfLines = 3
      content.image = Lucide.squareTerminal.image(size: 18)
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
    case .openChat:
      if let worktreeId = item.structuredWorkspaceId, let sessionId = item.structuredSessionId {
        onOpenChat?(worktreeId, sessionId)
      }
    case .copyCommand:
      UIPasteboard.general.string = item.resumeCommand
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      guard let cell = tableView.cellForRow(at: indexPath),
        var content = cell.contentConfiguration as? UIListContentConfiguration
      else { return }
      content.text = String(localized: "common.copied", defaultValue: "Copied")
      cell.contentConfiguration = content
    default: break
    }
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
  ) -> UIContextMenuConfiguration? {
    let text: String
    switch sections[indexPath.section].rows[indexPath.row] {
    case .detail(_, let value): text = value
    case .message(let message): text = message.text
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
}
