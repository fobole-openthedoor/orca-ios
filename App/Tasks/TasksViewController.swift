import OrcaCore
import UIKit

/// Tasks (tasks/MobileTasksScreen.tsx): the GitHub issues and pull requests the desktop reads for its projects,
/// with the official GitHub views (Open, Assigned to me; Open, Mine, Needs review), a repository filter and
/// search. With no host given, it reads the first connected one and offers the others in a menu.
final class TasksViewController: UIViewController {
  /// Called after "Create Workspace" made one, with its host and id, so the caller can open it.
  var onOpenWorkspace: ((HostSession, String) -> Void)?

  private enum Sort: String { case updated, repository }

  private let model = AppModel.shared
  private let fixedSession: HostSession?
  private var hostId: PairedHost.ID?
  private let hostButton = UIButton(configuration: .glass())
  private let kindControl = UISegmentedControl()
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let search = UISearchController(searchResultsController: nil)
  private var filterItem: UIBarButtonItem!

  private var preset: GitHubTaskPreset = .issues
  private var sort: Sort = .updated
  private var query = ""
  private var repos: [TaskRepo] = []
  /// Empty: every repository.
  private var selectedRepoIds: Set<String> = []
  private var items: [GitHubWorkItem] = []
  private var sections: [(title: String?, items: [GitHubWorkItem])] = []
  private var loading = false
  private var loadError: String?
  private var loadedKey: String?
  private var loadTask: Task<Void, Never>?
  private var searchDebounce: Task<Void, Never>?

  init(session: HostSession?) {
    fixedSession = session
    hostId = session?.host.id
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var session: HostSession? {
    if let fixedSession { return fixedSession }
    return hostId.flatMap { model.session(for: $0) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "tasks.screenChrome.title", defaultValue: "Tasks")
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .never

    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = String(
      format: String(localized: "tasks.searchControl.providerPlaceholder", defaultValue: "Search %@ tasks..."), "GitHub")
    search.searchBar.autocapitalizationType = .none
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = false

    filterItem = UIBarButtonItem(
      image: Lucide.listFilter.image(size: 20), style: .plain, target: nil, action: nil)
    filterItem.accessibilityLabel = String(localized: "tasks.providerControls.filterLabel", defaultValue: "Filter and display")
    navigationItem.rightBarButtonItem = filterItem

    kindControl.insertSegment(
      withTitle: String(localized: "tasks.options.issues", defaultValue: "Issues"), at: 0, animated: false)
    kindControl.insertSegment(
      withTitle: String(localized: "tasks.options.pullRequests", defaultValue: "PRs"), at: 1, animated: false)
    kindControl.selectedSegmentIndex = 0
    kindControl.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.preset = self.kindControl.selectedSegmentIndex == 1 ? .prs : .issues
        self.reload()
      }, for: .valueChanged)

    hostButton.configuration?.cornerStyle = .capsule
    hostButton.configuration?.baseForegroundColor = Palette.textPrimary
    hostButton.showsMenuAsPrimaryAction = true
    hostButton.isHidden = fixedSession != nil

    let hostRow = UIStackView(arrangedSubviews: [hostButton, UIView()])
    let header = UIStackView(arrangedSubviews: fixedSession == nil ? [hostRow, kindControl] : [kindControl])
    header.axis = .vertical
    header.alignment = .fill
    header.spacing = Spacing.md
    header.isLayoutMarginsRelativeArrangement = true
    header.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: Spacing.sm, leading: Spacing.lg + 4, bottom: Spacing.xs, trailing: Spacing.lg + 4)
    let headerHeight: CGFloat = fixedSession == nil ? 100 : 52
    header.frame = CGRect(x: 0, y: 0, width: 0, height: headerHeight)
    table.tableHeaderView = header

    table.backgroundColor = Palette.bgBase
    table.dataSource = self
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "item")
    table.refreshControl = UIRefreshControl(
      frame: .zero, primaryAction: UIAction { [weak self] _ in self?.reload(force: true) })
    view.addSubview(table)
    table.pin(to: view)
    rebuildFilterMenu()
  }

  override func updateProperties() {
    super.updateProperties()
    if fixedSession == nil {
      let hosts = model.orderedHosts
      if hostId == nil || !hosts.contains(where: { $0.id == hostId }) {
        hostId =
          hosts.first { model.session(for: $0.id)?.connectionState == .connected }?.id ?? hosts.first?.id
      }
      if let session {
        let status = HostConnectionPresentation(session.connectionState)
        var title = AttributedString(
          "● ", attributes: AttributeContainer([.foregroundColor: status.dot, .font: UIFont.systemFont(ofSize: 11)]))
        title += AttributedString(session.name, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16)]))
        hostButton.configuration?.attributedTitle = title
      }
      hostButton.menu = UIMenu(
        children: hosts.map { host in
          UIAction(title: model.session(for: host.id)?.name ?? host.name, state: host.id == hostId ? .on : .off) {
            [weak self] _ in
            guard let self, self.hostId != host.id else { return }
            self.hostId = host.id
            self.repos = []
            self.selectedRepoIds = []
            self.loadedKey = nil
            self.setNeedsUpdateProperties()
          }
        })
    } else {
      navigationItem.subtitle = session?.name
    }
    guard let session else {
      showState()
      return
    }
    if session.connectionState == .connected {
      if loadedKey == nil { reload() }
    } else {
      showState()
    }
  }

  // MARK: Loading

  private var requestKey: String {
    "\(hostId?.uuidString ?? "")|\(preset.rawValue)|\(query)|\(selectedRepoIds.sorted().joined(separator: ","))"
  }

  private func reload(force: Bool = false) {
    guard let session, session.connectionState == .connected else {
      table.refreshControl?.endRefreshing()
      showState()
      return
    }
    let key = requestKey
    loadedKey = key
    loadTask?.cancel()
    loading = true
    loadError = nil
    // A new view or search starts empty; a pull to refresh keeps the rows up while it reads.
    if !force { items = [] }
    rebuildSections()
    let api = session.api
    let preset = preset
    let query = preset.scoped(query)
    let knownRepos = force ? [] : repos
    let selected = selectedRepoIds
    loadTask = Task { [weak self] in
      do {
        let repos = knownRepos.isEmpty ? try await api.taskRepos() : knownRepos
        guard !Task.isCancelled else { return }
        self?.repos = repos
        self?.rebuildFilterMenu()
        let queried = selected.isEmpty ? repos : repos.filter { selected.contains($0.id) }
        if queried.isEmpty {
          self?.finish(items: [], error: nil, key: key)
          return
        }
        let limit = max(1, min(36, 100 / queried.count))
        var collected: [GitHubWorkItem] = []
        var failures: [String] = []
        // Four repositories at a time, as the official screen reads them.
        for chunk in stride(from: 0, to: queried.count, by: 4).map({ Array(queried[$0..<min($0 + 4, queried.count)]) }) {
          await withTaskGroup(of: Result<[GitHubWorkItem], Error>.self) { group in
            for repo in chunk {
              group.addTask { await Result { try await api.githubWorkItems(in: repo, query: query, limit: limit) } }
            }
            for await result in group {
              switch result {
              case .success(let items): collected += items
              case .failure(let error): failures.append(Self.message(error))
              }
            }
          }
          if Task.isCancelled { return }
        }
        let error = failures.count == queried.count ? failures.first : nil
        self?.finish(items: collected, error: error, key: key)
      } catch {
        guard !Task.isCancelled else { return }
        self?.finish(items: [], error: Self.message(error), key: key)
      }
    }
  }

  private func finish(items: [GitHubWorkItem], error: String?, key: String) {
    guard key == loadedKey else { return }
    loading = false
    loadError = error
    // Host pages come in issue-number order; merge them the same way so rows don't reshuffle.
    self.items = items.sorted { $0.number > $1.number }
    table.refreshControl?.endRefreshing()
    rebuildSections()
  }

  static func message(_ error: Error) -> String {
    if let error = error as? RPCError, !error.message.isEmpty { return error.message }
    return error.localizedDescription
  }

  private func rebuildSections() {
    switch sort {
    case .updated:
      let sorted = items.sorted {
        ($0.updatedDate ?? .distantPast, $0.number) > ($1.updatedDate ?? .distantPast, $1.number)
      }
      sections = sorted.isEmpty ? [] : [(nil, sorted)]
    case .repository:
      var order: [String] = []
      var byRepo: [String: [GitHubWorkItem]] = [:]
      for item in items {
        if byRepo[item.repoId] == nil { order.append(item.repoId) }
        byRepo[item.repoId, default: []].append(item)
      }
      sections = order.sorted {
        (byRepo[$0]?.first?.repoName ?? "").localizedStandardCompare(byRepo[$1]?.first?.repoName ?? "")
          == .orderedAscending
      }.map { id in
        let rows = (byRepo[id] ?? []).sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
        return (rows.first?.repoName, rows)
      }
    }
    table.reloadData()
    showState()
  }

  private func showState() {
    guard isViewLoaded else { return }
    var config: UIContentUnavailableConfiguration?
    if let session, session.connectionState != .connected {
      config = .empty()
      config?.image = Lucide.wifiOff.image(size: 34, strokeWidth: 1.6)
      config?.text = String(
        format: String(localized: "common.offline.waitingFor", defaultValue: "Waiting for %@"), session.name)
      config?.secondaryText = String(
        localized: "common.offline.message", defaultValue: "Check that the host is awake and Orca is running.")
    } else if session == nil {
      config = .empty()
      config?.text = String(
        localized: "tasks.connectionPresentation.connectToHost", defaultValue: "Connect to a host to load tasks")
    } else if loading && items.isEmpty {
      config = .loading()
      config?.text = String(localized: "tasks.listState.loading", defaultValue: "Loading tasks…")
    } else if let loadError, items.isEmpty {
      config = .empty()
      config?.image = Lucide.circleAlert.image(size: 34, strokeWidth: 1.6)
      config?.text = String(localized: "common.loadError.title", defaultValue: "Unable to Load")
      config?.secondaryText = loadError
      var retry = UIButton.Configuration.glass()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config?.button = retry
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload(force: true) }
    } else if items.isEmpty, !loading {
      config = .empty()
      config?.image = Lucide.inbox.image(size: 34, strokeWidth: 1.6)
      config?.text =
        query.isEmpty
        ? String(localized: "tasks.taskViewOptions.noGitHubTasks", defaultValue: "No GitHub tasks")
        : String(localized: "tasks.connectionPresentation.noMatchingTasks", defaultValue: "No matching tasks")
    }
    config?.imageProperties.tintColor = Palette.textMuted
    contentUnavailableConfiguration = config
  }

  // MARK: Filter menu

  private func rebuildFilterMenu() {
    let views: [(GitHubTaskPreset, String, String)] =
      preset.isPullRequests
      ? [
        (
          .prs, String(localized: "tasks.options.openState", defaultValue: "Open"),
          String(localized: "tasks.options.openPullRequestsDescription", defaultValue: "Open pull requests")
        ),
        (
          .myPRs, String(localized: "tasks.options.mine", defaultValue: "Mine"),
          String(localized: "tasks.options.myPullRequestsDescription", defaultValue: "Pull requests authored by you")
        ),
        (
          .review, String(localized: "tasks.options.needsReview", defaultValue: "Needs review"),
          String(localized: "tasks.options.reviewRequestsDescription", defaultValue: "Review requests assigned to you")
        ),
      ]
      : [
        (
          .issues, String(localized: "tasks.options.openState", defaultValue: "Open"),
          String(localized: "tasks.options.githubOpenIssuesDescription", defaultValue: "Open GitHub issues")
        ),
        (
          .myIssues, String(localized: "tasks.options.assignedToMe", defaultValue: "Assigned to me"),
          String(localized: "tasks.options.githubAssignedIssuesDescription", defaultValue: "Open issues assigned to you")
        ),
      ]
    let viewMenu = UIMenu(
      title: String(localized: "tasks.filterSheet.view", defaultValue: "View"), options: .displayInline,
      children: views.map { value, title, subtitle in
        UIAction(title: title, subtitle: subtitle, state: preset == value ? .on : .off) { [weak self] _ in
          self?.preset = value
          self?.rebuildFilterMenu()
          self?.reload()
        }
      })
    let sortMenu = UIMenu(
      title: String(localized: "tasks.filterSheet.sortBy", defaultValue: "Sort by"), options: .displayInline,
      children: [
        (Sort.updated, String(localized: "tasks.options.updated", defaultValue: "Updated"),
         String(localized: "tasks.options.updatedSortDescription", defaultValue: "Newest activity first")),
        (Sort.repository, String(localized: "tasks.options.repository", defaultValue: "Repository"),
         String(localized: "tasks.options.repositorySortDescription", defaultValue: "Group by repository, then newest activity")),
      ].map { value, title, subtitle in
        UIAction(title: title, subtitle: subtitle, state: sort == value ? .on : .off) { [weak self] _ in
          self?.sort = value
          self?.rebuildFilterMenu()
          self?.rebuildSections()
        }
      })
    var menus = [viewMenu, sortMenu]
    if repos.count > 1 {
      let all = UIAction(
        title: String(localized: "tasks.providerPickers.allRepositories", defaultValue: "All repositories"),
        state: selectedRepoIds.isEmpty ? .on : .off
      ) { [weak self] _ in
        self?.selectedRepoIds = []
        self?.rebuildFilterMenu()
        self?.reload()
      }
      let each = repos.map { repo in
        UIAction(title: repo.displayName, state: selectedRepoIds.contains(repo.id) ? .on : .off) { [weak self] _ in
          guard let self else { return }
          if self.selectedRepoIds.contains(repo.id) {
            self.selectedRepoIds.remove(repo.id)
          } else {
            self.selectedRepoIds.insert(repo.id)
          }
          // Every repository picked is the same as none: the filter widens back to all.
          if self.selectedRepoIds.count == self.repos.count { self.selectedRepoIds = [] }
          self.rebuildFilterMenu()
          self.reload()
        }
      }
      let value =
        selectedRepoIds.isEmpty
        ? String(localized: "tasks.pickerProjection.allRepos", defaultValue: "All repos")
        : repos.filter { selectedRepoIds.contains($0.id) }.map(\.displayName).joined(separator: ", ")
      let repoMenu = UIMenu(
        title: String(localized: "tasks.providerPickers.repos", defaultValue: "Repositories"), subtitle: value,
        image: Lucide.folderGit2.image(size: 18), children: [all] + each)
      menus.append(UIMenu(options: .displayInline, children: [repoMenu]))
    }
    filterItem.menu = UIMenu(children: menus)
  }
}

extension TasksViewController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    let text = searchController.searchBar.text ?? ""
    guard text != query else { return }
    query = text
    searchDebounce?.cancel()
    searchDebounce = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.reload()
    }
  }
}

extension TasksViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].items.count }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = sections[indexPath.section].items[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = item.title
    content.textProperties.font = .systemFont(ofSize: 16)
    content.textProperties.numberOfLines = 2
    var meta = ["\(item.repoName) #\(item.number)"]
    if let author = item.author, !author.isEmpty { meta.append(author) }
    if let date = item.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) { meta.append(age) }
    content.secondaryText = meta.joined(separator: " · ")
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.font = .systemFont(ofSize: 13)
    let glyph = TaskStateGlyph(item)
    content.image = glyph.icon.image(size: 18)
    content.imageProperties.tintColor = glyph.color
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    cell.contentConfiguration = content
    cell.backgroundColor = Palette.bgPanel
    cell.accessoryType = .disclosureIndicator
    cell.accessibilityLabel = "\(item.title), \(glyph.label)"
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    guard let session else { return }
    let item = sections[indexPath.section].items[indexPath.row]
    let detail = TaskDetailViewController(session: session, item: item)
    detail.onOpenWorkspace = onOpenWorkspace
    navigationController?.pushViewController(detail, animated: true)
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    let item = sections[indexPath.section].items[indexPath.row]
    guard let url = URL(string: item.url) else { return nil }
    return UIContextMenuConfiguration(actionProvider: { _ in
      UIMenu(children: [
        UIAction(
          title: String(localized: "tasks.projectDetailDrawer.openInGitHub", defaultValue: "Open in GitHub"),
          image: Lucide.externalLink.image(size: 18)
        ) { _ in UIApplication.shared.open(url) },
        UIAction(
          title: String(localized: "tasks.itemActions.copyGitHubLink", defaultValue: "Copy GitHub link"),
          image: Lucide.copy.image(size: 18)
        ) { _ in UIPasteboard.general.string = item.url },
      ])
    })
  }
}

/// The glyph and colour for an issue's or pull request's state, as GitHub draws them.
struct TaskStateGlyph {
  let icon: Lucide
  let color: UIColor
  let label: String

  init(_ item: GitHubWorkItem) {
    let open = String(localized: "tasks.options.openState", defaultValue: "Open")
    let closed = String(localized: "tasks.options.closedState", defaultValue: "Closed")
    switch (item.kind, item.state) {
    case (.issue, "closed"): (icon, color, label) = (.circleCheck, Palette.statusPurple, closed)
    case (.issue, _): (icon, color, label) = (.circleDot, Palette.statusGreen, open)
    case (.pr, "merged"):
      (icon, color, label) = (
        .gitMerge, Palette.statusPurple, String(localized: "tasks.options.mergedState", defaultValue: "Merged")
      )
    case (.pr, "closed"): (icon, color, label) = (.gitPullRequestClosed, Palette.statusRed, closed)
    case (.pr, "draft"):
      (icon, color, label) = (
        .gitPullRequestDraft, Palette.textMuted,
        String(localized: "pullRequest.prChecksPresentation.stateDraft", defaultValue: "Draft")
      )
    case (.pr, _): (icon, color, label) = (.gitPullRequest, Palette.statusGreen, open)
    }
  }
}
