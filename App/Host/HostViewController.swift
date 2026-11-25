import OrcaCore
import UIKit

/// A paired desktop's projects and workspaces, including its connected servers.
/// System chrome: large title with a connection subtitle, ⋯ menu, and a bottom toolbar with filter, search and +.
final class HostViewController: UIViewController {
  private enum Section: Hashable {
    case bots
    case project(String)
    /// A lane that isn't a project: `pinned`, `all`, `status:<id>` or `pr:<state>`.
    case lane(String)
  }

  private enum Item: Hashable {
    case bot(RowID)
    /// The bot's Home Chat, under its row while unfolded.
    case botHome(RowID)
    case botsEmpty
    case worktree(RowID)
  }

  private struct RowID: Hashable, Sendable {
    let scope: String
    let hostId: String
    let id: String
  }

  private struct WorkspaceEntry: Sendable {
    let id: RowID
    let session: HostSession
    let worktree: Worktree
    let repoName: String
    let project: WorkspaceProjectCatalog.Project
  }

  private struct WorkspacePlacement {
    let depth: Int
    let childCount: Int
  }

  private let session: HostSession
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
  private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
  private var collapsed: Set<String> = []
  private var foldedWorktrees: Set<RowID> = []
  private var foldedBots: Set<RowID> = []
  private var placements: [RowID: WorkspacePlacement] = [:]
  private var workspacesByID: [RowID: WorkspaceEntry] = [:]
  private var botsByID: [RowID: (Bot, HostSession)] = [:]
  private var projectNames: [String: String] = [:]
  private var sectionCounts: [Section: Int] = [:]
  private var query = ""
  private var workspaceView = WorkspaceView()
  private var workspaceViewLoaded = false
  private let search = UISearchController(searchResultsController: nil)

  init(session: HostSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .always
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: Lucide.ellipsis.image(size: 20, strokeWidth: 2), menu: hostMenu())
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "hostScreen.hostScreenHeader.moreActions", defaultValue: "More actions")

    search.searchBar.placeholder = String(
      localized: "hostScreen.hostBottomBar.searchWorkspaces", defaultValue: "Search workspaces")
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    navigationItem.searchController = search
    navigationItem.preferredSearchBarPlacement = .integrated
    navigationItem.searchBarPlacementAllowsToolbarIntegration = true
    let filter = UIBarButtonItem(
      image: Lucide.slidersHorizontal.image(size: 20, strokeWidth: 2),
      primaryAction: UIAction { [weak self] _ in self?.showOptions() })
    filter.accessibilityLabel = String(localized: "hostScreen.hostBottomBar.workspaceOptions", defaultValue: "Workspace options")
    let create = UIBarButtonItem(
      image: Lucide.plus.image(size: 20, strokeWidth: 2.2), style: .prominent, target: nil, action: nil)
    create.primaryAction = UIAction(image: Lucide.plus.image(size: 20, strokeWidth: 2.2)) { [weak self] _ in
      self?.newWorkspace()
    }
    create.tintColor = Palette.createActionFill
    create.accessibilityLabel = String(localized: "hostScreen.hostBottomBar.newWorkspace", defaultValue: "New workspace")
    toolbarItems = [filter, navigationItem.searchBarPlacementBarButtonItem, create]

    collection.backgroundColor = Palette.bgBase
    collection.delegate = self
    collection.refreshControl = UIRefreshControl(
      frame: .zero, primaryAction: UIAction { [weak self] _ in self?.reload() })
    view.addSubview(collection)
    collection.pin(to: view)
    configureDataSource()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setToolbarHidden(false, animated: animated)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setToolbarHidden(true, animated: animated)
  }

  override func updateProperties() {
    super.updateProperties()
    title = session.name
    let status = HostConnectionPresentation(session.connectionState)
    let subtitle = NSMutableAttributedString(
      string: "● ", attributes: [.foregroundColor: status.dot, .font: UIFont.systemFont(ofSize: 11)])
    let line = status.connected ? (session.status?.machineLine ?? status.label) : status.label
    subtitle.append(
      NSAttributedString(
        string: line, attributes: [.foregroundColor: status.connected ? Palette.textSecondary : status.labelColor]))
    navigationItem.attributedSubtitle = AttributedString(subtitle)
    // The menu follows the connection, the host's bots and its Floating Workspace setting.
    navigationItem.rightBarButtonItem?.menu = hostMenu()
    if status.connected, !workspaceViewLoaded { loadWorkspaceView() }
    applySnapshot()
  }

  private func reload() {
    if session.connectionState == .connected { loadWorkspaceView() }
    Task {
      await session.refresh()
      collection.refreshControl?.endRefreshing()
    }
  }

  // MARK: Data

  private func loadWorkspaceView() {
    workspaceViewLoaded = true
    Task {
      do {
        workspaceView = try await session.api.workspaceView()
        applySnapshot()
      } catch {
        workspaceViewLoaded = false
      }
    }
  }

  private func showOptions() {
    let rows = workspaceEntries.filter { !$0.worktree.isFolderWorkspace }
    let byProject = Dictionary(grouping: rows, by: \.project.id)
    var seen = Set<String>()
    let projects = rows.compactMap { entry -> WorkspaceOptionsViewController.Project? in
      guard seen.insert(entry.project.id).inserted, let group = byProject[entry.project.id] else { return nil }
      return .init(id: entry.project.id, name: entry.project.name, repoIds: Set(group.map(\.worktree.repoId)))
    }
    let api = session.api
    present(
      WorkspaceOptionsViewController.sheet(view: workspaceView, projects: projects) { [weak self] view in
        guard let self else { return }
        let old = self.workspaceView
        self.workspaceView = view
        self.applySnapshot()
        Task {
          do {
            try await api.setWorkspaceView(from: old, to: view)
          } catch {
            // The host refused: show what it keeps.
            self.workspaceViewLoaded = false
            self.setNeedsUpdateProperties()
          }
        }
      }, animated: true)
  }

  private var listingSessions: [HostSession] {
    [session] + session.remoteServers.filter { source in
      guard let id = source.remoteServer?.id else { return false }
      return workspaceView.visibleHostIds?.contains(id) != false
    }
  }

  private var workspaceEntries: [WorkspaceEntry] {
    let projects = session.workspaceProjects
    return listingSessions.flatMap { source -> [WorkspaceEntry] in
      let botHomes = Set(source.bots.bots.map(\.homeWorktreeId))
      let repos = Dictionary(source.repos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let serverId = source.remoteServer?.id
      return source.worktrees.compactMap { worktree -> WorkspaceEntry? in
        guard !worktree.isArchived, !botHomes.contains(worktree.id) else { return nil }
        let repo = repos[worktree.repoId]
        let hostId = serverId ?? worktree.executionHostId ?? repo?.workspaceHostId ?? "local"
        guard workspaceView.visibleHostIds?.contains(hostId) != false else { return nil }
        let repoName = repo?.displayName ?? worktree.repo
        let project = projects.project(hostId: hostId, repoId: worktree.repoId, fallbackName: repoName)
        guard !project.isHidden else { return nil }
        return WorkspaceEntry(
          id: RowID(scope: source.cacheNamespace, hostId: hostId, id: worktree.id), session: source,
          worktree: worktree, repoName: repoName, project: project)
      }
    }
  }

  private func applySnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    // A search narrows the bots to the ones it names, and drops the section when none match.
    let needle = query.lowercased()
    var seenBots = Set<RowID>()
    let bots = listingSessions.flatMap { source in
      // Read connection changes here so the row updates even if the catalog did not change.
      _ = (source.connectionState, source.name)
      return source.bots.bots.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }.map { bot in
        (RowID(scope: source.cacheNamespace, hostId: source.remoteServer?.id ?? "local", id: bot.id), (bot, source))
      }
    }.filter { seenBots.insert($0.0).inserted }
    botsByID = Dictionary(bots, uniquingKeysWith: { first, _ in first })
    let entries = workspaceEntries
    let knownRepoIds = Set(entries.map(\.worktree.repoId))
    let filtered = entries.filter { entry in
      guard workspaceView.keeps(entry.worktree, knownRepoIds: knownRepoIds) else { return false }
      return needle.isEmpty || [entry.worktree.displayName, entry.worktree.branch, entry.repoName, entry.project.name,
                               entry.session.remoteServer?.label ?? ""].contains { $0.lowercased().contains(needle) }
    }
    workspacesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let sorted = workspaceView.sorted(filtered, worktree: \.worktree)
    if needle.isEmpty || !bots.isEmpty {
      snapshot.appendSections([.bots])
      snapshot.appendItems(
        bots.isEmpty
          ? [.botsEmpty]
          : bots.flatMap { entry in foldedBots.contains(entry.0) ? [.bot(entry.0)] : [.bot(entry.0), .botHome(entry.0)] },
        toSection: .bots)
    }
    contentUnavailableConfiguration = !needle.isEmpty && bots.isEmpty && sorted.isEmpty ? UIContentUnavailableConfiguration.search() : nil
    let roots = Worktree.lineage(sorted, worktree: \.worktree, scope: \.id.scope)
    let pinned = roots.filter { $0.entry.worktree.isPinned }
    let worktrees = roots.filter { !$0.entry.worktree.isPinned }
    placements.removeAll(keepingCapacity: true)
    sectionCounts.removeAll(keepingCapacity: true)
    projectNames.removeAll(keepingCapacity: true)
    func append(_ branches: [LineageBranch<WorkspaceEntry>], to section: Section, collapsed: Bool) {
      snapshot.appendSections([section])
      var items: [Item] = []
      var count = 0
      func visit(_ branch: LineageBranch<WorkspaceEntry>, depth: Int, visible: Bool) {
        let id = branch.entry.id
        count += 1
        if visible {
          items.append(.worktree(id))
          placements[id] = WorkspacePlacement(depth: depth, childCount: branch.children.count)
        }
        let showChildren = visible && (!needle.isEmpty || !foldedWorktrees.contains(id))
        for child in branch.children { visit(child, depth: depth + 1, visible: showChildren) }
      }
      for root in branches { visit(root, depth: 0, visible: !collapsed) }
      sectionCounts[section] = count
      snapshot.appendItems(items, toSection: section)
    }
    func lane(_ key: String, _ branches: [LineageBranch<WorkspaceEntry>]) {
      guard !branches.isEmpty else { return }
      // Folder workspaces sit after the git ones.
      let ordered = branches.filter { !$0.entry.worktree.isFolderWorkspace } + branches.filter { $0.entry.worktree.isFolderWorkspace }
      append(ordered, to: .lane(key), collapsed: collapsed.contains(key) && needle.isEmpty)
    }
    lane("pinned", pinned)
    switch workspaceView.groupBy {
    case "repo":
      let groups = Dictionary(grouping: worktrees, by: \.entry.project.id)
      for projectId in projectOrder(worktrees, entries: entries) {
        guard var branches = groups[projectId], let project = branches.first?.entry.project else { continue }
        projectNames[projectId] = project.name
        // A project's own checkout leads its group unless the order is manual (section-order.ts).
        if workspaceView.sortBy != "manual" {
          branches = branches.filter { $0.entry.worktree.isMainWorktree } + branches.filter { !$0.entry.worktree.isMainWorktree }
        }
        append(branches, to: .project(projectId), collapsed: collapsed.contains(projectId) && needle.isEmpty)
      }
    case "workspace-status":
      for status in workspaceView.statuses {
        lane("status:\(status.id)", worktrees.filter { workspaceView.status(of: $0.entry.worktree) == status.id })
      }
    case "pr-status":
      for state in ["done", "in-review", "in-progress", "closed"] {
        lane("pr:\(state)", worktrees.filter { WorkspaceView.prLane(of: $0.entry.worktree) == state })
      }
    default:
      lane("all", worktrees)
    }
    snapshot.reconfigureItems(snapshot.itemIdentifiers)
    dataSource.apply(snapshot, animatingDifferences: view.window != nil) { [weak self] in self?.refreshHeaders() }
  }

  /// Headers count their rows when made; a section that stays while its rows change keeps its header, so
  /// those on screen count again after each update.
  private var configureHeader: ((WorkspaceSectionHeader, IndexPath) -> Void)?

  private func refreshHeaders() {
    let kind = UICollectionView.elementKindSectionHeader
    for indexPath in collection.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
      if let header = collection.supplementaryView(forElementKind: kind, at: indexPath) as? WorkspaceSectionHeader {
        configureHeader?(header, indexPath)
      }
    }
  }

  /// Projects in the host's order, or by their latest workspace activity.
  private func projectOrder(_ branches: [LineageBranch<WorkspaceEntry>], entries: [WorkspaceEntry]) -> [String] {
    var seen = Set<String>()
    let order = branches.map(\.entry.project.id).filter { seen.insert($0).inserted }
    guard workspaceView.projectOrderBy == "recent" else {
      let catalogRanks = Dictionary(entries.compactMap { entry in
        entry.project.order.map { (entry.project.id, $0) }
      }, uniquingKeysWith: min)
      let rowRanks = Dictionary(entries.enumerated().map { ($0.element.project.id, $0.offset) }, uniquingKeysWith: min)
      return order.sorted { left, right in
        (catalogRanks[left] ?? Int.max, rowRanks[left] ?? Int.max) < (catalogRanks[right] ?? Int.max, rowRanks[right] ?? Int.max)
      }
    }
    func newest(_ branch: LineageBranch<WorkspaceEntry>) -> Double {
      max(branch.entry.worktree.lastActivityAt ?? 0, branch.children.map(newest).max() ?? 0)
    }
    let latest = Dictionary(grouping: branches, by: \.entry.project.id).mapValues { $0.map(newest).max() ?? 0 }
    return order.sorted { (latest[$0] ?? 0) > (latest[$1] ?? 0) }
  }

  // MARK: Layout

  private func makeLayout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { [weak self] index, environment in
      var list = UICollectionLayoutListConfiguration(appearance: .plain)
      list.backgroundColor = Palette.bgBase
      list.headerMode = .supplementary
      list.itemSeparatorHandler = { indexPath, configuration in
        var configuration = configuration
        configuration.color = Palette.borderSubtle
        // Separators start at the row's text (worktree-list-row-layout textInset).
        configuration.bottomSeparatorInsets.leading = WorkspaceRowView.textInset
        if let self, case .worktree(let id) = self.dataSource.itemIdentifier(for: indexPath) {
          configuration.bottomSeparatorInsets.leading += WorkspaceRowView.indent(depth: self.placements[id]?.depth ?? 0)
        }
        configuration.bottomSeparatorInsets.trailing = 0
        let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
        let rows = self?.collection.numberOfItems(inSection: indexPath.section) ?? 0
        // No line under a section's last row, as the official list.
        let last = indexPath.item == rows - 1
        configuration.bottomSeparatorVisibility = section == .bots || last ? .hidden : .visible
        configuration.topSeparatorVisibility = .hidden
        return configuration
      }
      return NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
    }
  }

  private func configureDataSource() {
    let worktreeCell = UICollectionView.CellRegistration<UICollectionViewListCell, RowID> { [weak self] cell, _, id in
      guard let self, let entry = self.workspacesByID[id] else { return }
      // Grouped by project, the heading already names the project.
      let projectName = self.workspaceView.groupBy == "repo" ? entry.repoName : nil
      let placement = self.placements[id]
      var configuration = WorkspaceRowConfiguration(
        worktree: entry.worktree, projectName: projectName, depth: placement?.depth ?? 0,
        childCount: placement?.childCount ?? 0, childrenCollapsed: self.foldedWorktrees.contains(id))
      if let server = entry.session.remoteServer {
        let status = HostConnectionPresentation(entry.session.connectionState, server: server)
        configuration.hostLabel = server.label
        if !status.connected { configuration.hostStatus = status }
      }
      if configuration.childCount > 0, self.query.isEmpty {
        configuration.onToggleChildren = { [weak self] in self?.toggleChildren(of: id) }
      }
      cell.contentConfiguration = configuration
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgBase
      cell.backgroundConfiguration = background
    }
    let botsEmptyCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
      cell.contentConfiguration = NoteRowConfiguration(
        text: String(localized: "bots.list.noBotsYet", defaultValue: "No bots yet"),
        insets: NSDirectionalEdgeInsets(top: 2, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg))
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgBase
      cell.backgroundConfiguration = background
    }
    let configureHeader = { [weak self] (header: WorkspaceSectionHeader, indexPath: IndexPath) in
      guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
      switch section {
      case .bots:
        header.configureBots(count: self.botsByID.count) { [weak self] in self?.newBot() }
      case .project(let projectId):
        header.configureProject(
          name: self.projectNames[projectId] ?? projectId, count: self.sectionCounts[section] ?? 0,
          collapsed: self.collapsed.contains(projectId) && self.query.isEmpty
        ) { [weak self] in self?.toggle(projectId) }
      case .lane(let key):
        header.configureLane(title: self.laneTitle(key), count: self.sectionCounts[section] ?? 0, pinned: key == "pinned", collapsed: self.collapsed.contains(key) && self.query.isEmpty) {
          [weak self] in self?.toggleLane(key)
        }
      }
    }
    self.configureHeader = configureHeader
    let header = UICollectionView.SupplementaryRegistration<WorkspaceSectionHeader>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { header, _, indexPath in configureHeader(header, indexPath) }
    let botCell = UICollectionView.CellRegistration<UICollectionViewListCell, RowID> { [weak self] cell, _, id in
      guard let self, let (bot, source) = self.botsByID[id] else { return }
      var configuration = BotRowConfiguration.make(bot: bot, session: source, showHost: source.remoteServer != nil)
      configuration.unfolded = !self.foldedBots.contains(id)
      configuration.onToggle = { [weak self] in self?.toggleBot(id) }
      cell.contentConfiguration = configuration
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgBase
      cell.backgroundConfiguration = background
    }
    let homeCell = UICollectionView.CellRegistration<UICollectionViewListCell, RowID> { [weak self] cell, _, id in
      guard let (bot, source) = self?.botsByID[id] else { return }
      cell.contentConfiguration = BotHomeChatRowConfiguration(
        updatedAt: BotRowConfiguration.make(bot: bot, session: source, showHost: false).updatedAt)
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgBase
      cell.backgroundConfiguration = background
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { collection, indexPath, item in
      switch item {
      case .botHome(let id): collection.dequeueConfiguredReusableCell(using: homeCell, for: indexPath, item: id)
      case .bot(let id): collection.dequeueConfiguredReusableCell(using: botCell, for: indexPath, item: id)
      case .worktree(let id): collection.dequeueConfiguredReusableCell(using: worktreeCell, for: indexPath, item: id)
      case .botsEmpty: collection.dequeueConfiguredReusableCell(using: botsEmptyCell, for: indexPath, item: item)
      }
    }
    dataSource.supplementaryViewProvider = { collection, _, indexPath in
      collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
    }
  }

  private func newWorkspace() {
    // Git projects only: a bot's home folder isn't somewhere to branch from.
    let botHomes = Set(session.bots.bots.map(\.homeWorktreeId))
    let repoIds = session.worktrees.filter { !$0.isFolderWorkspace && !botHomes.contains($0.id) }.map(\.repoId)
    let projects = session.repos.filter { repoIds.contains($0.id) }
    let session = session
    present(
      NewWorkspaceViewController.sheet(session: session, projects: projects.isEmpty ? session.repos : projects) {
        [weak self] id in
        self?.navigationController?.pushViewController(SessionViewController(session: session, worktreeId: id), animated: true)
      }, animated: true)
  }

  private func newBot() {
    let session = session
    present(
      NewBotViewController.sheet(session: session) { [weak self] bot in
        BotDirectory.open(bot, in: session, from: self?.navigationController)
      }, animated: true)
  }

  private func laneTitle(_ key: String) -> String {
    switch key {
    case "pinned": return String(localized: "worktree.workspaceListSections.pinned", defaultValue: "Pinned")
    case "all": return String(localized: "worktree.workspaceListSections.all", defaultValue: "All")
    case "pr:done": return String(localized: "worktree.workspaceListSections.done", defaultValue: "Done")
    case "pr:in-review": return String(localized: "worktree.workspaceListSections.inReview", defaultValue: "In review")
    case "pr:in-progress": return String(localized: "worktree.workspaceListSections.inProgress", defaultValue: "In progress")
    case "pr:closed": return String(localized: "worktree.workspaceListSections.closed", defaultValue: "Closed")
    default:
      // Status names are the host's own, as on the desktop.
      let id = String(key.dropFirst("status:".count))
      return workspaceView.statuses.first { $0.id == id }?.label ?? id
    }
  }

  private func toggleLane(_ key: String) {
    guard query.isEmpty else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    applySnapshot()
    var snapshot = dataSource.snapshot()
    snapshot.reloadSections([.lane(key)])
    dataSource.apply(snapshot, animatingDifferences: true)
  }

  private func toggleBot(_ id: RowID) {
    if foldedBots.contains(id) { foldedBots.remove(id) } else { foldedBots.insert(id) }
    applySnapshot()
  }

  private func toggleChildren(of id: RowID) {
    UISelectionFeedbackGenerator().selectionChanged()
    if foldedWorktrees.contains(id) { foldedWorktrees.remove(id) } else { foldedWorktrees.insert(id) }
    applySnapshot()
  }

  private func toggle(_ projectId: String) {
    guard query.isEmpty else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    if collapsed.contains(projectId) { collapsed.remove(projectId) } else { collapsed.insert(projectId) }
    applySnapshot()
  }

  // MARK: Menus

  /// The ⋯ menu (host-screen-header.tsx): this desktop's pages, then the saved host's own settings.
  private func hostMenu() -> UIMenu {
    let connected = session.connectionState == .connected
    func item(_ title: String, _ icon: Lucide, needsConnection: Bool = true, _ action: @escaping (HostViewController) -> Void) -> UIAction {
      let item = UIAction(title: title, image: icon.image(size: 18)) { [weak self] _ in
        guard let self else { return }
        action(self)
      }
      if needsConnection, !connected { item.attributes = .disabled }
      return item
    }
    var navigation = [
      item(String(localized: "hostScreen.hostScreenHeader.tasks", defaultValue: "Tasks"), .list) { $0.openTasks() },
      item(String(localized: "hostScreen.hostScreenHeader.automations", defaultValue: "Automations"), .calendarClock) {
        $0.push(HostAutomationsViewController(session: $0.session))
      },
      item(String(localized: "hostScreen.hostScreenHeader.accounts", defaultValue: "Accounts"), .userCircle) {
        $0.push(HostAccountsViewController(session: $0.session))
      },
    ]
    // The desktop's own bot links, once it lists bots.
    if session.bots.enabled {
      navigation.append(
        item(String(localized: "hostScreen.hostScreenHeader.sharedLinks", defaultValue: "Shared links"), .link) {
          $0.present(HostSharedLinksViewController.sheet(session: $0.session), animated: true)
        })
    }
    if session.status?.floatingWorkspaceEnabled == true {
      navigation.append(
        item(String(localized: "hostScreen.hostScreenHeader.floatingWorkspace", defaultValue: "Floating Workspace"), .squareTerminal) {
          $0.openFloatingWorkspace()
        })
    }
    // Unlike the pages above, these work on the saved host, so they stay offered while disconnected.
    let host = [
      item(String(localized: "hostScreen.hostListActionSheetActions.editHost", defaultValue: "Edit host"), .edit3, needsConnection: false) {
        $0.push(EditHostViewController(session: $0.session))
      },
      item(
        String(localized: "hostScreen.hostListActionSheetActions.networkDiagnostics", defaultValue: "Network diagnostics"), .activity,
        needsConnection: false
      ) { $0.push(NetworkDiagnosticsViewController(session: $0.session)) },
    ]
    var groups = [UIMenu(options: .displayInline, children: navigation), UIMenu(options: .displayInline, children: host)]
    // The official header offers Reconnect beside the status line during an outage; the bar's subtitle can't hold a button.
    if !connected, session.connectionState != .authFailed {
      groups.append(
        UIMenu(
          options: .displayInline,
          children: [
            item(String(localized: "hostScreen.hostScreenHeader.reconnect", defaultValue: "Reconnect"), .refreshCw, needsConnection: false) {
              $0.session.nudge()
            }
          ]))
    }
    return UIMenu(children: groups)
  }

  private func push(_ controller: UIViewController) {
    navigationController?.pushViewController(controller, animated: true)
  }

  /// This desktop's issues and reviews; making a workspace from one opens it.
  private func openTasks() {
    let tasks = TasksViewController(session: session)
    tasks.onOpenWorkspace = { [weak self] session, worktreeId in
      self?.navigationController?.pushViewController(SessionViewController(session: session, worktreeId: worktreeId), animated: true)
    }
    navigationController?.pushViewController(tasks, animated: true)
  }

  /// The desktop's Floating Workspace (session/floating-workspace.ts): a synthetic workspace with no repo behind it.
  private func openFloatingWorkspace() {
    let floating = SessionViewController(session: session, worktreeId: "global-floating-terminal")
    floating.fallbackTitle = String(localized: "session.floatingWorkspace.title", defaultValue: "Floating Workspace")
    push(floating)
  }

}

extension HostViewController: UICollectionViewDelegate, UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text ?? ""
    applySnapshot()
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    Haptics.select()
    collectionView.deselectItem(at: indexPath, animated: true)
    switch dataSource.itemIdentifier(for: indexPath) {
    case .worktree(let id):
      if let entry = workspacesByID[id] {
        push(SessionViewController(session: entry.session, worktreeId: entry.worktree.id))
      }
    case .bot(let id), .botHome(let id):
      if let (bot, source) = botsByID[id] {
        BotDirectory.open(bot, in: source, from: navigationController)
      }
    default:
      break
    }
  }

  func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
    switch dataSource.itemIdentifier(for: indexPath) {
    case .worktree, .bot, .botHome: return true
    default: return false
    }
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first, case .worktree(let id) = dataSource.itemIdentifier(for: indexPath),
      let entry = workspacesByID[id]
    else { return nil }
    let worktree = entry.worktree
    let source = entry.session
    let api = source.api
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      let pin = UIAction(
        title: worktree.isPinned
          ? String(localized: "hostScreen.hostScreenOverlays.unpin", defaultValue: "Unpin")
          : String(localized: "hostScreen.hostScreenOverlays.pin", defaultValue: "Pin"),
        image: (worktree.isPinned ? Lucide.pinOff : Lucide.pin).image(size: 18)
      ) { _ in
        Task {
          try? await api.setPinned(!worktree.isPinned, worktree: worktree.selector)
          await source.refresh()
        }
      }
      let copyBranch = UIAction(
        title: String(localized: "common.copy", defaultValue: "Copy"), subtitle: worktree.branch,
        image: Lucide.copy.image(size: 18)
      ) { _ in UIPasteboard.general.string = worktree.branch }
      if api.connection.isRelayed {
        return UIMenu(title: worktree.displayName, children: [pin, copyBranch])
      }
      let delete = UIAction(
        title: String(localized: "common.delete", defaultValue: "Delete"), image: Lucide.trash2.image(size: 18),
        attributes: .destructive
      ) { [weak self] _ in self?.confirmDelete(worktree) }
      return UIMenu(title: worktree.displayName, children: [
        UIMenu(options: .displayInline, children: [pin, copyBranch]), UIMenu(options: .displayInline, children: [delete]),
      ])
    }
  }

  /// The official delete sheet's words: a folder leaves Orca and stays on disk; a worktree goes with its branch.
  private func confirmDelete(_ worktree: Worktree) {
    let name = worktree.displayName.isEmpty ? worktree.repo : worktree.displayName
    let folder = worktree.id.hasPrefix("folder:")
    let alert = UIAlertController(
      title: folder ? String(localized: "hostScreen.deleteConfirm.removeTitle", defaultValue: "Remove Workspace") : nil,
      message: folder
        ? String(
          format: String(
            localized: "hostScreen.deleteConfirm.removeFolderMessage",
            defaultValue: "Remove \"%1$@\" from Orca? The folder on disk is kept."), name)
        : String(
          format: String(localized: "hostScreen.hostScreenOverlays.deleteConfirmMessage", defaultValue: "Delete \"%1$@\" (%2$@)?"),
          name, worktree.branch.replacingOccurrences(of: "refs/heads/", with: "")),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "common.delete", defaultValue: "Delete"), style: .destructive) { [weak self] _ in
        self?.delete(worktree, name: name)
      })
    present(alert, animated: true)
  }

  private func delete(_ worktree: Worktree, name: String) {
    let session = session
    Task { [weak self] in
      do {
        try await session.api.removeWorkspace(id: worktree.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let alert = UIAlertController(
          title: String(
            format: String(localized: "hostScreen.hostScreenOverlays.deleteFailed", defaultValue: "Failed to delete \"%1$@\""),
            name),
          message: (error as? RPCError)?.message ?? error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        self?.present(alert, animated: true)
      }
      await session.refresh()
    }
  }
}
