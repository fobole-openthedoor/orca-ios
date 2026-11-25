import OrcaCore
import UIKit

/// One desktop's workspaces (host-screen/HostScreen.tsx): Bots, then each project's workspaces.
/// System chrome: large title with a connection subtitle, ⋯ menu, and a bottom toolbar with filter, search and +.
final class HostViewController: UIViewController {
  private enum Section: Hashable {
    case bots
    case remoteServers
    case project(String)
    /// A lane that isn't a project: `pinned`, `all`, `status:<id>` or `pr:<state>`.
    case lane(String)
  }

  private enum Item: Hashable {
    case bot(String)
    /// The bot's Home Chat, under its row while unfolded.
    case botHome(String)
    case botsEmpty
    case remoteServer(String)
    case worktree(String)
  }

  private struct WorkspacePlacement {
    let depth: Int
    let childCount: Int
  }

  private let session: HostSession
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
  private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
  private var collapsed: Set<String> = []
  private var foldedWorktrees: Set<String> = []
  private var foldedBots: Set<String> = []
  private var placements: [String: WorkspacePlacement] = [:]
  private var sectionCounts: [Section: Int] = [:]
  private var query = ""
  private var workspaceView = WorkspaceView()
  private var workspaceViewLoaded = false
  private var serversCollapsed = false
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
    if session.remoteServer == nil {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        image: Lucide.ellipsis.image(size: 20, strokeWidth: 2), menu: hostMenu())
      navigationItem.rightBarButtonItem?.accessibilityLabel = String(
        localized: "hostScreen.hostScreenHeader.moreActions", defaultValue: "More actions")
    }

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
    toolbarItems = [filter, navigationItem.searchBarPlacementBarButtonItem] + (session.remoteServer == nil ? [create] : [])

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
    let status = HostConnectionPresentation(session.connectionState, server: session.remoteServer)
    let subtitle = NSMutableAttributedString(
      string: "● ", attributes: [.foregroundColor: status.dot, .font: UIFont.systemFont(ofSize: 11)])
    let line = status.connected ? (session.status?.machineLine ?? status.label) : status.label
    subtitle.append(
      NSAttributedString(
        string: line, attributes: [.foregroundColor: status.connected ? Palette.textSecondary : status.labelColor]))
    navigationItem.attributedSubtitle = AttributedString(subtitle)
    // The menu follows the connection, the host's bots and its Floating Workspace setting.
    if let item = navigationItem.rightBarButtonItem { item.menu = hostMenu() }
    if status.connected, !workspaceViewLoaded { loadWorkspaceView() }
    applySnapshot()
  }

  private func reload() {
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
    let botHomes = Set(session.bots.bots.map(\.homeWorktreeId))
    var projects: [WorkspaceOptionsViewController.Project] = []
    for worktree in session.worktrees where !worktree.isArchived && !botHomes.contains(worktree.id) {
      guard !worktree.isFolderWorkspace, !projects.contains(where: { $0.id == worktree.repoId }) else { continue }
      projects.append(.init(id: worktree.repoId, name: session.repo(id: worktree.repoId)?.displayName ?? worktree.repo))
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

  private var visibleWorktrees: [Worktree] {
    let botHomes = Set(session.bots.bots.map(\.homeWorktreeId))
    let repoIds = Set(session.worktrees.map(\.repoId))
    let all = session.worktrees.filter {
      !botHomes.contains($0.id) && workspaceView.keeps($0, knownRepoIds: repoIds)
    }
    guard !query.isEmpty else { return all }
    let needle = query.lowercased()
    return all.filter {
      $0.displayName.lowercased().contains(needle) || $0.branch.lowercased().contains(needle)
        || $0.repo.lowercased().contains(needle)
    }
  }

  private var visibleServers: [HostSession] {
    let needle = query.lowercased()
    return session.remoteServers.filter { server in
      guard let id = server.remoteServer?.id, workspaceView.visibleHostIds?.contains(id) != false else { return false }
      return needle.isEmpty || server.name.lowercased().contains(needle) || server.worktrees.contains {
        !$0.isArchived && ($0.displayName.lowercased().contains(needle) || $0.repo.lowercased().contains(needle)
          || $0.branch.lowercased().contains(needle))
      }
    }
  }

  private func applySnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    // A search narrows the bots to the ones it names, and drops the section when none match.
    let needle = query.lowercased()
    let bots = session.bots.bots.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
    let servers = visibleServers
    // These reads let UIKit reconfigure a server row when its background catalog or connection changes.
    for server in servers {
      _ = (server.connectionState, server.worktrees, server.bots, server.isLoading, server.hasLiveWorktrees)
    }
    let sorted = workspaceView.sorted(visibleWorktrees)
    if session.remoteServer == nil ? (needle.isEmpty || !bots.isEmpty) : !bots.isEmpty {
      snapshot.appendSections([.bots])
      snapshot.appendItems(
        bots.isEmpty
          ? [.botsEmpty]
          : bots.flatMap { foldedBots.contains($0.id) ? [Item.bot($0.id)] : [.bot($0.id), .botHome($0.id)] },
        toSection: .bots)
    }
    if !servers.isEmpty {
      snapshot.appendSections([.remoteServers])
      if !serversCollapsed || !needle.isEmpty {
        snapshot.appendItems(servers.compactMap { $0.remoteServer.map { Item.remoteServer($0.id) } }, toSection: .remoteServers)
      }
    }
    contentUnavailableConfiguration = emptyConfiguration(hasItems: !bots.isEmpty || !sorted.isEmpty || !servers.isEmpty)
    let roots = Worktree.lineage(sorted)
    let pinned = roots.filter { $0.entry.isPinned }
    let worktrees = roots.filter { !$0.entry.isPinned }
    placements.removeAll(keepingCapacity: true)
    sectionCounts.removeAll(keepingCapacity: true)
    func append(_ branches: [LineageBranch<Worktree>], to section: Section, collapsed: Bool) {
      snapshot.appendSections([section])
      var items: [Item] = []
      var count = 0
      func visit(_ branch: LineageBranch<Worktree>, depth: Int, visible: Bool) {
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
    func lane(_ key: String, _ branches: [LineageBranch<Worktree>]) {
      guard !branches.isEmpty else { return }
      // Folder workspaces sit after the git ones.
      let ordered = branches.filter { !$0.entry.isFolderWorkspace } + branches.filter { $0.entry.isFolderWorkspace }
      append(ordered, to: .lane(key), collapsed: collapsed.contains(key))
    }
    lane("pinned", pinned)
    switch workspaceView.groupBy {
    case "repo":
      for repoId in projectOrder(worktrees) {
        var branches = worktrees.filter { $0.entry.repoId == repoId }
        // A project's own checkout leads its group unless the order is manual (section-order.ts).
        if workspaceView.sortBy != "manual" {
          branches = branches.filter { $0.entry.isMainWorktree } + branches.filter { !$0.entry.isMainWorktree }
        }
        append(branches, to: .project(repoId), collapsed: collapsed.contains(repoId))
      }
    case "workspace-status":
      for status in workspaceView.statuses {
        lane("status:\(status.id)", worktrees.filter { workspaceView.status(of: $0.entry) == status.id })
      }
    case "pr-status":
      for state in ["done", "in-review", "in-progress", "closed"] {
        lane("pr:\(state)", worktrees.filter { WorkspaceView.prLane(of: $0.entry) == state })
      }
    default:
      lane("all", worktrees)
    }
    snapshot.reconfigureItems(snapshot.itemIdentifiers)
    dataSource.apply(snapshot, animatingDifferences: view.window != nil) { [weak self] in self?.refreshHeaders() }
  }

  private func emptyConfiguration(hasItems: Bool) -> UIContentUnavailableConfiguration? {
    guard !hasItems else { return nil }
    if !query.isEmpty { return .search() }
    guard session.remoteServer != nil else { return nil }
    var configuration = session.isLoading && session.connectionState == .connected
      ? UIContentUnavailableConfiguration.loading() : .empty()
    if session.connectionState != .connected {
      configuration.text = HostConnectionPresentation(session.connectionState, server: session.remoteServer).label
    } else if !session.isLoading {
      configuration.text = session.hasLiveWorktrees
        ? String(localized: "worktree.hostWorkspaceListStates.empty", defaultValue: "No workspaces")
        : String(localized: "worktree.hostWorkspaceListStates.loadFailed", defaultValue: "Could not load workspaces from this host")
    }
    return configuration
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
  private func projectOrder(_ branches: [LineageBranch<Worktree>]) -> [String] {
    var order: [String] = []
    for branch in branches where !order.contains(branch.entry.repoId) { order.append(branch.entry.repoId) }
    guard workspaceView.projectOrderBy == "recent" else {
      let hostOrder = session.worktrees.map(\.repoId)
      return order.sorted { (hostOrder.firstIndex(of: $0) ?? 0) < (hostOrder.firstIndex(of: $1) ?? 0) }
    }
    func newest(_ branch: LineageBranch<Worktree>) -> Double {
      max(branch.entry.lastActivityAt ?? 0, branch.children.map(newest).max() ?? 0)
    }
    let latest = Dictionary(grouping: branches, by: \.entry.repoId).mapValues { $0.map(newest).max() ?? 0 }
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
    let worktreeCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
      guard let self, let worktree = self.session.worktree(id: id) else { return }
      // Grouped by project, the heading already names the project.
      let projectName =
        self.workspaceView.groupBy == "repo" ? (self.session.repo(id: worktree.repoId)?.displayName ?? worktree.repo) : nil
      let placement = self.placements[id]
      var configuration = WorkspaceRowConfiguration(
        worktree: worktree, projectName: projectName, depth: placement?.depth ?? 0,
        childCount: placement?.childCount ?? 0, childrenCollapsed: self.foldedWorktrees.contains(id))
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
    let remoteServerCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
      guard let server = self?.remoteSession(id: id) else { return }
      let status = HostConnectionPresentation(server.connectionState, server: server.remoteServer)
      let summary = status.connected && server.hasLiveWorktrees ? HostWorktreeSummary.text(for: server) : nil
      cell.contentConfiguration = TileRowConfiguration(
        icon: .server, title: server.name, subtitle: [(summary ?? status.label, status.labelColor)], dot: status.dot)
      cell.accessories = [.disclosureIndicator(options: .init(tintColor: Palette.textMuted))]
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgBase
      cell.backgroundConfiguration = background
    }
    let configureHeader = { [weak self] (header: WorkspaceSectionHeader, indexPath: IndexPath) in
      guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
      switch section {
      case .bots:
        header.configureBots(count: self.session.bots.bots.count) { [weak self] in self?.newBot() }
      case .remoteServers:
        header.configureLane(
          title: String(localized: "orcaios.host.remoteServers", defaultValue: "Remote Servers"),
          count: self.visibleServers.count, pinned: false, collapsed: self.serversCollapsed && self.query.isEmpty
        ) { [weak self] in
          guard let self, self.query.isEmpty else { return }
          self.serversCollapsed.toggle()
          self.applySnapshot()
        }
      case .project(let repoId):
        let name = self.session.repo(id: repoId)?.displayName ?? self.session.worktrees.first { $0.repoId == repoId }?.repo ?? repoId
        header.configureProject(name: name, count: self.sectionCounts[section] ?? 0, collapsed: self.collapsed.contains(repoId)) {
          [weak self] in self?.toggle(repoId)
        }
      case .lane(let key):
        header.configureLane(title: self.laneTitle(key), count: self.sectionCounts[section] ?? 0, pinned: key == "pinned", collapsed: self.collapsed.contains(key)) {
          [weak self] in self?.toggleLane(key)
        }
      }
    }
    self.configureHeader = configureHeader
    let header = UICollectionView.SupplementaryRegistration<WorkspaceSectionHeader>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { header, _, indexPath in configureHeader(header, indexPath) }
    let botCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
      guard let self, let bot = self.session.bots.bots.first(where: { $0.id == id }) else { return }
      var configuration = BotRowConfiguration.make(bot: bot, session: self.session, showHost: false)
      configuration.unfolded = !self.foldedBots.contains(id)
      configuration.onToggle = { [weak self] in self?.toggleBot(id) }
      cell.contentConfiguration = configuration
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgBase
      cell.backgroundConfiguration = background
    }
    let homeCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
      guard let self, let bot = self.session.bots.bots.first(where: { $0.id == id }) else { return }
      cell.contentConfiguration = BotHomeChatRowConfiguration(
        updatedAt: BotRowConfiguration.make(bot: bot, session: self.session, showHost: false).updatedAt)
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
      case .remoteServer(let id): collection.dequeueConfiguredReusableCell(using: remoteServerCell, for: indexPath, item: id)
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
    UISelectionFeedbackGenerator().selectionChanged()
    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    applySnapshot()
    var snapshot = dataSource.snapshot()
    snapshot.reloadSections([.lane(key)])
    dataSource.apply(snapshot, animatingDifferences: true)
  }

  private func toggleBot(_ id: String) {
    if foldedBots.contains(id) { foldedBots.remove(id) } else { foldedBots.insert(id) }
    applySnapshot()
  }

  private func toggleChildren(of id: String) {
    UISelectionFeedbackGenerator().selectionChanged()
    if foldedWorktrees.contains(id) { foldedWorktrees.remove(id) } else { foldedWorktrees.insert(id) }
    applySnapshot()
  }

  private func toggle(_ repoId: String) {
    UISelectionFeedbackGenerator().selectionChanged()
    if collapsed.contains(repoId) { collapsed.remove(repoId) } else { collapsed.insert(repoId) }
    applySnapshot()
    var snapshot = dataSource.snapshot()
    snapshot.reloadSections([.project(repoId)])
    dataSource.apply(snapshot, animatingDifferences: true)
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

  private func open(_ worktree: Worktree) {
    navigationController?.pushViewController(SessionViewController(session: session, worktreeId: worktree.id), animated: true)
  }

  private func remoteSession(id: String) -> HostSession? {
    session.remoteServers.first { $0.remoteServer?.id == id }
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
    case .remoteServer(let id):
      if let server = remoteSession(id: id) { push(HostViewController(session: server)) }
    case .worktree(let id):
      if let worktree = session.worktree(id: id) { open(worktree) }
    case .bot(let id), .botHome(let id):
      if let bot = session.bots.bots.first(where: { $0.id == id }) {
        BotDirectory.open(bot, in: session, from: navigationController)
      }
    default:
      break
    }
  }

  func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
    switch dataSource.itemIdentifier(for: indexPath) {
    case .remoteServer, .worktree, .bot, .botHome: return true
    default: return false
    }
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first, case .worktree(let id) = dataSource.itemIdentifier(for: indexPath),
      let worktree = session.worktree(id: id)
    else { return nil }
    let api = session.api
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      let pin = UIAction(
        title: worktree.isPinned
          ? String(localized: "hostScreen.hostScreenOverlays.unpin", defaultValue: "Unpin")
          : String(localized: "hostScreen.hostScreenOverlays.pin", defaultValue: "Pin"),
        image: (worktree.isPinned ? Lucide.pinOff : Lucide.pin).image(size: 18)
      ) { _ in Task { try? await api.setPinned(!worktree.isPinned, worktree: worktree.selector) } }
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
