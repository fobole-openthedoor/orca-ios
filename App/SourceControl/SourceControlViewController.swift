import OrcaCore
import UIKit

/// Source Control for one workspace (source-control/MobileSourceControlPanel.tsx): the branch and how it stands
/// against its upstream, the changed files under Conflicts, Uncommitted and Staged, a commit message, and the
/// primary git action of the moment (commit, stage all, push, pull, sync or publish) in the toolbar.
final class SourceControlViewController: UITableViewController, UITextViewDelegate {
  private enum Section {
    case branch
    case message
    case files(id: String, title: String, entries: [GitStatusEntry])
    case empty
  }

  private enum Primary {
    case commit(Int), stageAll, push(Int), pull(Int), sync, publish, none
  }

  private let session: HostSession
  private let worktreeId: String
  private var status: GitStatus?
  private var sections: [Section] = []
  private var loadError: String?
  private var loading = false
  private var busy = false
  private var commitMessage = ""
  private var loadTask: Task<Void, Never>?
  private var foregroundObserver: NSObjectProtocol?

  init(session: HostSession, worktreeId: String) {
    self.session = session
    self.worktreeId = worktreeId
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    loadTask?.cancel()
    if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
  }

  private var api: HostAPI { session.api }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "sourceControl.header.title", defaultValue: "Source Control")
    navigationItem.subtitle = session.worktree(id: worktreeId)?.displayName
    navigationItem.largeTitleDisplayMode = .never
    tableView.register(GitFileCell.self, forCellReuseIdentifier: GitFileCell.reuseIdentifier)
    tableView.register(CommitMessageCell.self, forCellReuseIdentifier: CommitMessageCell.reuseIdentifier)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.register(ActionHeaderView.self, forHeaderFooterViewReuseIdentifier: ActionHeaderView.reuseIdentifier)
    tableView.keyboardDismissMode = .interactive
    let refresh = UIRefreshControl()
    refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
    refreshControl = refresh
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
    updateChrome()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setToolbarHidden(false, animated: animated)
    reload()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // A pushed diff sets the toolbar for itself; only leaving this screen hides it.
    if isMovingFromParent || navigationController?.isBeingDismissed == true {
      navigationController?.setToolbarHidden(true, animated: animated)
    }
  }

  // MARK: Loading

  private func reload() {
    loadTask?.cancel()
    if status == nil, loadError == nil {
      loading = true
      contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
    }
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let status = try await api.gitStatus(worktreeId: worktreeId)
        guard !Task.isCancelled else { return }
        self.status = status
        loadError = nil
      } catch {
        guard !Task.isCancelled else { return }
        loadError = Self.message(error)
      }
      loading = false
      refreshControl?.endRefreshing()
      rebuild()
    }
  }

  private static func message(_ error: Error) -> String {
    (error as? RPCError)?.message ?? error.localizedDescription
  }

  private func rebuild() {
    if let loadError, status == nil {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = Lucide.gitBranch.image(size: 32)
      config.text = String(localized: "sourceControl.loaders.loadFailed", defaultValue: "Unable to load source control")
      config.secondaryText = loadError
      var retry = UIButton.Configuration.gray()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config.button = retry
      config.buttonProperties.primaryAction = UIAction { [weak self] _ in
        self?.loadError = nil
        self?.reload()
      }
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
    sections = []
    if let status {
      sections.append(.branch)
      let known = status.entries
      let conflicts = known.filter(\.isConflict).sorted { $0.path < $1.path }
      let rest = known.filter { !$0.isConflict }
      let uncommitted = rest.filter { $0.area != .staged }.sorted { $0.path < $1.path }
      let staged = rest.filter { $0.area == .staged }.sorted { $0.path < $1.path }
      if known.isEmpty {
        sections.append(.empty)
      } else {
        sections.append(.message)
      }
      if !conflicts.isEmpty {
        sections.append(
          .files(
            id: "conflicts", title: String(localized: "sourceControl.gitStatus.conflicts", defaultValue: "Conflicts"),
            entries: conflicts))
      }
      if !uncommitted.isEmpty {
        sections.append(
          .files(
            id: "unstaged", title: String(localized: "sourceControl.gitStatus.uncommitted", defaultValue: "Uncommitted"),
            entries: uncommitted))
      }
      if !staged.isEmpty {
        sections.append(
          .files(
            id: "staged", title: String(localized: "sourceControl.gitStatus.staged", defaultValue: "Staged"),
            entries: staged))
      }
    }
    tableView.reloadData()
    updateChrome()
  }

  // MARK: Facts

  private var entries: [GitStatusEntry] { status?.entries ?? [] }
  private var stagedCount: Int { entries.filter { $0.area == .staged }.count }
  private var stageablePaths: [String] { entries.filter(\.canStage).map(\.path) }
  private var unstageablePaths: [String] { entries.filter(\.canUnstage).map(\.path) }
  private var hasUnresolvedConflicts: Bool { entries.contains { $0.conflictStatus == "unresolved" } }
  private var hasMessage: Bool { !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private var primary: Primary {
    guard let status else { return .none }
    if hasUnresolvedConflicts { return .commit(stagedCount) }
    if stagedCount > 0 { return .commit(stagedCount) }
    if !stageablePaths.isEmpty { return .stageAll }
    guard status.branch != nil else { return .none }
    guard let upstream = status.upstream, upstream.hasUpstream else { return .publish }
    if upstream.ahead > 0, upstream.behind > 0 { return .sync }
    if upstream.ahead > 0 { return .push(upstream.ahead) }
    if upstream.behind > 0 { return .pull(upstream.behind) }
    return .none
  }

  private var syncSummary: String {
    guard let status else { return "" }
    switch status.conflictOperation {
    case "merge": return String(localized: "sourceControl.changesHeader.merging", defaultValue: "Merging")
    case "rebase": return String(localized: "sourceControl.changesHeader.rebasing", defaultValue: "Rebasing")
    case "cherry-pick":
      return String(localized: "sourceControl.changesHeader.cherryPicking", defaultValue: "Cherry-picking")
    default: break
    }
    guard status.branch != nil else { return "" }
    guard let upstream = status.upstream, upstream.hasUpstream else {
      return String(localized: "sourceControl.changesHeader.notPublished", defaultValue: "Not published")
    }
    if upstream.ahead > 0, upstream.behind > 0 {
      return String(
        format: String(localized: "sourceControl.state.syncStatus", defaultValue: "%1$@ ahead, %2$@ behind"),
        "\(upstream.ahead)", "\(upstream.behind)")
    }
    if upstream.ahead > 0 {
      return String(
        format: String(localized: "sourceControl.changesHeader.notPushed", defaultValue: "%1$lld not pushed"),
        upstream.ahead)
    }
    if upstream.behind > 0 {
      return String(
        format: String(localized: "sourceControl.changesHeader.behind", defaultValue: "%1$lld behind"), upstream.behind)
    }
    return String(localized: "sourceControl.changesHeader.upToDate", defaultValue: "Up to date")
  }

  // MARK: Chrome

  private func updateChrome() {
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: Lucide.ellipsis.image(size: 20), menu: actionsMenu())
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "sourceControl.header.moreActions", defaultValue: "More source control actions")
    navigationItem.rightBarButtonItem?.isEnabled = status != nil && !busy
    toolbarItems = [.flexibleSpace(), primaryItem()]
  }

  private func primaryItem() -> UIBarButtonItem {
    if busy {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      return UIBarButtonItem(customView: spinner)
    }
    let title: String
    var enabled = true
    var action: () -> Void = {}
    switch primary {
    case .commit(let count):
      title =
        count > 0
        ? String.localizedStringWithFormat(
          String(localized: "sourceControl.primaryAction.commitFiles", defaultValue: "Commit %lld files"), count)
        : String(localized: "sourceControl.primaryAction.commit", defaultValue: "Commit")
      enabled = count > 0 && hasMessage && !hasUnresolvedConflicts
      action = { [weak self] in self?.commit() }
    case .stageAll:
      title = String(localized: "sourceControl.primaryAction.stageAll", defaultValue: "Stage all")
      action = { [weak self] in self?.stageAll() }
    case .push(let count):
      title = String.localizedStringWithFormat(
        String(localized: "sourceControl.primaryAction.pushCommits", defaultValue: "Push %lld commits"), count)
      action = { [weak self] in self?.run { try await $0.gitPush(worktreeId: $1) } }
    case .pull(let count):
      title = String.localizedStringWithFormat(
        String(localized: "sourceControl.primaryAction.pullCommits", defaultValue: "Pull %lld commits"), count)
      action = { [weak self] in self?.run { try await $0.gitPull(worktreeId: $1) } }
    case .sync:
      title = String(localized: "sourceControl.primaryAction.sync", defaultValue: "Sync")
      action = { [weak self] in self?.sync() }
    case .publish:
      title = String(localized: "sourceControl.primaryAction.publishBranch", defaultValue: "Publish Branch")
      action = { [weak self] in self?.run { try await $0.gitPush(worktreeId: $1, publish: true) } }
    case .none:
      title = String(localized: "sourceControl.primaryAction.commit", defaultValue: "Commit")
      enabled = false
    }
    let item = UIBarButtonItem(title: title, style: .prominent, target: nil, action: nil)
    item.primaryAction = UIAction(title: title) { _ in action() }
    item.isEnabled = enabled && status != nil
    return item
  }

  private func actionsMenu() -> UIMenu {
    let hasBranch = status?.branch != nil
    let published = status?.upstream?.hasUpstream == true
    var remote: [UIMenuElement] = []
    if hasBranch, !published {
      remote.append(
        UIAction(
          title: String(localized: "sourceControl.remoteDropdown.publishBranch", defaultValue: "Publish Branch"),
          image: Lucide.cloudUpload.image(size: 18)
        ) { [weak self] _ in self?.run { try await $0.gitPush(worktreeId: $1, publish: true) } })
    }
    remote += [
      UIAction(
        title: String(localized: "sourceControl.remoteDropdown.pull", defaultValue: "Pull"),
        image: Lucide.arrowDown.image(size: 18),
        attributes: hasBranch && published ? [] : .disabled
      ) { [weak self] _ in self?.run { try await $0.gitPull(worktreeId: $1) } },
      UIAction(
        title: String(localized: "sourceControl.remoteDropdown.push", defaultValue: "Push"),
        image: Lucide.arrowUp.image(size: 18),
        attributes: hasBranch && published ? [] : .disabled
      ) { [weak self] _ in self?.run { try await $0.gitPush(worktreeId: $1) } },
      UIAction(
        title: String(localized: "sourceControl.remoteDropdown.sync", defaultValue: "Sync"),
        image: Lucide.arrowUpDown.image(size: 18),
        attributes: hasBranch && published ? [] : .disabled
      ) { [weak self] _ in self?.sync() },
      UIAction(
        title: String(localized: "sourceControl.remoteDropdown.fetch", defaultValue: "Fetch"),
        subtitle: String(
          localized: "sourceControl.remoteDropdown.fetchTitle", defaultValue: "Fetch from remote without merging"),
        image: Lucide.download.image(size: 18)
      ) { [weak self] _ in self?.run { try await $0.gitFetch(worktreeId: $1) } },
    ]
    let staging: [UIMenuElement] = [
      UIAction(
        title: String(localized: "sourceControl.fileList.stageAll", defaultValue: "Stage all"),
        image: Lucide.plus.image(size: 18),
        attributes: stageablePaths.isEmpty ? .disabled : []
      ) { [weak self] _ in self?.stageAll() },
      UIAction(
        title: String(localized: "sourceControl.fileList.unstageAll", defaultValue: "Unstage all"),
        image: Lucide.minus.image(size: 18),
        attributes: unstageablePaths.isEmpty ? .disabled : []
      ) { [weak self] _ in self?.unstageAll() },
    ]
    let refresh = UIAction(
      title: String(localized: "common.refresh", defaultValue: "Refresh"), image: Lucide.refreshCw.image(size: 18)
    ) { [weak self] _ in self?.reload() }
    return UIMenu(children: [
      UIMenu(options: .displayInline, children: remote),
      UIMenu(options: .displayInline, children: staging),
      UIMenu(options: .displayInline, children: [refresh]),
    ])
  }

  // MARK: Actions

  /// Runs one git call with the screen busy, then reads status again; a failure shows the host's message.
  private func run(
    failureTitle: String? = nil, _ body: @escaping (HostAPI, String) async throws -> Void
  ) {
    guard !busy else { return }
    busy = true
    updateChrome()
    let api = api
    let worktreeId = worktreeId
    Task { [weak self] in
      do {
        try await body(api, worktreeId)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        self?.showFailure(
          failureTitle
            ?? String(localized: "sourceControl.commitRunners.actionFailed", defaultValue: "Source control action failed"),
          Self.message(error))
      }
      guard let self else { return }
      busy = false
      reload()
    }
  }

  private func showFailure(_ title: String, _ message: String?) {
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  private func stageAll() {
    let paths = stageablePaths
    guard !paths.isEmpty else { return }
    run { try await $0.gitStage(worktreeId: $1, paths: paths) }
  }

  private func unstageAll() {
    let paths = unstageablePaths
    guard !paths.isEmpty else { return }
    run { try await $0.gitUnstage(worktreeId: $1, paths: paths) }
  }

  private func sync() {
    run {
      try await $0.gitPull(worktreeId: $1)
      try await $0.gitPush(worktreeId: $1)
    }
  }

  private func commit() {
    let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, stagedCount > 0 else { return }
    view.endEditing(true)
    let failed = String(localized: "sourceControl.commitRunners.commitFailed", defaultValue: "Commit failed")
    run(failureTitle: failed) { [weak self] api, worktreeId in
      let outcome = try await api.gitCommit(worktreeId: worktreeId, message: message)
      guard outcome.success else { throw CommitFailure(message: outcome.error ?? failed) }
      await MainActor.run {
        self?.commitMessage = ""
      }
    }
  }

  private struct CommitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private func stage(_ entry: GitStatusEntry) {
    run { try await $0.gitStage(worktreeId: $1, path: entry.path) }
  }

  private func unstage(_ entry: GitStatusEntry) {
    run { try await $0.gitUnstage(worktreeId: $1, path: entry.path) }
  }

  private func confirmDiscard(_ entry: GitStatusEntry, from view: UIView?) {
    let alert = UIAlertController(
      title: String(localized: "sourceControl.modals.discardTitle", defaultValue: "Discard Change"),
      message: String(
        format: String(
          localized: "sourceControl.modals.discardConfirmMessage",
          defaultValue: "Discard changes to \"%1$@\"? This cannot be undone."), entry.path),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(
        title: String(localized: "sourceControl.modals.discardButton", defaultValue: "Discard"), style: .destructive
      ) { [weak self] _ in self?.run { try await $0.gitDiscard(worktreeId: $1, path: entry.path) } })
    present(alert, animated: true)
  }

  private func open(_ entry: GitStatusEntry) {
    guard entry.canOpen else { return }
    navigationController?.pushViewController(
      GitDiffViewController(session: session, worktreeId: worktreeId, entry: entry), animated: true)
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch sections[section] {
    case .branch, .message, .empty: return 1
    case .files(_, _, let entries): return entries.count
    }
  }

  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard case .files(let id, let title, let entries) = sections[section] else { return nil }
    let header =
      tableView.dequeueReusableHeaderFooterView(withIdentifier: ActionHeaderView.reuseIdentifier) as? ActionHeaderView
    var action: UIAction?
    if id == "unstaged", entries.contains(where: \.canStage) {
      action = UIAction(title: String(localized: "sourceControl.fileList.stageAll", defaultValue: "Stage all")) {
        [weak self] _ in self?.stageAll()
      }
    } else if id == "staged", entries.contains(where: \.canUnstage) {
      action = UIAction(title: String(localized: "sourceControl.fileList.unstageAll", defaultValue: "Unstage all")) {
        [weak self] _ in self?.unstageAll()
      }
    }
    header?.configure(title: title, count: entries.count, action: busy ? nil : action)
    return header
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    guard case .branch = sections[section] else { return nil }
    return status?.readError ?? loadError
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch sections[indexPath.section] {
    case .branch:
      let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
      var content = UIListContentConfiguration.valueCell()
      content.image = Lucide.gitBranch.image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
      content.text =
        status?.branch ?? String(localized: "sourceControl.remoteDropdown.statusNoBranch", defaultValue: "No branch")
      content.textProperties.font = Typography.font(Typography.bodySize + 1, .semibold)
      content.secondaryText = syncSummary
      content.prefersSideBySideTextAndSecondaryText = true
      cell.contentConfiguration = content
      cell.selectionStyle = .none
      return cell
    case .message:
      let cell =
        tableView.dequeueReusableCell(withIdentifier: CommitMessageCell.reuseIdentifier, for: indexPath)
        as! CommitMessageCell
      cell.configure(text: commitMessage, enabled: stagedCount > 0 && !busy, delegate: self)
      return cell
    case .empty:
      let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
      var content = UIListContentConfiguration.subtitleCell()
      content.text = String(localized: "sourceControl.content.emptyTitle", defaultValue: "No local changes")
      content.secondaryText = String(localized: "sourceControl.content.emptyMessage", defaultValue: "Working tree is clean.")
      content.secondaryTextProperties.color = Palette.textSecondary
      content.textProperties.alignment = .center
      content.secondaryTextProperties.alignment = .center
      content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.xl, leading: 0, bottom: Spacing.xl, trailing: 0)
      cell.contentConfiguration = content
      cell.selectionStyle = .none
      return cell
    case .files(_, _, let entries):
      let cell =
        tableView.dequeueReusableCell(withIdentifier: GitFileCell.reuseIdentifier, for: indexPath) as! GitFileCell
      cell.configure(entry: entries[indexPath.row])
      return cell
    }
  }

  private func entry(at indexPath: IndexPath) -> GitStatusEntry? {
    guard case .files(_, _, let entries) = sections[indexPath.section] else { return nil }
    return entries[indexPath.row]
  }

  override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    entry(at: indexPath)?.canOpen == true
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    if let entry = entry(at: indexPath) { open(entry) }
  }

  override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration?
  {
    guard let entry = entry(at: indexPath), !busy else { return nil }
    var actions: [UIContextualAction] = []
    if entry.canStage {
      let stage = UIContextualAction(
        style: .normal, title: String(localized: "orcaios.sourceControl.stage", defaultValue: "Stage")
      ) { [weak self] _, _, done in
        self?.stage(entry)
        done(true)
      }
      stage.backgroundColor = Palette.mergeGreen
      actions.append(stage)
    }
    if entry.canUnstage {
      let unstage = UIContextualAction(
        style: .normal, title: String(localized: "components.diffReviewDrawers.unstageFile", defaultValue: "Unstage")
      ) { [weak self] _, _, done in
        self?.unstage(entry)
        done(true)
      }
      unstage.backgroundColor = Palette.statusAmber
      actions.append(unstage)
    }
    if entry.canDiscard {
      let discard = UIContextualAction(
        style: .destructive, title: String(localized: "sourceControl.fileRows.discard", defaultValue: "Discard")
      ) { [weak self] _, _, done in
        self?.confirmDiscard(entry, from: nil)
        done(false)
      }
      actions.insert(discard, at: 0)
    }
    let configuration = UISwipeActionsConfiguration(actions: actions)
    configuration.performsFirstActionWithFullSwipe = false
    return configuration
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let entry = entry(at: indexPath) else { return nil }
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      guard let self else { return nil }
      var children: [UIMenuElement] = []
      if entry.canStage {
        children.append(
          UIAction(
            title: String(localized: "orcaios.sourceControl.stage", defaultValue: "Stage"),
            image: Lucide.plus.image(size: 18), attributes: busy ? .disabled : []
          ) { [weak self] _ in self?.stage(entry) })
      }
      if entry.canUnstage {
        children.append(
          UIAction(
            title: String(localized: "components.diffReviewDrawers.unstageFile", defaultValue: "Unstage"),
            image: Lucide.minus.image(size: 18), attributes: busy ? .disabled : []
          ) { [weak self] _ in self?.unstage(entry) })
      }
      children.append(
        UIAction(
          title: String(localized: "session.sheets.copyPath", defaultValue: "Copy Path"),
          image: Lucide.copy.image(size: 18)
        ) { _ in UIPasteboard.general.string = entry.path })
      if entry.canDiscard {
        children.append(
          UIMenu(
            options: .displayInline,
            children: [
              UIAction(
                title: String(localized: "sourceControl.fileRows.discard", defaultValue: "Discard"),
                image: Lucide.undo2.image(size: 18), attributes: busy ? [.destructive, .disabled] : .destructive
              ) { [weak self] _ in self?.confirmDiscard(entry, from: nil) }
            ]))
      }
      return UIMenu(children: children)
    })
  }

  // MARK: Commit message

  func textViewDidChange(_ textView: UITextView) {
    commitMessage = textView.text
    (textView.superview?.superview as? CommitMessageCell)?.updatePlaceholder()
    UIView.performWithoutAnimation {
      tableView.beginUpdates()
      tableView.endUpdates()
    }
    toolbarItems = [.flexibleSpace(), primaryItem()]
  }
}

// MARK: - Cells

/// A changed file: status letter, name over its folder, then +/- line counts.
private final class GitFileCell: UITableViewCell {
  static let reuseIdentifier = "gitFile"

  private let statusLabel = UILabel()
  private let nameLabel = UILabel()
  private let folderLabel = UILabel()
  private let statsLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    statusLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    statusLabel.textAlignment = .center
    nameLabel.font = Typography.font(15)
    nameLabel.textColor = Palette.textPrimary
    nameLabel.lineBreakMode = .byTruncatingMiddle
    folderLabel.font = Typography.font(Typography.metaSize)
    folderLabel.textColor = Palette.textSecondary
    folderLabel.lineBreakMode = .byTruncatingHead
    statsLabel.font = Typography.mono(Typography.metaSize)
    statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    statsLabel.setContentHuggingPriority(.required, for: .horizontal)
    let text = UIStackView(arrangedSubviews: [nameLabel, folderLabel])
    text.axis = .vertical
    text.spacing = Spacing.xxs
    let row = UIStackView(arrangedSubviews: [statusLabel, text, statsLabel])
    row.alignment = .center
    row.spacing = Spacing.md
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      statusLabel.widthAnchor.constraint(equalToConstant: 16),
      row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.sm + 2),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Spacing.sm + 2)),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(entry: GitStatusEntry) {
    let slash = entry.path.lastIndex(of: "/")
    let name = slash.map { String(entry.path[entry.path.index(after: $0)...]) } ?? entry.path
    let folder = slash.map { String(entry.path[..<$0]) } ?? ""
    statusLabel.text = Self.letter(entry.status)
    statusLabel.textColor = Self.color(entry.status)
    let attributes: [NSAttributedString.Key: Any] =
      entry.status == "deleted" ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue] : [:]
    nameLabel.attributedText = NSAttributedString(string: name, attributes: attributes)
    var detail: String?
    if entry.conflictStatus == "unresolved" {
      detail = Self.conflictLabel(entry.conflictKind)
    } else if let oldPath = entry.oldPath {
      detail = String(
        format: String(localized: "sourceControl.fileRows.renamedFrom", defaultValue: "from %1$@"), oldPath)
    }
    let subtitle = [detail, folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    folderLabel.text = subtitle
    folderLabel.isHidden = subtitle.isEmpty
    let stats = NSMutableAttributedString()
    if let added = entry.added, added > 0 {
      stats.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: Palette.diffAddedSign]))
    }
    if let removed = entry.removed, removed > 0 {
      if stats.length > 0 { stats.append(NSAttributedString(string: " ")) }
      stats.append(NSAttributedString(string: "−\(removed)", attributes: [.foregroundColor: Palette.diffDeletedSign]))
    }
    statsLabel.attributedText = stats
    statsLabel.isHidden = stats.length == 0
    accessoryType = entry.canOpen ? .disclosureIndicator : .none
    accessibilityLabel = String(
      format: String(localized: "sourceControl.fileRows.openChangedFile", defaultValue: "Open changed file %1$@"),
      entry.path)
  }

  /// git-status-labels.ts.
  static func letter(_ status: String) -> String {
    switch status {
    case "added": return "A"
    case "deleted": return "D"
    case "renamed": return "R"
    case "untracked": return "U"
    case "copied": return "C"
    default: return "M"
    }
  }

  static func color(_ status: String) -> UIColor {
    switch status {
    case "added", "copied": return Palette.statusGreen
    case "deleted": return Palette.statusRed
    case "renamed": return Palette.accentBlue
    case "untracked": return Palette.statusAmber
    default: return Palette.textSecondary
    }
  }

  static func conflictLabel(_ kind: String?) -> String {
    switch kind {
    case "both_modified": return String(localized: "sourceControl.fileRows.bothModified", defaultValue: "Both modified")
    case "both_added": return String(localized: "sourceControl.fileRows.bothAdded", defaultValue: "Both added")
    case "deleted_by_us": return String(localized: "sourceControl.fileRows.deletedByUs", defaultValue: "Deleted by us")
    case "deleted_by_them":
      return String(localized: "sourceControl.fileRows.deletedByThem", defaultValue: "Deleted by them")
    case "added_by_us": return String(localized: "sourceControl.fileRows.addedByUs", defaultValue: "Added by us")
    case "added_by_them": return String(localized: "sourceControl.fileRows.addedByThem", defaultValue: "Added by them")
    case "both_deleted": return String(localized: "sourceControl.fileRows.bothDeleted", defaultValue: "Both deleted")
    default:
      return String(localized: "sourceControl.fileRows.unresolvedConflict", defaultValue: "Unresolved conflict")
    }
  }
}

/// The commit message box: grows with its text, disabled while nothing is staged.
private final class CommitMessageCell: UITableViewCell {
  static let reuseIdentifier = "commitMessage"

  let textView = UITextView()
  private let placeholder = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    textView.font = Typography.font(15)
    textView.textColor = Palette.textPrimary
    textView.backgroundColor = .clear
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.translatesAutoresizingMaskIntoConstraints = false
    placeholder.font = textView.font
    placeholder.textColor = Palette.textMuted
    placeholder.numberOfLines = 0
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(textView)
    contentView.addSubview(placeholder)
    let margins = contentView.layoutMarginsGuide
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
      textView.topAnchor.constraint(equalTo: margins.topAnchor),
      textView.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
      textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      placeholder.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
      placeholder.topAnchor.constraint(equalTo: textView.topAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(text: String, enabled: Bool, delegate: UITextViewDelegate) {
    if textView.text != text { textView.text = text }
    textView.delegate = delegate
    textView.isEditable = enabled
    textView.alpha = enabled ? 1 : Feedback.disabledOpacity
    placeholder.text =
      enabled
      ? String(localized: "sourceControl.content.commitMessagePlaceholder", defaultValue: "Commit message")
      : String(
        localized: "sourceControl.content.commitMessageDisabled", defaultValue: "Commit message disabled. No staged files.")
    updatePlaceholder()
  }

  func updatePlaceholder() {
    placeholder.isHidden = !textView.text.isEmpty
  }
}

/// A grouped section header with its file count and an optional trailing action (Stage all, Unstage all).
private final class ActionHeaderView: UITableViewHeaderFooterView {
  static let reuseIdentifier = "actionHeader"

  private let button = UIButton(type: .system)

  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    button.titleLabel?.font = Typography.font(13, .semibold)
    button.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      button.lastBaselineAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -2),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(title: String, count: Int, action: UIAction?) {
    var content = UIListContentConfiguration.header()
    content.text = "\(title) \(count)"
    contentConfiguration = content
    button.removeTarget(nil, action: nil, for: .allEvents)
    for existing in button.enumerateActions() { button.removeAction(existing, for: .touchUpInside) }
    if let action {
      button.setTitle(action.title, for: .normal)
      button.addAction(action, for: .touchUpInside)
      button.isHidden = false
    } else {
      button.isHidden = true
    }
    contentView.bringSubviewToFront(button)
  }
}

extension UIButton {
  fileprivate func enumerateActions() -> [UIAction] {
    var actions: [UIAction] = []
    enumerateEventHandlers { action, _, _, _ in
      if let action { actions.append(action) }
    }
    return actions
  }
}
