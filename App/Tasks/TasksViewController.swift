import OrcaCore
import UIKit

/// Tasks (tasks/MobileTasksScreen.tsx) for one desktop: the bar (Tasks over the host, Refresh), the source switch
/// (GitHub, Linear, Jira), one row of scope chips, the list, and search with New issue at the bottom.
final class TasksViewController: UIViewController {
  /// Called after "Create Workspace" made one, with its host and id, so the caller can open it.
  var onOpenWorkspace: ((HostSession, String) -> Void)?

  private enum Provider: Int, CaseIterable {
    case github, linear, jira

    var label: String {
      switch self {
      case .github: "GitHub"
      case .linear: "Linear"
      case .jira: "Jira"
      }
    }
  }

  enum Sort: String { case updated, repository }

  /// tasks/task-list/mobile-tasks-options.tsx LINEAR_FILTER_OPTIONS.
  private static let linearFilters: [(value: String, title: String, subtitle: String)] = [
    (
      "all", String(localized: "tasks.options.all", defaultValue: "All"),
      String(localized: "tasks.options.linearAllDescription", defaultValue: "Open issues across connected workspaces")
    ),
    (
      "assigned", String(localized: "tasks.options.myIssues", defaultValue: "My Issues"),
      String(localized: "tasks.options.linearAssignedDescription", defaultValue: "Issues assigned to you")
    ),
    (
      "created", String(localized: "tasks.options.createdState", defaultValue: "Created"),
      String(localized: "tasks.options.linearCreatedDescription", defaultValue: "Issues created by you")
    ),
    (
      "completed", String(localized: "tasks.options.completedState", defaultValue: "Completed"),
      String(localized: "tasks.options.linearCompletedDescription", defaultValue: "Recently completed issues")
    ),
  ]

  /// JIRA_FILTER_OPTIONS: the labels are English in the official app too.
  private static let jiraFilters: [(value: String, title: String, subtitle: String)] = [
    (
      "assigned", "My Issues",
      String(localized: "tasks.taskViewOptions.assignedSubtitle", defaultValue: "Unresolved issues assigned to you")
    ),
    (
      "reported", "Reported",
      String(localized: "tasks.taskViewOptions.reportedSubtitle", defaultValue: "Unresolved issues you reported")
    ),
    (
      "all", "All",
      String(localized: "tasks.taskViewOptions.allSubtitle", defaultValue: "Unresolved issues across the selected sites")
    ),
    ("done", "Done", String(localized: "tasks.taskViewOptions.doneSubtitle", defaultValue: "Your recently resolved issues")),
  ]

  private let session: HostSession
  private let providerControl = UISegmentedControl()
  private let chipRow = UIStackView()
  private let chipScroll = UIScrollView()
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let search = UISearchController(searchResultsController: nil)
  private var refreshItem: UIBarButtonItem!
  private var createItem: UIBarButtonItem!

  private var provider: Provider = .github
  private var preset: GitHubTaskPreset = .issues
  private var sort: Sort = .updated
  /// The search sent: GitHub's starts as the preset's own query and shows in the field.
  private var appliedQuery = GitHubTaskPreset.issues.query
  private var linearFilter = "all"
  private var jiraFilter = "assigned"
  private var repos: [TaskRepo] = []
  /// Empty: every repository.
  private var selectedRepoIds: Set<String> = []
  private var items: [GitHubWorkItem] = []
  private var sections: [(title: String?, items: [GitHubWorkItem])] = []
  private var issues: [TrackerIssue] = []
  /// nil until the desktop answers.
  private var linearConnected: Bool?
  private var jiraConnected: Bool?
  private var loading = false
  private var loadError: String?
  private var loadedKey: String?
  private var loadTask: Task<Void, Never>?

  init(session: HostSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
    // The host's own page stack: no tab bar under it.
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "tasks.screenChrome.title", defaultValue: "Tasks")
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .never

    // These pages have no pull-to-refresh, so Refresh stays in the bar.
    refreshItem = UIBarButtonItem(
      image: Lucide.refreshCw.image(size: 20), primaryAction: UIAction { [weak self] _ in self?.reload(force: true) })
    navigationItem.rightBarButtonItem = refreshItem

    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.autocapitalizationType = .none
    search.searchBar.autocorrectionType = .no
    search.searchBar.delegate = self
    search.searchBar.text = appliedQuery
    navigationItem.searchController = search
    navigationItem.preferredSearchBarPlacement = .integrated
    navigationItem.searchBarPlacementAllowsToolbarIntegration = true
    navigationItem.hidesSearchBarWhenScrolling = false
    createItem = UIBarButtonItem(image: Lucide.plus.image(size: 20, strokeWidth: 2.2), style: .prominent, target: nil, action: nil)
    createItem.primaryAction = UIAction(image: Lucide.plus.image(size: 20, strokeWidth: 2.2)) { [weak self] _ in
      self?.newIssue()
    }
    createItem.tintColor = Palette.createActionFill
    toolbarItems = [navigationItem.searchBarPlacementBarButtonItem, createItem]

    for provider in Provider.allCases {
      providerControl.insertSegment(withTitle: provider.label, at: provider.rawValue, animated: false)
    }
    providerControl.selectedSegmentIndex = provider.rawValue
    providerControl.addAction(
      UIAction { [weak self] _ in
        guard let self, let next = Provider(rawValue: self.providerControl.selectedSegmentIndex) else { return }
        self.select(next)
      }, for: .valueChanged)

    chipRow.axis = .horizontal
    chipRow.spacing = Spacing.sm
    chipRow.distribution = .fillProportionally
    chipRow.translatesAutoresizingMaskIntoConstraints = false
    chipScroll.showsHorizontalScrollIndicator = false
    chipScroll.translatesAutoresizingMaskIntoConstraints = false
    chipScroll.addSubview(chipRow)

    let chrome = UIStackView(arrangedSubviews: [providerControl, chipScroll])
    chrome.axis = .vertical
    chrome.spacing = Spacing.sm
    chrome.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(chrome)

    table.backgroundColor = Palette.bgBase
    table.dataSource = self
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "item")
    table.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(table, belowSubview: chrome)

    NSLayoutConstraint.activate([
      chrome.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
      chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
      chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
      providerControl.heightAnchor.constraint(equalToConstant: 36),
      chipScroll.heightAnchor.constraint(equalToConstant: 32),
      chipRow.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
      chipRow.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
      chipRow.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
      chipRow.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
      chipRow.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
      // The chips share the row when they fit and scroll when they don't.
      chipRow.widthAnchor.constraint(greaterThanOrEqualTo: chipScroll.frameLayoutGuide.widthAnchor),
      table.topAnchor.constraint(equalTo: chrome.bottomAnchor, constant: Spacing.sm),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    let divider = Hairline()
    divider.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(divider)
    NSLayoutConstraint.activate([
      divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      divider.topAnchor.constraint(equalTo: table.topAnchor),
    ])
    updateChrome()
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
    let status = HostConnectionPresentation(session.connectionState)
    let subtitle = NSMutableAttributedString(
      string: "● ", attributes: [.foregroundColor: status.dot, .font: UIFont.systemFont(ofSize: 11)])
    subtitle.append(NSAttributedString(string: session.name, attributes: [.foregroundColor: Palette.textSecondary]))
    navigationItem.attributedSubtitle = AttributedString(subtitle)
    if session.connectionState == .connected {
      if loadedKey == nil { reload() }
    } else {
      showState()
    }
  }

  // MARK: Chrome

  private func select(_ next: Provider) {
    guard next != provider else { return }
    provider = next
    items = []
    issues = []
    sections = []
    loadError = nil
    appliedQuery = next == .github ? preset.query : ""
    search.searchBar.text = appliedQuery
    updateChrome()
    reload()
  }

  /// The placeholder, New issue and the chips for the current source.
  private func updateChrome() {
    search.searchBar.placeholder =
      provider == .jira
      ? String(localized: "auto.components.TaskPage.99c2755218", defaultValue: "Search issues or enter JQL, e.g. project = ABC")
      : String(
        format: String(localized: "tasks.searchControl.providerPlaceholder", defaultValue: "Search %@ tasks..."),
        provider.label)
    switch provider {
    case .github:
      refreshItem.accessibilityLabel = String(localized: "tasks.screenChrome.refreshGitHub", defaultValue: "Refresh GitHub work")
    case .linear:
      refreshItem.accessibilityLabel = String(localized: "tasks.screenChrome.refreshLinear", defaultValue: "Refresh Linear")
    case .jira:
      refreshItem.accessibilityLabel = String(localized: "tasks.screenChrome.refreshJira", defaultValue: "Refresh Jira issues")
    }
    createItem.accessibilityLabel = String(localized: "tasks.screenChrome.newGitHubIssue", defaultValue: "New GitHub issue")
    // Unconnected sources have nothing to search; New issue files GitHub issues.
    let connected = provider == .github || (provider == .linear ? linearConnected : jiraConnected) == true
    toolbarItems =
      connected
      ? (provider == .github ? [navigationItem.searchBarPlacementBarButtonItem, createItem] : [navigationItem.searchBarPlacementBarButtonItem])
      : []
    if isViewLoaded, view.window != nil { navigationController?.setToolbarHidden(!connected, animated: true) }
    rebuildChips(connected: connected)
  }

  private func rebuildChips(connected: Bool) {
    chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
    chipScroll.isHidden = !connected
    guard connected else { return }
    switch provider {
    case .github:
      chipRow.addArrangedSubview(repoChip())
      let kind = preset.isPullRequests
      chipRow.addArrangedSubview(
        Self.chip(
          kind
            ? String(localized: "tasks.providerViewProjection.pullRequests", defaultValue: "PRs")
            : String(localized: "tasks.providerViewProjection.issues", defaultValue: "Issues"),
          menu: UIMenu(
            title: String(localized: "tasks.providerPickers.githubView", defaultValue: "GitHub View"),
            children: [
              UIAction(
                title: String(localized: "tasks.options.issues", defaultValue: "Issues"),
                subtitle: String(localized: "tasks.options.githubIssuesDescription", defaultValue: "GitHub issues"),
                state: kind ? .off : .on
              ) { [weak self] _ in self?.apply(.issues) },
              UIAction(
                title: String(localized: "tasks.options.pullRequests", defaultValue: "PRs"),
                subtitle: String(
                  localized: "tasks.options.githubPullRequestsDescription", defaultValue: "GitHub pull requests"),
                state: kind ? .on : .off
              ) { [weak self] _ in self?.apply(.prs) },
            ])))
      let presets = Self.presets(pullRequests: kind)
      chipRow.addArrangedSubview(
        Self.chip(
          presets.first { $0.0 == preset }?.1 ?? String(localized: "tasks.options.openState", defaultValue: "Open"),
          menu: UIMenu(
            title: kind
              ? String(localized: "tasks.providerPickers.pullRequests", defaultValue: "Pull Requests")
              : String(localized: "tasks.providerPickers.issues", defaultValue: "Issues"),
            children: presets.map { value, title, subtitle in
              UIAction(title: title, subtitle: subtitle, state: preset == value ? .on : .off) { [weak self] _ in
                self?.apply(value)
              }
            })))
      let count = sort == .updated ? 0 : 1
      let filter = Self.chip(
        count > 0
          ? String(
            format: String(localized: "tasks.providerControls.filterCount", defaultValue: "Filter · %lld"), count)
          : String(localized: "tasks.providerControls.filter", defaultValue: "Filter"),
        icon: .slidersHorizontal, active: count > 0)
      filter.accessibilityLabel = String(localized: "tasks.providerControls.filterLabel", defaultValue: "Filter and display")
      filter.addAction(UIAction { [weak self] _ in self?.showFilterSheet() }, for: .primaryActionTriggered)
      chipRow.addArrangedSubview(filter)
    case .linear:
      chipRow.addArrangedSubview(
        filterChip(
          Self.linearFilters, selected: linearFilter,
          title: String(localized: "tasks.filterPickers.linearFilter", defaultValue: "Linear Filter")
        ) { [weak self] value in self?.linearFilter = value })
    case .jira:
      chipRow.addArrangedSubview(
        filterChip(
          Self.jiraFilters, selected: jiraFilter,
          title: String(localized: "tasks.filterPickers.jiraFilter", defaultValue: "Jira Filter")
        ) { [weak self] value in self?.jiraFilter = value })
    }
  }

  /// "Open", "Assigned to me"… for issues; "Open", "Mine", "Needs review" for pull requests.
  private static func presets(pullRequests: Bool) -> [(GitHubTaskPreset, String, String)] {
    pullRequests
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
  }

  /// A preset sets the search to its own query, as picking one does on the official screen.
  private func apply(_ next: GitHubTaskPreset) {
    preset = next
    appliedQuery = next.query
    search.searchBar.text = appliedQuery
    updateChrome()
    reload()
  }

  private func repoChip() -> UIButton {
    let label: String
    let picked = repos.filter { selectedRepoIds.contains($0.id) }
    if selectedRepoIds.isEmpty || selectedRepoIds.count == repos.count {
      label = String(localized: "tasks.pickerProjection.allRepos", defaultValue: "All repos")
    } else if picked.count == 1 {
      label = picked[0].displayName
    } else {
      label = String.localizedStringWithFormat(
        String(localized: "tasks.pickerProjection.repos", defaultValue: "%lld repos"), selectedRepoIds.count)
    }
    let all = UIAction(
      title: String(localized: "tasks.providerPickers.allRepositories", defaultValue: "All repositories"),
      state: selectedRepoIds.isEmpty ? .on : .off
    ) { [weak self] _ in
      self?.selectedRepoIds = []
      self?.updateChrome()
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
        self.updateChrome()
        self.reload()
      }
    }
    let chip = Self.chip(
      label, active: !selectedRepoIds.isEmpty,
      menu: UIMenu(
        title: String(localized: "tasks.providerPickers.repos", defaultValue: "Repositories"),
        subtitle: String(
          localized: "tasks.providerPickers.repoDescription", defaultValue: "Choose which repositories to query."),
        children: [UIMenu(options: .displayInline, children: [all]), UIMenu(options: .displayInline, children: each)]))
    chip.accessibilityLabel = String(
      format: String(localized: "tasks.providerControls.reposLabel", defaultValue: "Repositories: %@"), label)
    return chip
  }

  private func filterChip(
    _ options: [(value: String, title: String, subtitle: String)], selected: String, title: String,
    onPick: @escaping (String) -> Void
  ) -> UIButton {
    Self.chip(
      options.first { $0.value == selected }?.title ?? options[0].title,
      menu: UIMenu(
        title: title,
        children: options.map { option in
          UIAction(title: option.title, subtitle: option.subtitle, state: option.value == selected ? .on : .off) {
            [weak self] _ in
            onPick(option.value)
            self?.appliedQuery = ""
            self?.search.searchBar.text = ""
            self?.updateChrome()
            self?.reload()
          }
        }))
  }

  /// components/nav-bar/FilterChip.tsx: a 32 pt capsule on the raised fill, a ring when it narrows the list, a
  /// chevron when it opens a menu.
  private static func chip(_ title: String, icon: Lucide? = nil, active: Bool = false, menu: UIMenu? = nil) -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.baseBackgroundColor = Palette.bgRaised
    configuration.baseForegroundColor = active ? Palette.textPrimary : Palette.textSecondary
    configuration.background.strokeColor = active ? Palette.textSecondary : .clear
    configuration.background.strokeWidth = 1
    configuration.contentInsets = .init(
      top: 0, leading: icon == nil ? Spacing.md : Spacing.sm, bottom: 0, trailing: menu == nil ? Spacing.md : Spacing.sm)
    var attributes = AttributeContainer()
    attributes.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    configuration.attributedTitle = AttributedString(title, attributes: attributes)
    configuration.titleLineBreakMode = .byTruncatingTail
    if let icon {
      configuration.image = icon.image(size: 15, strokeWidth: 2.2)
      configuration.imagePlacement = .leading
    } else if menu != nil {
      configuration.image = Lucide.chevronDown.image(size: 14, strokeWidth: 2.2)
        .withTintColor(Palette.textMuted, renderingMode: .alwaysOriginal)
      configuration.imagePlacement = .trailing
    }
    configuration.imagePadding = Spacing.xs
    let button = UIButton(configuration: configuration)
    if let menu {
      button.menu = menu
      button.showsMenuAsPrimaryAction = true
    }
    button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    return button
  }

  private func showFilterSheet() {
    let sheet = TaskFilterSheetViewController(sort: sort) { [weak self] sort in
      self?.sort = sort
      self?.updateChrome()
      self?.rebuildSections()
    }
    let navigation = UINavigationController(rootViewController: sheet)
    navigation.sheetPresentationController?.detents = [.medium(), .large()]
    navigation.sheetPresentationController?.prefersGrabberVisible = true
    present(navigation, animated: true)
  }

  private func newIssue() {
    guard !repos.isEmpty else { return }
    let api = session.api
    let compose = NewGitHubIssueViewController(repos: repos, selected: selectedRepoIds) { repo, title, body in
      try await api.createGitHubIssue(repoId: repo.id, title: title, body: body)
    } onCreated: { [weak self] in
      self?.reload(force: true)
    }
    let navigation = UINavigationController(rootViewController: compose)
    navigation.sheetPresentationController?.detents = [.large()]
    navigation.sheetPresentationController?.prefersGrabberVisible = true
    present(navigation, animated: true)
  }

  // MARK: Loading

  private var requestKey: String {
    "\(provider.rawValue)|\(appliedQuery)|\(linearFilter)|\(jiraFilter)|\(selectedRepoIds.sorted().joined(separator: ","))"
  }

  private func reload(force: Bool = false) {
    guard session.connectionState == .connected else {
      showState()
      return
    }
    loadedKey = requestKey
    loadTask?.cancel()
    loading = true
    loadError = nil
    // A new view or search starts empty; Refresh keeps the rows up while it reads.
    if !force {
      items = []
      issues = []
    }
    rebuildSections()
    switch provider {
    case .github: loadGitHub(force: force)
    case .linear, .jira: loadTracker()
    }
  }

  private func loadGitHub(force: Bool) {
    let key = requestKey
    let api = session.api
    let query = appliedQuery
    let knownRepos = force ? [] : repos
    let selected = selectedRepoIds
    loadTask = Task { [weak self] in
      do {
        let repos = knownRepos.isEmpty ? try await api.taskRepos() : knownRepos
        guard !Task.isCancelled else { return }
        if self?.repos != repos {
          self?.repos = repos
          self?.updateChrome()
        }
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

  /// Linear and Jira: whether the desktop has the account, then its issues for the filter or search.
  private func loadTracker() {
    let key = requestKey
    let api = session.api
    let provider = provider
    let query = appliedQuery
    let filter = provider == .linear ? linearFilter : jiraFilter
    loadTask = Task { [weak self] in
      do {
        let connected = provider == .linear ? try await api.linearConnected() : try await api.jiraConnected()
        guard !Task.isCancelled, let self else { return }
        let changed = (provider == .linear ? self.linearConnected : self.jiraConnected) != connected
        if provider == .linear { self.linearConnected = connected } else { self.jiraConnected = connected }
        if changed { self.updateChrome() }
        guard connected else {
          self.finishTracker([], error: nil, key: key)
          return
        }
        let issues =
          provider == .linear
          ? try await api.linearIssues(filter: filter, query: query)
          : try await api.jiraIssues(filter: filter, query: query)
        guard !Task.isCancelled else { return }
        self.finishTracker(issues, error: nil, key: key)
      } catch {
        guard !Task.isCancelled else { return }
        self?.finishTracker([], error: Self.message(error), key: key)
      }
    }
  }

  private func finish(items: [GitHubWorkItem], error: String?, key: String) {
    guard key == loadedKey else { return }
    loading = false
    loadError = error
    // Host pages come in issue-number order; merge them the same way so rows don't reshuffle.
    self.items = items.sorted { $0.number > $1.number }
    rebuildSections()
  }

  private func finishTracker(_ issues: [TrackerIssue], error: String?, key: String) {
    guard key == loadedKey else { return }
    loading = false
    loadError = error
    self.issues = issues
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

  private var rowCount: Int { provider == .github ? items.count : issues.count }

  private func showState() {
    guard isViewLoaded else { return }
    var config: UIContentUnavailableConfiguration?
    let trackerConnected = provider == .linear ? linearConnected : jiraConnected
    if session.connectionState != .connected {
      config = .empty()
      config?.image = Lucide.wifiOff.image(size: 24, strokeWidth: 1.75)
      config?.text = String(
        format: String(localized: "common.offline.waitingFor", defaultValue: "Waiting for %@"), session.name)
      config?.secondaryText = String(
        localized: "common.offline.message", defaultValue: "Check that the host is awake and Orca is running.")
    } else if loading && rowCount == 0 {
      config = .loading()
      config?.text = String(localized: "tasks.listState.loading", defaultValue: "Loading tasks…")
    } else if provider == .linear, trackerConnected == false {
      config = .empty()
      config?.image = Lucide.listTodo.image(size: 24, strokeWidth: 1.75)
      config?.text = String(localized: "tasks.listSurface.connectLinearTitle", defaultValue: "Connect your Linear account")
      config?.secondaryText = String(
        localized: "tasks.listSurface.connectLinearMessage",
        defaultValue: "Browse and start work on your assigned Linear issues directly from Tasks.")
      var connect = UIButton.Configuration.glass()
      connect.title = String(localized: "tasks.listSurface.connectLinearButton", defaultValue: "Connect Linear")
      config?.button = connect
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.connectLinear() }
    } else if provider == .jira, trackerConnected == false {
      config = .empty()
      config?.image = Lucide.listTodo.image(size: 24, strokeWidth: 1.75)
      config?.text = String(localized: "components.jiraConnectPrompt.connectOnDesktop", defaultValue: "Connect Jira on your desktop")
      config?.secondaryText = String(
        localized: "components.jiraConnectPrompt.connectHint",
        defaultValue: "Add your Jira site in Orca desktop under Settings → Integrations, then check again.")
      var check = UIButton.Configuration.glass()
      check.title = String(localized: "components.jiraConnectPrompt.checkAgain", defaultValue: "Check again")
      config?.button = check
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload(force: true) }
    } else if let loadError, rowCount == 0 {
      config = .empty()
      config?.image = Lucide.circleAlert.image(size: 24, strokeWidth: 1.75)
      config?.text = String(localized: "common.loadError.title", defaultValue: "Unable to Load")
      config?.secondaryText = loadError
      var retry = UIButton.Configuration.glass()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config?.button = retry
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload(force: true) }
    } else if rowCount == 0, !loading {
      config = .empty()
      config?.image = Lucide.inbox.image(size: 24, strokeWidth: 1.75)
      let searched = provider == .github ? appliedQuery != preset.query : !appliedQuery.isEmpty
      let empty =
        switch provider {
        case .github: String(localized: "tasks.taskViewOptions.noGitHubTasks", defaultValue: "No GitHub tasks")
        case .linear: String(localized: "tasks.taskViewOptions.noLinearTasks", defaultValue: "No Linear tasks")
        case .jira: String(localized: "tasks.taskViewOptions.noJiraTasks", defaultValue: "No Jira tasks")
        }
      config?.text =
        searched ? String(localized: "tasks.connectionPresentation.noMatchingTasks", defaultValue: "No matching tasks") : empty
    }
    // components/feedback/MobileStateView.tsx: a 24 pt muted glyph over a 15 pt semibold title.
    config?.imageProperties.tintColor = Palette.textMuted
    config?.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
    config?.textProperties.color = Palette.textPrimary
    config?.secondaryTextProperties.font = .systemFont(ofSize: 13)
    config?.secondaryTextProperties.color = Palette.textSecondary
    // Behind the list, so the source switch and chips above it stay live.
    table.backgroundView = config.map { UIContentUnavailableView(configuration: $0) }
  }

  private func connectLinear() {
    let alert = UIAlertController(
      title: String(localized: "tasks.tasksCreateDrawers.connectLinearWorkspace", defaultValue: "Connect Linear workspace"),
      message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = String(localized: "tasks.tasksCreateDrawers.personalApiKey", defaultValue: "Personal API key")
      field.isSecureTextEntry = true
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "tasks.tasksCreateDrawers.connect", defaultValue: "Connect"), style: .default) {
        [weak self, weak alert] _ in
        let key = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let self, !key.isEmpty else { return }
        let api = self.session.api
        Task {
          do {
            try await api.connectLinear(apiKey: key)
            self.reload(force: true)
          } catch {
            let failed = UIAlertController(title: nil, message: Self.message(error), preferredStyle: .alert)
            failed.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
            self.present(failed, animated: true)
          }
        }
      })
    present(alert, animated: true)
  }
}

extension TasksViewController: UISearchBarDelegate {
  // Typing is a draft; Search sends it, as the official bottom bar does.
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    let text = searchBar.text ?? ""
    appliedQuery = provider == .github ? preset.scoped(text) : text.trimmingCharacters(in: .whitespacesAndNewlines)
    searchBar.text = appliedQuery
    searchBar.resignFirstResponder()
    reload()
  }

  // Clearing GitHub's search puts the preset's query back; the others go unfiltered.
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    guard searchText.isEmpty, !searchBar.isFirstResponder else { return }
    clearSearch()
  }

  func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    clearSearch()
  }

  private func clearSearch() {
    let cleared = provider == .github ? preset.query : ""
    search.searchBar.text = cleared
    guard appliedQuery != cleared else { return }
    appliedQuery = cleared
    reload()
  }
}

extension TasksViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int { provider == .github ? sections.count : (issues.isEmpty ? 0 : 1) }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    provider == .github ? sections[section].items.count : issues.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    provider == .github ? sections[section].title : nil
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.textProperties.font = .systemFont(ofSize: 16)
    content.textProperties.numberOfLines = 2
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.font = .systemFont(ofSize: 13)
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    cell.backgroundColor = Palette.bgPanel
    cell.accessoryType = .disclosureIndicator
    guard provider == .github else {
      let issue = issues[indexPath.row]
      content.text = issue.title
      var meta = [issue.identifier]
      if let state = issue.state { meta.append(state) }
      content.secondaryText = meta.joined(separator: " · ")
      content.image = Lucide.circleDot.image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
      cell.contentConfiguration = content
      cell.accessibilityLabel = "\(issue.identifier), \(issue.title)"
      return cell
    }
    let item = sections[indexPath.section].items[indexPath.row]
    content.text = item.title
    var meta = ["\(item.repoName) #\(item.number)"]
    if let author = item.author, !author.isEmpty { meta.append(author) }
    if let date = item.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) { meta.append(age) }
    content.secondaryText = meta.joined(separator: " · ")
    let glyph = TaskStateGlyph(item)
    content.image = glyph.icon.image(size: 18)
    content.imageProperties.tintColor = glyph.color
    cell.contentConfiguration = content
    cell.accessibilityLabel = "\(item.title), \(glyph.label)"
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    guard provider == .github else {
      if let url = URL(string: issues[indexPath.row].url) { UIApplication.shared.open(url) }
      return
    }
    let item = sections[indexPath.section].items[indexPath.row]
    let detail = TaskDetailViewController(session: session, item: item)
    detail.onOpenWorkspace = onOpenWorkspace
    navigationController?.pushViewController(detail, animated: true)
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    guard provider == .github else { return nil }
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

/// Filter & display (screen/mobile-tasks-filter-sheet.tsx) for GitHub's lists: Sort by, applied as it is tapped.
private final class TaskFilterSheetViewController: UITableViewController {
  private var sort: TasksViewController.Sort
  private let onChange: (TasksViewController.Sort) -> Void
  private let options: [(TasksViewController.Sort, String, String)] = [
    (
      .updated, String(localized: "tasks.options.updated", defaultValue: "Updated"),
      String(localized: "tasks.options.updatedSortDescription", defaultValue: "Newest activity first")
    ),
    (
      .repository, String(localized: "tasks.options.repository", defaultValue: "Repository"),
      String(localized: "tasks.options.repositorySortDescription", defaultValue: "Group by repository, then newest activity")
    ),
  ]

  init(sort: TasksViewController.Sort, onChange: @escaping (TasksViewController.Sort) -> Void) {
    self.sort = sort
    self.onChange = onChange
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "tasks.filterSheet.title", defaultValue: "Filter & display")
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: String(localized: "tasks.filterSheet.done", defaultValue: "Done"), style: .done, target: nil, action: nil)
    navigationItem.rightBarButtonItem?.primaryAction = UIAction(
      title: String(localized: "tasks.filterSheet.done", defaultValue: "Done")
    ) { [weak self] _ in self?.dismiss(animated: true) }
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "option")
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { options.count }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    String(localized: "tasks.filterSheet.sortBy", defaultValue: "Sort by")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let (value, title, subtitle) = options[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "option", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = title
    content.secondaryText = subtitle
    content.secondaryTextProperties.color = Palette.textSecondary
    cell.contentConfiguration = content
    cell.accessoryType = value == sort ? .checkmark : .none
    cell.tintColor = Palette.textPrimary
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    sort = options[indexPath.row].0
    onChange(sort)
    tableView.reloadData()
  }
}

/// New GitHub Issue (workspace-creation/mobile-tasks-create-drawers.tsx): the repository, a title and a description.
private final class NewGitHubIssueViewController: UITableViewController {
  private let repos: [TaskRepo]
  private var repo: TaskRepo
  private let create: (TaskRepo, String, String) async throws -> Int?
  private let onCreated: () -> Void
  private let titleField = UITextField()
  private let bodyView = UITextView()
  private var creating = false

  init(
    repos: [TaskRepo], selected: Set<String>, create: @escaping (TaskRepo, String, String) async throws -> Int?,
    onCreated: @escaping () -> Void
  ) {
    self.repos = repos
    repo = repos.first { selected.contains($0.id) } ?? repos[0]
    self.create = create
    self.onCreated = onCreated
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(
      format: String(localized: "tasks.tasksCreateDrawers.newIssueTitle", defaultValue: "New %@ Issue"), "GitHub")
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    let submit = UIBarButtonItem(
      title: String(localized: "tasks.tasksCreateDrawers.createIssue", defaultValue: "Create Issue"), style: .prominent,
      target: nil, action: nil)
    submit.primaryAction = UIAction(
      title: String(localized: "tasks.tasksCreateDrawers.createIssue", defaultValue: "Create Issue")
    ) { [weak self] _ in self?.submit() }
    navigationItem.rightBarButtonItem = submit
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    titleField.placeholder = String(localized: "tasks.tasksCreateDrawers.titlePlaceholder", defaultValue: "Task title")
    titleField.font = .systemFont(ofSize: 17)
    titleField.addAction(UIAction { [weak self] _ in self?.updateSubmit() }, for: .editingChanged)
    bodyView.font = .systemFont(ofSize: 17)
    bodyView.backgroundColor = .clear
    bodyView.textContainerInset = .zero
    bodyView.textContainer.lineFragmentPadding = 0
    updateSubmit()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    titleField.becomeFirstResponder()
  }

  private var issueTitle: String { (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

  private func updateSubmit() {
    navigationItem.rightBarButtonItem?.isEnabled = !issueTitle.isEmpty && !creating
  }

  private func submit() {
    guard !issueTitle.isEmpty, !creating else { return }
    creating = true
    updateSubmit()
    let repo = repo
    let title = issueTitle
    let body = bodyView.text ?? ""
    Task {
      do {
        _ = try await create(repo, title, body)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true) { self.onCreated() }
      } catch {
        creating = false
        updateSubmit()
        let alert = UIAlertController(title: nil, message: TasksViewController.message(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
    }
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 3 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0: String(localized: "tasks.tasksCreateDrawers.repository", defaultValue: "Repository")
    case 1: String(localized: "tasks.tasksCreateDrawers.title", defaultValue: "Title")
    default: String(localized: "tasks.tasksCreateDrawers.description", defaultValue: "Description")
    }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .none
    cell.contentView.subviews.filter { $0 === titleField || $0 === bodyView || $0 is UIButton }.forEach {
      $0.removeFromSuperview()
    }
    cell.contentConfiguration = nil
    cell.accessoryView = nil
    switch indexPath.section {
    case 0:
      var content = UIListContentConfiguration.valueCell()
      content.text = repo.displayName
      cell.contentConfiguration = content
      let picker = UIButton(type: .system)
      picker.showsMenuAsPrimaryAction = true
      picker.menu = UIMenu(
        children: repos.map { choice in
          UIAction(title: choice.displayName, state: choice.id == repo.id ? .on : .off) { [weak self] _ in
            self?.repo = choice
            self?.tableView.reloadSections([0], with: .none)
          }
        })
      picker.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(picker)
      picker.pin(to: cell.contentView)
      let chevrons = UIImageView(image: Lucide.chevronsUpDown.image(size: 14))
      chevrons.tintColor = Palette.textMuted
      cell.accessoryView = chevrons
    case 1:
      embed(titleField, in: cell, height: 44)
    default:
      bodyView.text = bodyView.text
      embed(bodyView, in: cell, height: 140)
    }
    return cell
  }

  private func embed(_ field: UIView, in cell: UITableViewCell, height: CGFloat) {
    field.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
      field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
      field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: height > 44 ? Spacing.md : 0),
      field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: height > 44 ? -Spacing.md : 0),
      field.heightAnchor.constraint(equalToConstant: height > 44 ? height - 2 * Spacing.md : height),
    ])
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
