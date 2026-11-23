import OrcaCore
import UIKit

/// Tasks (tasks/MobileTasksScreen.tsx) for one desktop: the bar (Tasks over the host, Refresh), the source switch
/// (GitHub, GitLab, Linear, Jira, as the desktop shows them), one row of scope chips with Filter, the list, and
/// search with New issue at the bottom. It opens on the view the desktop last kept for it.
final class TasksViewController: UIViewController {
  /// Called after "Create Workspace" made one, with its host and id, so the caller can open it.
  var onOpenWorkspace: ((HostSession, String) -> Void)?

  enum Sort: String { case updated, repository }

  private enum GitHubMode { case items, project }

  private enum Row {
    case item(GitHubWorkItem)
    case tracker(TrackerIssue)
    case todo(GitLabTodo)
    case project(GitHubProjectRow)
  }

  private struct ListSection {
    var key: String
    var title: String?
    var color: UIColor?
    var count: Int?
    var collapsible = false
    var rows: [Row]
  }

  /// What this phone keeps per desktop that the desktop doesn't: sort, layouts, GitLab's view and Jira's site.
  private struct ViewPrefs: Codable {
    var sort = "updated"
    var gitlabView = "project"
    var gitlabFilter = "opened"
    var linearLayout = "list"
    var linearGroup = "none"
    var linearOrder = "priority"
    var linearDisplay = ["state", "priority", "assignee", "team", "labels", "updated"]
    var linearTeamTouched = false
    var jiraSite: String?
    var projectSortField: String?
    var projectSortDescending = false
  }

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

  /// GITLAB_FILTER_OPTIONS.
  private static let gitlabFilters: [(value: String, title: String, subtitle: String)] = [
    (
      "opened", String(localized: "tasks.options.openState", defaultValue: "Open"),
      String(localized: "tasks.options.gitlabOpenDescription", defaultValue: "Open issues and merge requests")
    ),
    (
      "merged", String(localized: "tasks.options.mergedState", defaultValue: "Merged"),
      String(localized: "tasks.options.gitlabMergedDescription", defaultValue: "Merged merge requests")
    ),
    (
      "closed", String(localized: "tasks.options.closedState", defaultValue: "Closed"),
      String(localized: "tasks.options.gitlabClosedDescription", defaultValue: "Closed issues and merge requests")
    ),
    (
      "all", String(localized: "tasks.options.all", defaultValue: "All"),
      String(localized: "tasks.options.gitlabAllDescription", defaultValue: "Any GitLab state")
    ),
  ]

  /// GITLAB_VIEW_OPTIONS.
  private static let gitlabViews: [(value: String, title: String, subtitle: String)] = [
    (
      "project", String(localized: "tasks.options.projectMergeRequests", defaultValue: "Project MRs"),
      String(
        localized: "tasks.options.projectMergeRequestsDescription", defaultValue: "Merge requests and issues by repository")
    ),
    (
      "todos", String(localized: "tasks.options.myTodos", defaultValue: "My Todos"),
      String(localized: "tasks.options.myTodosDescription", defaultValue: "Pending GitLab todos")
    ),
  ]

  private static let sortOptions: [(Sort, String, String)] = [
    (
      .updated, String(localized: "tasks.options.updated", defaultValue: "Updated"),
      String(localized: "tasks.options.updatedSortDescription", defaultValue: "Newest activity first")
    ),
    (
      .repository, String(localized: "tasks.options.repository", defaultValue: "Repository"),
      String(localized: "tasks.options.repositorySortDescription", defaultValue: "Group by repository, then newest activity")
    ),
  ]

  /// LINEAR_DISPLAY_OPTIONS, in their order.
  private static let linearProperties: [(String, String)] = [
    ("state", String(localized: "tasks.options.status", defaultValue: "Status")),
    ("priority", String(localized: "tasks.options.priority", defaultValue: "Priority")),
    ("assignee", String(localized: "tasks.options.assignee", defaultValue: "Assignee")),
    ("team", String(localized: "tasks.options.team", defaultValue: "Team")),
    ("labels", String(localized: "tasks.options.labels", defaultValue: "Labels")),
    ("updated", String(localized: "tasks.options.updated", defaultValue: "Updated")),
  ]

  private let session: HostSession
  private let providerControl = UISegmentedControl()
  private let chipRow = UIStackView()
  private let chipScroll = UIScrollView()
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let board = TaskBoardView()
  private let search = UISearchController(searchResultsController: nil)
  private var refreshItem: UIBarButtonItem!
  private var createItem: UIBarButtonItem!

  // The desktop's settings and resume state; nil until read (or on a desktop without them).
  private var hydration: TaskHydration?
  private var hydrating = false
  /// Set once the read was tried: a desktop without these settings keeps the screen's defaults.
  private var hydrationTried = false
  private var resume: [String: JSONValue] = [:]
  private var providers: [TaskProvider] = [.github, .linear, .jira]
  private var provider: TaskProvider = .github
  private var prefs = ViewPrefs()

  // GitHub
  private var githubMode: GitHubMode = .items
  private var preset: GitHubTaskPreset = .issues
  private var defaultPreset: GitHubTaskPreset?
  /// The search sent: GitHub's starts as the preset's own query and shows in the field.
  private var appliedQuery = GitHubTaskPreset.issues.query
  private var repos: [TaskRepo] = []
  /// Empty: every repository.
  private var selectedRepoIds: Set<String> = []
  private var pages: [[GitHubWorkItem]] = []
  private var currentPage = 0
  private var countedTotalPages: Int?
  private var pageLoading = false
  private var issueSources: [String: GitHubIssueSources] = [:]

  // GitHub Projects
  private var projectSettings = GitHubProjectSettings()
  private var projects: [GitHubProjectSummary] = []
  private var projectFailures: [(owner: String, message: String)] = []
  private var projectsLoading = false
  private var projectError: String?
  private var projectViews: [GitHubProjectView] = []
  private var projectTable: GitHubProjectTable?
  /// A search in place of the view's own filter.
  private var projectQuery: String?
  private var hiddenProjectFields: [String: [String]] = [:]
  private var collapsedGroups: Set<String> = []
  /// `owner/repo` (lowercased) to the project here that points at it, for opening a project row's issue.
  private var repoSlugs: [String: TaskRepo]?
  private weak var projectSheet: TaskSheetViewController?

  // GitLab
  private var gitlabItems: [GitHubWorkItem] = []
  private var todos: [GitLabTodo] = []

  // Linear
  private var linearAccount: LinearAccount?
  private var linearTeams: [LinearTeam] = []
  private var teamsWorkspace: String??
  /// Empty or every team: no filter.
  private var selectedTeamIds: Set<String> = []
  private var linearFilter = "all"

  // Jira
  private var jiraAccount: JiraAccount?
  private var jiraFilter = "assigned"

  private var issues: [TrackerIssue] = []
  private var sections: [ListSection] = []
  /// Some repositories failed, or Jira fell back to a text search: shown above the rows.
  private var notice: String?
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
    if let data = UserDefaults.standard.data(forKey: prefsKey),
      let saved = try? JSONDecoder().decode(ViewPrefs.self, from: data)
    {
      prefs = saved
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var prefsKey: String { "orca.tasks.view.\(session.host.id.uuidString)" }

  private func savePrefs() {
    if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: prefsKey) }
  }

  private var sort: Sort { Sort(rawValue: prefs.sort) ?? .updated }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "tasks.screenChrome.title", defaultValue: "Tasks")
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .never

    // These pages have no pull-to-refresh, so Refresh stays in the bar.
    refreshItem = UIBarButtonItem(
      image: Lucide.refreshCw.image(size: 20), primaryAction: UIAction { [weak self] _ in self?.refresh() })
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

    rebuildProviderControl()
    providerControl.addAction(
      UIAction { [weak self] _ in
        guard let self, self.providers.indices.contains(self.providerControl.selectedSegmentIndex) else { return }
        self.select(self.providers[self.providerControl.selectedSegmentIndex])
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
    table.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "group")
    table.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(table, belowSubview: chrome)

    board.isHidden = true
    board.translatesAutoresizingMaskIntoConstraints = false
    board.onSelect = { [weak self] issue in self?.open(issue) }
    board.subtitle = { [weak self] issue in self?.linearSubtitle(issue) ?? issue.identifier }
    view.insertSubview(board, belowSubview: chrome)

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
      board.topAnchor.constraint(equalTo: table.topAnchor),
      board.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      board.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      board.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
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
    navigationController?.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: animated)
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
      if !hydrationTried {
        hydrate()
      } else if loadedKey == nil, !hydrating {
        reload()
      }
    } else {
      showState()
    }
  }

  // MARK: Hydration

  /// Reads the desktop's task settings and the view it last kept, then opens on it
  /// (screen-state/use-mobile-tasks-runtime-hydration.tsx).
  private func hydrate() {
    hydrationTried = true
    hydrating = true
    loading = true
    showState()
    let api = session.api
    Task {
      let hydration = try? await api.taskHydration()
      hydrating = false
      if let hydration { apply(hydration) }
      reload()
    }
  }

  private func apply(_ hydration: TaskHydration) {
    self.hydration = hydration
    resume = hydration.resume
    providers = hydration.availableProviders
    provider = hydration.initialProvider
    linearConnected = hydration.linearConnected
    defaultPreset = hydration.defaultTaskViewPreset.flatMap(GitHubTaskPreset.init)
    preset = hydration.githubPreset
    githubMode = hydration.githubProjectMode ? .project : .items
    selectedRepoIds = Set(hydration.defaultRepoSelection ?? [])
    selectedTeamIds = Set(hydration.defaultLinearTeamSelection ?? [])
    projectSettings = hydration.githubProjects
    for (key, value) in resume["githubProjectHiddenFieldIdsByView"]?.objectValue ?? [:] {
      hiddenProjectFields[key] = value.arrayValue?.compactMap(\.stringValue)
    }
    if let saved = resume["linearPreset"]?.stringValue, Self.linearFilters.contains(where: { $0.value == saved }) {
      linearFilter = saved
    }
    if let saved = resume["jiraPreset"]?.stringValue, Self.jiraFilters.contains(where: { $0.value == saved }) {
      jiraFilter = saved
    }
    appliedQuery = query(resumedFor: provider)
    search.searchBar.text = appliedQuery
    rebuildProviderControl()
    updateChrome()
  }

  /// A source's last search, as switching back to it restores (provider-pickers selectMobileTasksProvider).
  private func query(resumedFor provider: TaskProvider) -> String {
    switch provider {
    case .github:
      guard githubMode == .items else { return projectQuery ?? "" }
      if resume["githubItemsPreset"]?.isNull == true {
        return preset.scoped(resume["githubItemsQuery"]?.stringValue ?? "")
      }
      return preset.query
    case .linear: return resume["linearQuery"]?.stringValue ?? ""
    case .jira: return resume["jiraQuery"]?.stringValue ?? ""
    case .gitlab: return ""
    }
  }

  /// Keeps the view the desktop reopens on (`ui.taskResumeState`), only when it changed.
  private func persistResume() {
    guard hydration != nil else { return }
    var next = resume
    switch provider {
    case .github where githubMode == .project:
      next["githubMode"] = "project"
    case .github:
      next["githubMode"] = "items"
      next["githubItemsPreset"] = appliedQuery == preset.query ? .string(preset.rawValue) : .null
      next["githubItemsQuery"] = .string(appliedQuery)
    case .linear:
      next["linearPreset"] = .string(linearFilter)
      next["linearQuery"] = .string(appliedQuery)
    case .jira:
      next["jiraPreset"] = .string(jiraFilter)
      next["jiraQuery"] = .string(appliedQuery)
    case .gitlab:
      return
    }
    if !hiddenProjectFields.isEmpty {
      next["githubProjectHiddenFieldIdsByView"] = .object(hiddenProjectFields.mapValues { .array($0.map(JSONValue.string)) })
    }
    guard next != resume else { return }
    resume = next
    let api = session.api
    Task { try? await api.setTaskResumeState(next) }
  }

  /// Saves a task preference on the desktop (`settings.update`); the local view has already changed.
  private func persistSetting(_ key: String, _ value: JSONValue) {
    guard hydration != nil else { return }
    let api = session.api
    Task { try? await api.updateTaskSettings([key: value]) }
  }

  // MARK: Chrome

  private func rebuildProviderControl() {
    providerControl.removeAllSegments()
    for (index, provider) in providers.enumerated() {
      providerControl.insertSegment(withTitle: provider.label, at: index, animated: false)
    }
    providerControl.selectedSegmentIndex = providers.firstIndex(of: provider) ?? 0
    providerControl.isHidden = providers.count < 2
  }

  private func select(_ next: TaskProvider) {
    guard next != provider else { return }
    persistResume()
    provider = next
    persistSetting("defaultTaskSource", .string(next.rawValue))
    pages = []
    issues = []
    gitlabItems = []
    todos = []
    sections = []
    loadError = nil
    notice = nil
    appliedQuery = query(resumedFor: next)
    search.searchBar.text = appliedQuery
    updateChrome()
    reload()
  }

  private var isProjectMode: Bool { provider == .github && githubMode == .project }

  /// The placeholder, the bottom bar and the chips for the current source.
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
    case .gitlab:
      refreshItem.accessibilityLabel = String(
        localized: "tasks.screenChrome.refreshGitLab", defaultValue: "Refresh GitLab work items")
    case .linear:
      refreshItem.accessibilityLabel = String(localized: "tasks.screenChrome.refreshLinear", defaultValue: "Refresh Linear")
    case .jira:
      refreshItem.accessibilityLabel = String(localized: "tasks.screenChrome.refreshJira", defaultValue: "Refresh Jira issues")
    }
    createItem.accessibilityLabel =
      provider == .linear
      ? String(localized: "tasks.screenChrome.newLinearIssue", defaultValue: "New Linear issue")
      : String(localized: "tasks.screenChrome.newGitHubIssue", defaultValue: "New GitHub issue")
    // Unconnected sources have nothing to search; New issue files GitHub issues and Linear issues.
    let connected = isConnected
    let canCreate = (provider == .github && githubMode == .items) || provider == .linear
    let searchable = !(provider == .gitlab && prefs.gitlabView == "todos")
    var items: [UIBarButtonItem] = []
    if connected, searchable { items.append(navigationItem.searchBarPlacementBarButtonItem) }
    if connected, canCreate {
      if !searchable { items.append(.flexibleSpace()) }
      items.append(createItem)
    }
    toolbarItems = items
    if isViewLoaded, view.window != nil { navigationController?.setToolbarHidden(items.isEmpty, animated: true) }
    rebuildChips(connected: connected)
  }

  private var isConnected: Bool {
    switch provider {
    case .github, .gitlab: true
    case .linear: linearConnected == true
    case .jira: jiraConnected == true
    }
  }

  private func rebuildChips(connected: Bool) {
    chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
    chipScroll.isHidden = !connected
    guard connected else { return }
    switch provider {
    case .github:
      if githubMode == .items { chipRow.addArrangedSubview(repoChip()) }
      chipRow.addArrangedSubview(githubKindChip())
      chipRow.addArrangedSubview(githubMode == .items ? presetChip() : projectChip())
    case .gitlab:
      chipRow.addArrangedSubview(repoChip())
      chipRow.addArrangedSubview(
        menuChip(
          Self.gitlabViews, selected: prefs.gitlabView,
          title: String(localized: "tasks.filterPickers.gitlabView", defaultValue: "GitLab View")
        ) { [weak self] value in
          self?.prefs.gitlabView = value
          self?.appliedQuery = ""
        })
      if prefs.gitlabView == "project" {
        chipRow.addArrangedSubview(
          menuChip(
            Self.gitlabFilters, selected: prefs.gitlabFilter,
            title: String(localized: "tasks.filterPickers.gitlabFilter", defaultValue: "GitLab Filter")
          ) { [weak self] value in self?.prefs.gitlabFilter = value })
      }
    case .linear:
      chipRow.addArrangedSubview(teamChip())
      chipRow.addArrangedSubview(
        menuChip(
          Self.linearFilters, selected: linearFilter,
          title: String(localized: "tasks.filterPickers.linearFilter", defaultValue: "Linear Filter")
        ) { [weak self] value in
          self?.linearFilter = value
          self?.appliedQuery = ""
        })
    case .jira:
      if let account = jiraAccount, account.sites.count > 1 { chipRow.addArrangedSubview(jiraSiteChip(account)) }
      if appliedQuery.isEmpty {
        chipRow.addArrangedSubview(
          menuChip(
            Self.jiraFilters, selected: jiraFilter,
            title: String(localized: "tasks.filterPickers.jiraFilter", defaultValue: "Jira Filter")
          ) { [weak self] value in self?.jiraFilter = value })
      } else {
        // A JQL search replaces the preset, so its chip stays visible but locked until the search is cleared.
        let locked = Self.chip(
          String(localized: "tasks.jiraViewControls.jqlSearch", defaultValue: "JQL search"), active: true)
        locked.isEnabled = false
        chipRow.addArrangedSubview(locked)
      }
    }
    let count = filterCount
    let filter = Self.chip(
      count > 0
        ? String(format: String(localized: "tasks.providerControls.filterCount", defaultValue: "Filter · %lld"), count)
        : String(localized: "tasks.providerControls.filter", defaultValue: "Filter"),
      icon: .slidersHorizontal, active: count > 0)
    filter.accessibilityLabel = String(localized: "tasks.providerControls.filterLabel", defaultValue: "Filter and display")
    filter.addAction(UIAction { [weak self] _ in self?.showFilterSheet() }, for: .primaryActionTriggered)
    chipRow.addArrangedSubview(filter)
  }

  /// How many Filter & display settings differ from their defaults (screen/mobile-tasks-filter-sheet.tsx).
  private var filterCount: Int {
    if isProjectMode {
      let hidden = projectTable.map { !(hiddenProjectFields[$0.visibilityKey] ?? []).isEmpty } ?? false
      return (prefs.projectSortField != nil ? 1 : 0) + (hidden ? 1 : 0)
    }
    if provider == .linear {
      return (prefs.linearLayout != "list" ? 1 : 0) + (prefs.linearGroup != "none" ? 1 : 0)
        + (prefs.linearOrder != "priority" ? 1 : 0)
    }
    return sort != .updated ? 1 : 0
  }

  private func githubKindChip() -> UIButton {
    let label =
      githubMode == .project
      ? String(localized: "tasks.providerViewProjection.projects", defaultValue: "Projects")
      : preset.isPullRequests
        ? String(localized: "tasks.providerViewProjection.pullRequests", defaultValue: "PRs")
        : String(localized: "tasks.providerViewProjection.issues", defaultValue: "Issues")
    let kinds: [(String, String, String)] = [
      (
        "issues", String(localized: "tasks.options.issues", defaultValue: "Issues"),
        String(localized: "tasks.options.githubIssuesDescription", defaultValue: "GitHub issues")
      ),
      (
        "prs", String(localized: "tasks.options.pullRequests", defaultValue: "PRs"),
        String(localized: "tasks.options.githubPullRequestsDescription", defaultValue: "GitHub pull requests")
      ),
      (
        "project", String(localized: "tasks.options.projects", defaultValue: "Projects"),
        String(localized: "tasks.options.githubProjectsDescription", defaultValue: "GitHub Projects views")
      ),
    ]
    let current = githubMode == .project ? "project" : (preset.isPullRequests ? "prs" : "issues")
    return Self.chip(
      label,
      menu: UIMenu(
        title: String(localized: "tasks.providerPickers.githubView", defaultValue: "GitHub View"),
        children: kinds.map { value, title, subtitle in
          UIAction(title: title, subtitle: subtitle, state: value == current ? .on : .off) { [weak self] _ in
            self?.pickGitHubKind(value)
          }
        }))
  }

  private func pickGitHubKind(_ kind: String) {
    persistResume()
    if kind == "project" {
      githubMode = .project
      pages = []
      appliedQuery = projectQuery ?? ""
    } else {
      githubMode = .items
      apply(kind == "prs" ? .prs : .issues)
      return
    }
    search.searchBar.text = appliedQuery
    updateChrome()
    reload()
  }

  private func presetChip() -> UIButton {
    let presets = Self.presets(pullRequests: preset.isPullRequests)
    let label =
      presets.first { $0.0 == preset }?.1 ?? String(localized: "tasks.options.openState", defaultValue: "Open")
    let picks = presets.map { value, title, subtitle in
      UIAction(
        title: title,
        subtitle: value == defaultPreset
          ? String(
            format: String(localized: "tasks.providerViewProjection.defaultSubtitle", defaultValue: "%@ · Default"),
            subtitle)
          : subtitle,
        state: preset == value ? .on : .off
      ) { [weak self] _ in self?.apply(value) }
    }
    // The official picker sets the default on a long press; a menu gives it its own row.
    let makeDefault = UIAction(
      title: String(localized: "orcaios.tasks.makeDefault", defaultValue: "Make Default"),
      subtitle: label, image: UIImage(systemName: "pin"),
      attributes: preset == defaultPreset ? .disabled : []
    ) { [weak self] _ in
      guard let self else { return }
      self.defaultPreset = self.preset
      self.persistSetting("defaultTaskViewPreset", .string(self.preset.rawValue))
      self.updateChrome()
    }
    return Self.chip(
      label,
      menu: UIMenu(
        title: preset.isPullRequests
          ? String(localized: "tasks.providerPickers.pullRequests", defaultValue: "Pull Requests")
          : String(localized: "tasks.providerPickers.issues", defaultValue: "Issues"),
        children: [UIMenu(options: .displayInline, children: picks), UIMenu(options: .displayInline, children: [makeDefault])]))
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
    githubMode = .items
    appliedQuery = next.query
    search.searchBar.text = appliedQuery
    updateChrome()
    reload()
  }

  private func projectChip() -> UIButton {
    let label =
      projectTable?.projectTitle
      ?? projectSettings.activeProject.map { project in
        projects.first { $0.ref.key == project.key }?.title ?? "#\(project.number)"
      } ?? String(localized: "tasks.providerViewProjection.chooseProject", defaultValue: "Choose project")
    let chip = Self.chip(label, active: false, opensSheet: true)
    chip.addAction(UIAction { [weak self] _ in self?.showProjectPicker() }, for: .primaryActionTriggered)
    return chip
  }

  private var repoLabel: String {
    let picked = repos.filter { selectedRepoIds.contains($0.id) }
    if selectedRepoIds.isEmpty || selectedRepoIds.count == repos.count {
      return String(localized: "tasks.pickerProjection.allRepos", defaultValue: "All repos")
    }
    if picked.count == 1 { return picked[0].displayName }
    return String.localizedStringWithFormat(
      String(localized: "tasks.pickerProjection.repos", defaultValue: "%lld repos"), selectedRepoIds.count)
  }

  private func repoChip() -> UIButton {
    let label = repoLabel
    let chip = Self.chip(
      label, active: !selectedRepoIds.isEmpty && selectedRepoIds.count < repos.count, opensSheet: true)
    chip.accessibilityLabel = String(
      format: String(localized: "tasks.providerControls.reposLabel", defaultValue: "Repositories: %@"), label)
    chip.addAction(UIAction { [weak self] _ in self?.showRepoPicker() }, for: .primaryActionTriggered)
    return chip
  }

  private func teamChip() -> UIButton {
    let count = selectedTeamIds.count
    let label: String
    if count == 0 || count == linearTeams.count {
      label = String(localized: "tasks.providerViewProjection.allTeams", defaultValue: "All teams")
    } else if count == 1, let team = linearTeams.first(where: { selectedTeamIds.contains($0.id) }) {
      label = team.name
    } else {
      label = String.localizedStringWithFormat(
        String(localized: "tasks.providerViewProjection.teams", defaultValue: "%lld teams"), count)
    }
    let chip = Self.chip(label, active: count > 0 && count < linearTeams.count, opensSheet: true)
    chip.addAction(UIAction { [weak self] _ in self?.showTeamPicker() }, for: .primaryActionTriggered)
    return chip
  }

  private func jiraSiteChip(_ account: JiraAccount) -> UIButton {
    let selected = account.selection.flatMap { id in account.sites.first { $0.id == id } }
    let all = UIAction(
      title: String(localized: "tasks.pickerProjection.allSites", defaultValue: "All sites"),
      state: account.selection == "all" ? .on : .off
    ) { [weak self] _ in self?.pickJiraSite("all") }
    let sites = account.sites.map { site in
      UIAction(title: site.label, subtitle: site.siteUrl, state: account.selection == site.id ? .on : .off) {
        [weak self] _ in self?.pickJiraSite(site.id)
      }
    }
    return Self.chip(
      selected?.label ?? String(localized: "tasks.providerViewProjection.allSites", defaultValue: "All sites"),
      active: selected != nil,
      menu: UIMenu(
        title: String(localized: "tasks.filterPickers.jiraSite", defaultValue: "Jira Site"),
        children: [UIMenu(options: .displayInline, children: [all]), UIMenu(options: .displayInline, children: sites)]))
  }

  private func pickJiraSite(_ id: String) {
    jiraAccount?.selection = id
    prefs.jiraSite = id
    savePrefs()
    issues = []
    updateChrome()
    reload()
  }

  /// A scope picked from a chip's menu: the list restarts unfiltered by search.
  private func menuChip(
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
            guard let self else { return }
            onPick(option.value)
            self.savePrefs()
            self.search.searchBar.text = self.appliedQuery
            self.updateChrome()
            self.reload()
          }
        }))
  }

  /// components/nav-bar/FilterChip.tsx: a 32 pt capsule on the raised fill, a ring when it narrows the list, a
  /// chevron when it opens a menu or sheet.
  private static func chip(
    _ title: String, icon: Lucide? = nil, active: Bool = false, menu: UIMenu? = nil, opensSheet: Bool = false
  ) -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.baseBackgroundColor = Palette.bgRaised
    configuration.baseForegroundColor = active ? Palette.textPrimary : Palette.textSecondary
    configuration.background.strokeColor = active ? Palette.textSecondary : .clear
    configuration.background.strokeWidth = 1
    let chevron = menu != nil || opensSheet
    configuration.contentInsets = .init(
      top: 0, leading: icon == nil ? Spacing.md : Spacing.sm, bottom: 0, trailing: chevron ? Spacing.sm : Spacing.md)
    var attributes = AttributeContainer()
    attributes.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    configuration.attributedTitle = AttributedString(title, attributes: attributes)
    configuration.titleLineBreakMode = .byTruncatingTail
    if let icon {
      configuration.image = icon.image(size: 15, strokeWidth: 2.2)
      configuration.imagePlacement = .leading
    } else if chevron {
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

  // MARK: Sheets

  /// Rows with their own sheet open it in place of Filter & display rather than stacking over it.
  private func replaceSheet(with open: @escaping () -> Void) {
    // An active search is presented too, but it stays; only a sheet makes way.
    if let presented = presentedViewController, !(presented is UISearchController) {
      dismiss(animated: true, completion: open)
    } else {
      open()
    }
  }

  private func choiceRows<T: Equatable>(_ options: [(T, String, String?)], selected: T, pick: @escaping (T) -> Void)
    -> [TaskSheetRow]
  {
    options.map { value, title, subtitle in
      TaskSheetRow(title: title, subtitle: subtitle, selected: value == selected) { pick(value) }
    }
  }

  /// Sort, layout, grouping, fields and source in one sheet, so the chip row keeps only scopes.
  private func showFilterSheet() {
    let sheet = TaskSheetViewController(title: String(localized: "tasks.filterSheet.title", defaultValue: "Filter & display")) {
      [weak self] _ in self?.filterSections() ?? []
    }
    presentTaskSheet(sheet)
  }

  private func filterSections() -> [TaskSheetSection] {
    let sortBy = String(localized: "tasks.filterSheet.sortBy", defaultValue: "Sort by")
    let showOnRows = String(localized: "tasks.filterSheet.showOnRows", defaultValue: "Show on rows")
    let sortRows = choiceRows(Self.sortOptions.map { ($0.0, $0.1, Optional($0.2)) }, selected: sort) { [weak self] value in
      self?.prefs.sort = value.rawValue
      self?.savePrefs()
      self?.updateChrome()
      self?.rebuildSections()
    }
    switch provider {
    case .github where githubMode == .project:
      var sections: [TaskSheetSection] = []
      let count = projectTable.map { visibleProjectRows($0).count }
      var view = TaskSheetRow(
        title: String(localized: "tasks.filterSheet.projectView", defaultValue: "Project view"),
        subtitle: count.map {
          String.localizedStringWithFormat(
            String(localized: "tasks.filterSheet.projectItems", defaultValue: "%lld items"), $0)
        },
        value: projectTable?.view.name ?? String(localized: "tasks.filterSheet.chooseView", defaultValue: "Choose"),
        navigates: true
      ) { [weak self] in self?.replaceSheet { self?.showProjectViewPicker(pending: nil) } }
      view.disabled = projectTable == nil
      var viewRows = [view]
      if let url = projectViewURL {
        viewRows.append(
          TaskSheetRow(title: String(localized: "tasks.githubViewControls.openView", defaultValue: "Open view in GitHub")) {
            UIApplication.shared.open(url)
          })
      }
      sections.append(TaskSheetSection(header: String(localized: "tasks.filterSheet.view", defaultValue: "View"), rows: viewRows))
      if let table = projectTable {
        var rows = [
          TaskSheetRow(
            title: String(localized: "tasks.pickerProjection.viewOrder", defaultValue: "View order"),
            subtitle: table.sortBy.map { sort in
              sort.descending
                ? String(
                  format: String(localized: "tasks.pickerProjection.usesFieldDescending", defaultValue: "Uses %@ desc"),
                  sort.field.name)
                : String(
                  format: String(localized: "tasks.pickerProjection.usesFieldAscending", defaultValue: "Uses %@ asc"),
                  sort.field.name)
            } ?? String(localized: "tasks.pickerProjection.usesGitHubRankOrder", defaultValue: "Uses GitHub rank order"),
            selected: prefs.projectSortField == nil
          ) { [weak self] in self?.cycleProjectSort(nil) }
        ]
        for field in table.fields {
          let active = prefs.projectSortField == field.id
          rows.append(
            TaskSheetRow(
              title: field.name,
              subtitle: active
                ? (prefs.projectSortDescending
                  ? String(
                    localized: "tasks.pickerProjection.currentlyDescending", defaultValue: "Currently desc · tap for ascending")
                  : String(
                    localized: "tasks.pickerProjection.currentlyAscending", defaultValue: "Currently asc · tap for descending"))
                : String(localized: "tasks.pickerProjection.sortAscending", defaultValue: "Sort ascending"),
              selected: active
            ) { [weak self] in self?.cycleProjectSort(field.id) })
        }
        sections.append(TaskSheetSection(header: sortBy, rows: rows))
        if !table.summaryFields.isEmpty {
          let hidden = Set(hiddenProjectFields[table.visibilityKey] ?? [])
          let shown = table.summaryFields.filter { !hidden.contains($0.id) }.count
          sections.append(
            TaskSheetSection(
              header: showOnRows,
              rows: [
                TaskSheetRow(
                  title: String(localized: "tasks.filterSheet.projectFields", defaultValue: "Project fields"),
                  value: String(
                    format: String(localized: "tasks.pickerProjection.selectedFields", defaultValue: "%1$@/%2$@ fields"),
                    String(shown), String(table.summaryFields.count)),
                  navigates: true
                ) { [weak self] in self?.replaceSheet { self?.showProjectFieldsPicker() } }
              ]))
        }
      }
      return sections
    case .github:
      var sections = [TaskSheetSection(header: sortBy, rows: sortRows)]
      let sourceRows = issueSourceRows
      if !sourceRows.isEmpty {
        let label =
          sourceRows.count == 1
          ? (sourceRows[0].repo.issueSourcePreference == "origin"
            ? sourceRows[0].sources.prs?.slug : sourceRows[0].sources.upstreamCandidate?.slug) ?? ""
          : String.localizedStringWithFormat(
            String(localized: "tasks.pickerProjection.sources", defaultValue: "%lld sources"), sourceRows.count)
        sections.append(
          TaskSheetSection(
            header: String(localized: "tasks.filterSheet.issueSource", defaultValue: "Issue source"),
            rows: [
              TaskSheetRow(
                title: String(localized: "tasks.filterSheet.issueSourceRow", defaultValue: "Upstream or origin"),
                value: label, navigates: true
              ) { [weak self] in self?.replaceSheet { self?.showIssueSourcePicker() } }
            ]))
      }
      return sections
    case .linear:
      var sections: [TaskSheetSection] = []
      if let account = linearAccount, account.workspaces.count > 1 {
        let name =
          account.selectedWorkspaceId == "all"
          ? String(localized: "tasks.providerViewProjection.allWorkspaces", defaultValue: "All workspaces")
          : account.workspaces.first { $0.id == account.selectedWorkspaceId }?.name
            ?? String(localized: "tasks.providerViewProjection.workspace", defaultValue: "Workspace")
        sections.append(
          TaskSheetSection(
            header: String(localized: "tasks.filterSheet.workspace", defaultValue: "Workspace"),
            rows: [
              TaskSheetRow(
                title: String(localized: "tasks.filterSheet.linearWorkspace", defaultValue: "Linear workspace"),
                value: name, navigates: true
              ) { [weak self] in self?.replaceSheet { self?.showLinearWorkspacePicker() } }
            ]))
      }
      sections.append(
        TaskSheetSection(
          header: String(localized: "tasks.filterSheet.layout", defaultValue: "Layout"),
          rows: choiceRows(
            [
              (
                "list", String(localized: "tasks.options.list", defaultValue: "List"),
                String(localized: "tasks.options.listDescription", defaultValue: "Compact issue rows")
              ),
              (
                "board", String(localized: "tasks.options.board", defaultValue: "Board"),
                String(localized: "tasks.options.boardDescription", defaultValue: "Grouped columns")
              ),
            ], selected: prefs.linearLayout
          ) { [weak self] value in self?.setLinear(\.linearLayout, value) }))
      sections.append(
        TaskSheetSection(
          header: String(localized: "tasks.filterSheet.groupBy", defaultValue: "Group by"),
          rows: choiceRows(
            [
              ("none", String(localized: "tasks.options.noGrouping", defaultValue: "No grouping"), nil),
              ("status", String(localized: "tasks.options.status", defaultValue: "Status"), nil),
              ("assignee", String(localized: "tasks.options.assignee", defaultValue: "Assignee"), nil),
              ("priority", String(localized: "tasks.options.priority", defaultValue: "Priority"), nil),
              ("team", String(localized: "tasks.options.team", defaultValue: "Team"), nil),
            ], selected: prefs.linearGroup
          ) { [weak self] value in self?.setLinear(\.linearGroup, value) }))
      sections.append(
        TaskSheetSection(
          header: String(localized: "tasks.filterSheet.orderBy", defaultValue: "Order by"),
          rows: choiceRows(
            [
              ("priority", String(localized: "tasks.options.priority", defaultValue: "Priority"), nil),
              ("updated", String(localized: "tasks.options.updated", defaultValue: "Updated"), nil),
              ("identifier", String(localized: "tasks.options.identifier", defaultValue: "Identifier"), nil),
            ], selected: prefs.linearOrder
          ) { [weak self] value in self?.setLinear(\.linearOrder, value) }))
      sections.append(
        TaskSheetSection(
          header: showOnRows,
          rows: [
            TaskSheetRow(
              title: String(localized: "tasks.filterSheet.displayProperties", defaultValue: "Display properties"),
              navigates: true
            ) { [weak self] in self?.replaceSheet { self?.showLinearDisplayPicker() } }
          ]))
      return sections
    case .gitlab, .jira:
      return [
        TaskSheetSection(
          header: sortBy,
          footer: provider == .jira && !appliedQuery.isEmpty
            ? String(
              localized: "tasks.filterSheet.jqlReplacesPreset",
              defaultValue: "Your JQL search replaces the Show preset. Clear the search to pick one again.")
            : nil,
          rows: sortRows)
      ]
    }
  }

  private func setLinear(_ key: WritableKeyPath<ViewPrefs, String>, _ value: String) {
    prefs[keyPath: key] = value
    savePrefs()
    updateChrome()
    rebuildSections()
  }

  private func showRepoPicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.providerPickers.repos", defaultValue: "Repositories"),
      subtitle: String(localized: "tasks.providerPickers.repoDescription", defaultValue: "Choose which repositories to query.")
    ) { [weak self] _ in
      guard let self else { return [] }
      let all = TaskSheetRow(
        title: String(localized: "tasks.providerPickers.allRepositories", defaultValue: "All repositories"),
        subtitle: String.localizedStringWithFormat(
          String(localized: "orcaios.tasks.repositoryCount", defaultValue: "%lld repositories"), self.repos.count),
        selected: self.selectedRepoIds.isEmpty
      ) { [weak self] in self?.setRepoSelection([]) }
      let each = self.repos.map { repo in
        TaskSheetRow(
          title: repo.displayName, subtitle: repo.connectionId == nil ? nil : "SSH",
          selected: self.selectedRepoIds.contains(repo.id), dot: Self.repoColor(repo)
        ) { [weak self] in
          guard let self else { return }
          var next = self.selectedRepoIds
          if next.contains(repo.id) { next.remove(repo.id) } else { next.insert(repo.id) }
          // Every repository picked is the same as none: the filter widens back to all.
          if next.count == self.repos.count { next = [] }
          self.setRepoSelection(next)
        }
      }
      return [TaskSheetSection(rows: [all]), TaskSheetSection(rows: each)]
    }
    presentTaskSheet(sheet)
  }

  private func setRepoSelection(_ next: Set<String>) {
    selectedRepoIds = next
    persistSetting("defaultRepoSelection", next.isEmpty ? .null : .array(next.sorted().map(JSONValue.string)))
    updateChrome()
    reload()
  }

  /// A repository's badge colour, stable per name.
  static func repoColor(_ repo: TaskRepo) -> UIColor {
    let colors: [UIColor] = [
      Palette.accentBlue, Palette.statusGreen, Palette.statusPurple, Palette.statusAmber, Palette.agentQuestion,
      Palette.statusRed,
    ]
    let hash = repo.displayName.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return colors[hash % colors.count]
  }

  private func showTeamPicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.filterPickers.teamsTitle", defaultValue: "Linear Teams"),
      subtitle: String(localized: "tasks.filterPickers.teamsSubtitle", defaultValue: "Choose which teams appear in Tasks.")
    ) { [weak self] _ in
      guard let self else { return [] }
      let teams = self.linearTeams
      let allSelected = self.selectedTeamIds.isEmpty || self.selectedTeamIds.count == teams.count
      let all = TaskSheetRow(
        title: String(localized: "tasks.filterPickers.allTeams", defaultValue: "All teams"),
        subtitle: String.localizedStringWithFormat(
          String(localized: "tasks.filterPickers.teams", defaultValue: "%lld teams"), teams.count),
        selected: allSelected
      ) { [weak self] in self?.setTeamSelection([]) }
      let each = teams.map { team in
        TaskSheetRow(
          title: team.name, subtitle: team.workspaceName ?? team.key,
          selected: !allSelected && self.selectedTeamIds.contains(team.id)
        ) { [weak self] in
          guard let self else { return }
          var next = allSelected ? [] : self.selectedTeamIds
          if next.contains(team.id) { next.remove(team.id) } else { next.insert(team.id) }
          self.setTeamSelection(next.count == teams.count ? [] : next)
        }
      }
      return [TaskSheetSection(rows: [all]), TaskSheetSection(rows: each)]
    }
    presentTaskSheet(sheet)
  }

  private func setTeamSelection(_ next: Set<String>) {
    selectedTeamIds = next
    persistSetting("defaultLinearTeamSelection", next.isEmpty ? .null : .array(next.sorted().map(JSONValue.string)))
    updateChrome()
    rebuildSections()
  }

  private func showLinearWorkspacePicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.filterPickers.linearWorkspace", defaultValue: "Linear Workspace")
    ) { [weak self] _ in
      guard let self, let account = self.linearAccount else { return [] }
      let options =
        [("all", String(localized: "tasks.providerViewProjection.allWorkspaces", defaultValue: "All workspaces"))]
        + account.workspaces.map { ($0.id, $0.name) }
      return [
        TaskSheetSection(
          rows: options.map { id, name in
            TaskSheetRow(title: name, selected: account.selectedWorkspaceId == id) { [weak self] in
              self?.selectLinearWorkspace(id)
            }
          })
      ]
    }
    presentTaskSheet(sheet)
  }

  private func selectLinearWorkspace(_ id: String) {
    linearAccount?.selectedWorkspaceId = id
    selectedTeamIds = []
    linearTeams = []
    teamsWorkspace = nil
    let api = session.api
    Task {
      do {
        try await api.selectLinearWorkspace(id)
      } catch {
        loadError = String(localized: "tasks.filterPickers.switchWorkspaceFailed", defaultValue: "Failed to switch workspace")
      }
      reload(force: true)
    }
  }

  private func showLinearDisplayPicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.filterSheet.displayProperties", defaultValue: "Display properties")
    ) { [weak self] _ in
      guard let self else { return [] }
      let shown = self.linearDisplay
      return [
        TaskSheetSection(
          rows: Self.linearProperties.map { value, title in
            TaskSheetRow(title: title, selected: shown.contains(value)) { [weak self] in
              guard let self else { return }
              var next = Set(self.linearDisplay)
              if next.contains(value) { next.remove(value) } else { next.insert(value) }
              self.prefs.linearDisplay = Self.linearProperties.map(\.0).filter(next.contains)
              if value == "team" { self.prefs.linearTeamTouched = true }
              self.savePrefs()
              self.rebuildSections()
            }
          })
      ]
    }
    presentTaskSheet(sheet)
  }

  /// The properties shown on Linear rows: the grouped one drops out, and Team shows only across several teams until
  /// it is set by hand (use-mobile-tasks-provider-view-projection.tsx).
  private var linearDisplay: [String] {
    var shown = Set(prefs.linearDisplay)
    switch prefs.linearGroup {
    case "status": shown.remove("state")
    case "assignee": shown.remove("assignee")
    case "priority": shown.remove("priority")
    case "team": shown.remove("team")
    default: break
    }
    if !prefs.linearTeamTouched {
      let teams = selectedTeamIds.isEmpty ? linearTeams.count : selectedTeamIds.count
      if teams > 1 { shown.insert("team") } else { shown.remove("team") }
    }
    return Self.linearProperties.map(\.0).filter(shown.contains)
  }

  /// The repositories whose fork reads issues from a different repository than its own, for the issue-source rows.
  private var issueSourceRows: [(repo: TaskRepo, sources: GitHubIssueSources)] {
    queriedRepos.compactMap { repo in
      guard let sources = issueSources[repo.id], sources.hasChoice else { return nil }
      return (repo, sources)
    }
  }

  private func showIssueSourcePicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.providerPickers.issueSources", defaultValue: "GitHub Issue Sources"),
      subtitle: String(
        localized: "tasks.providerPickers.issueSourcesDescription",
        defaultValue: "Choose whether each repository queries and creates work from upstream or origin.")
    ) { [weak self] _ in
      guard let self else { return [] }
      let rows = self.issueSourceRows
      guard !rows.isEmpty else {
        return [
          TaskSheetSection(rows: [
            TaskSheetRow(
              title: String(localized: "tasks.providerPickers.noIssueSources", defaultValue: "No alternate issue sources available."),
              disabled: true)
          ])
        ]
      }
      return [
        TaskSheetSection(
          rows: rows.map { repo, sources in
            let origin = repo.issueSourcePreference == "origin"
            var row = TaskSheetRow(
              title: repo.displayName,
              subtitle: String(
                format: String(localized: "tasks.providerPickers.queryingSource", defaultValue: "Querying %@"),
                (origin ? sources.prs : sources.upstreamCandidate)?.slug
                  ?? String(localized: "common.unknown", defaultValue: "Unknown")))
            row.segments = [
              String(localized: "tasks.providerPickers.upstream", defaultValue: "Upstream"),
              String(localized: "tasks.providerPickers.origin", defaultValue: "Origin"),
            ]
            row.selectedSegment = origin ? 1 : 0
            row.onSegment = { [weak self] index in self?.setIssueSource(repoId: repo.id, origin: index == 1) }
            return row
          })
      ]
    }
    presentTaskSheet(sheet)
  }

  /// The host owns the preference: write it, reread the repositories, then the list.
  private func setIssueSource(repoId: String, origin: Bool) {
    let api = session.api
    Task {
      do {
        try await api.setIssueSourcePreference(repoId: repoId, origin ? "origin" : "upstream")
        repos = (try? await api.taskRepos()) ?? repos
        (presentedViewController as? UINavigationController)?.viewControllers.compactMap { $0 as? TaskSheetViewController }
          .forEach { $0.reload() }
        reload(force: true)
      } catch {
        alert(Self.message(error))
      }
    }
  }

  private func showPagePicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.providerPickers.pages", defaultValue: "GitHub Pages"),
      subtitle: String(localized: "tasks.providerPickers.pageHint", defaultValue: "Jump to a loaded or available result page.")
    ) { [weak self] _ in
      guard let self else { return [] }
      let available = min(self.totalPages + (self.canLoadUncountedNext ? 1 : 0), self.pages.count + 1)
      return [
        TaskSheetSection(
          rows: (0..<max(available, 1)).map { index in
            TaskSheetRow(
              title: String(format: String(localized: "tasks.providerPickers.pageNumber", defaultValue: "Page %@"), String(index + 1)),
              subtitle: index < self.pages.count
                ? String(localized: "tasks.providerPickers.pageLoaded", defaultValue: "Loaded")
                : String(localized: "tasks.providerPickers.pageNotLoaded", defaultValue: "Loads older results"),
              selected: index == self.currentPage, disabled: self.pageLoading
            ) { [weak self] in
              self?.dismiss(animated: true)
              self?.goToPage(index)
            }
          })
      ]
    }
    presentTaskSheet(sheet)
  }

  // MARK: GitHub Projects sheets

  private func showProjectPicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.githubProjectPickers.title", defaultValue: "GitHub Projects"),
      subtitle: String(localized: "tasks.githubProjectPickers.subtitle", defaultValue: "Choose a project view for the Tasks page."),
      searchPlaceholder: String(localized: "tasks.githubProjectPickers.searchProjects", defaultValue: "Search projects")
    ) { [weak self] sheet in self?.projectPickerSections(search: sheet.searchText) ?? [] }
    projectSheet = presentTaskSheet(sheet, large: true)
    if projects.isEmpty { loadProjects() }
  }

  private func loadProjects() {
    guard !projectsLoading else { return }
    projectsLoading = true
    projectSheet?.reload()
    let api = session.api
    Task {
      do {
        let (projects, failures) = try await api.githubProjects()
        self.projects = projects
        projectFailures = failures
        projectError = nil
      } catch {
        projectError = Self.message(error)
      }
      projectsLoading = false
      projectSheet?.reload()
      updateChrome()
    }
  }

  private func projectPickerSections(search: String) -> [TaskSheetSection] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    let titles = Dictionary(projects.map { ($0.ref.key, $0.title) }) { a, _ in a }
    func matches(_ ref: GitHubProjectRef, _ title: String?) -> Bool {
      query.isEmpty || (title ?? "").lowercased().contains(query) || ref.owner.lowercased().contains(query)
    }
    func row(_ ref: GitHubProjectRef, title: String) -> TaskSheetRow {
      TaskSheetRow(
        title: title, subtitle: "\(ref.owner) · #\(ref.number)", selected: projectSettings.activeProject?.key == ref.key
      ) { [weak self] in
        self?.dismiss(animated: true) { self?.selectProject(ref) }
      }
    }
    var sections: [TaskSheetSection] = []
    var add = TaskSheetRow(
      title: String(localized: "tasks.githubProjectPickers.addPlaceholder", defaultValue: "Add by URL or owner/number"),
      dot: nil
    ) { [weak self] in self?.promptAddProject() }
    add.navigates = true
    var failure: String?
    if let projectError {
      failure = projectError
    } else if !projectFailures.isEmpty {
      let head =
        projectFailures.count == 1 && projectFailures[0].owner != "*"
        ? String(
          format: String(localized: "tasks.githubProjectPickers.ownerLoadFailed", defaultValue: "Couldn't load projects from %@."),
          projectFailures[0].owner)
        : String.localizedStringWithFormat(
          String(localized: "tasks.githubProjectPickers.organizationsLoadFailed", defaultValue: "Some organizations didn't load (%lld)."),
          projectFailures.count)
      failure =
        head + " "
        + String(localized: "tasks.githubProjectPickers.addByUrlHint", defaultValue: "Use Add by URL to reach missing projects.")
    }
    sections.append(TaskSheetSection(footer: failure, rows: [add]))
    let pinned = projectSettings.pinned.filter { matches($0, titles[$0.key]) }
    if !pinned.isEmpty {
      sections.append(
        TaskSheetSection(
          header: String(localized: "tasks.githubProjectPickers.pinned", defaultValue: "Pinned"),
          rows: pinned.map { row($0, title: titles[$0.key] ?? "#\($0.number)") }))
    }
    let pinnedKeys = Set(projectSettings.pinned.map(\.key))
    let recent = projectSettings.recent.map(\.ref).filter { !pinnedKeys.contains($0.key) && matches($0, titles[$0.key]) }
    if !recent.isEmpty {
      sections.append(
        TaskSheetSection(
          header: String(localized: "tasks.githubProjectPickers.recent", defaultValue: "Recent"),
          rows: recent.map { row($0, title: titles[$0.key] ?? "#\($0.number)") }))
    }
    let shownKeys = pinnedKeys.union(recent.map(\.key))
    let browse = projects.filter { !shownKeys.contains($0.ref.key) && matches($0.ref, $0.title) }
    if projectsLoading && projects.isEmpty {
      sections.append(
        TaskSheetSection(
          header: String(localized: "tasks.githubProjectPickers.browseLoading", defaultValue: "Browse all (loading...)"),
          rows: []))
    } else if projects.isEmpty && pinned.isEmpty && recent.isEmpty {
      sections.append(
        TaskSheetSection(rows: [
          TaskSheetRow(
            title: String(localized: "tasks.githubProjectPickers.noProjects", defaultValue: "No projects loaded"),
            subtitle: String(localized: "tasks.githubProjectPickers.retryHint", defaultValue: "Tap to retry.")
          ) { [weak self] in self?.loadProjects() }
        ]))
    } else {
      sections.append(
        TaskSheetSection(
          header: projectsLoading
            ? String(localized: "tasks.githubProjectPickers.browseLoading", defaultValue: "Browse all (loading...)")
            : String(localized: "tasks.githubProjectPickers.browseAll", defaultValue: "Browse all"),
          footer: browse.isEmpty
            ? (query.isEmpty
              ? String(localized: "tasks.githubProjectPickers.noMoreProjects", defaultValue: "No more projects.")
              : String(localized: "tasks.githubProjectPickers.noMatches", defaultValue: "No matching projects."))
            : nil,
          rows: browse.map { row($0.ref, title: $0.title) }))
    }
    return sections
  }

  private func promptAddProject() {
    let prompt = UIAlertController(
      title: String(localized: "tasks.githubProjectPickers.addPlaceholder", defaultValue: "Add by URL or owner/number"),
      message: nil, preferredStyle: .alert)
    prompt.addTextField { field in
      field.placeholder = "owner/1"
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.keyboardType = .URL
    }
    prompt.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    prompt.addAction(
      UIAlertAction(title: String(localized: "tasks.githubProjectPickers.add", defaultValue: "Add"), style: .default) {
        [weak self, weak prompt] _ in
        self?.addProject(prompt?.textFields?.first?.text ?? "")
      })
    (projectSheet ?? self as UIViewController).topPresenter.present(prompt, animated: true)
  }

  private func addProject(_ input: String) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = GitHubProjectRef.parseInput(trimmed) else {
      (projectSheet ?? self as UIViewController).alert("Expected a project URL or owner/number.")
      return
    }
    let api = session.api
    Task {
      do {
        let resolved = try await api.resolveGitHubProject(trimmed, host: parsed.host)
        dismiss(animated: true) { self.selectProject(resolved.ref, viewNumber: resolved.viewNumber) }
      } catch {
        (projectSheet ?? self as UIViewController).alert(Self.message(error))
      }
    }
  }

  /// Opens a project on its remembered table view, or the view a URL named; else asks which view, as desktop does.
  private func selectProject(_ ref: GitHubProjectRef, viewNumber: Int? = nil) {
    let api = session.api
    loading = true
    projectError = nil
    showState()
    Task {
      do {
        let views = try await api.githubProjectViews(ref)
        loading = false
        if let viewNumber, let view = views.first(where: { $0.number == viewNumber }) {
          guard view.isTable else {
            throw TaskMessage(
              String(
                localized: "tasks.githubProjectPickers.unsupportedLayout",
                defaultValue: "Orca doesn't support this GitHub Project layout yet."))
          }
          commitProjectView(ref, viewId: view.id, views: views)
          return
        }
        let remembered = projectSettings.lastViewByProject[ref.key]
        if viewNumber == nil, let view = views.first(where: { $0.id == remembered && $0.isTable }) {
          commitProjectView(ref, viewId: view.id, views: views)
          return
        }
        guard views.contains(where: \.isTable) else {
          throw TaskMessage("This project has no supported views.")
        }
        showProjectViewPicker(pending: (ref, views))
        showState()
      } catch {
        loading = false
        projectError = Self.message(error)
        showState()
      }
    }
  }

  private func commitProjectView(_ ref: GitHubProjectRef, viewId: String, views: [GitHubProjectView]) {
    projectViews = views
    projectSettings = projectSettings.opening(ref, viewId: viewId)
    persistSetting("githubProjects", projectSettings.json)
    projectQuery = nil
    projectTable = nil
    appliedQuery = ""
    search.searchBar.text = ""
    updateChrome()
    reload()
  }

  private func showProjectViewPicker(pending: (ref: GitHubProjectRef, views: [GitHubProjectView])?) {
    let sheet = TaskSheetViewController(
      title: pending != nil
        ? String(localized: "tasks.githubProjectPickers.chooseView", defaultValue: "Choose Project View")
        : String(localized: "tasks.githubProjectPickers.view", defaultValue: "Project View")
    ) { [weak self] _ in
      guard let self else { return [] }
      let views = pending?.views ?? self.projectViews
      let current = pending == nil ? self.projectTable?.view.id : nil
      return [
        TaskSheetSection(
          rows: views.map { view in
            TaskSheetRow(
              title: view.name,
              subtitle: view.isTable
                ? String(format: String(localized: "tasks.pickerProjection.viewNumber", defaultValue: "View #%@"), String(view.number))
                : String(localized: "tasks.pickerProjection.unsupportedLayout", defaultValue: "Unsupported layout on mobile"),
              selected: view.id == current, disabled: !view.isTable
            ) { [weak self] in
              guard let self, let ref = pending?.ref ?? self.projectSettings.activeProject else { return }
              self.dismiss(animated: true)
              self.commitProjectView(ref, viewId: view.id, views: views)
            }
          })
      ]
    }
    presentTaskSheet(sheet)
  }

  private func showProjectFieldsPicker() {
    let sheet = TaskSheetViewController(
      title: String(localized: "tasks.filterPickers.fieldsTitle", defaultValue: "Project Fields"),
      subtitle: String(localized: "tasks.filterPickers.fieldsSubtitle", defaultValue: "Choose which Project fields appear on item cards.")
    ) { [weak self] _ in
      guard let self, let table = self.projectTable else { return [] }
      let hidden = Set(self.hiddenProjectFields[table.visibilityKey] ?? [])
      guard !table.summaryFields.isEmpty else {
        return [
          TaskSheetSection(rows: [
            TaskSheetRow(
              title: String(localized: "tasks.filterPickers.noFields", defaultValue: "This view has no extra fields to show."),
              disabled: true)
          ])
        ]
      }
      return [
        TaskSheetSection(
          rows: table.summaryFields.map { field in
            let shown = !hidden.contains(field.id)
            return TaskSheetRow(
              title: field.name,
              subtitle: shown
                ? String(localized: "tasks.filterPickers.fieldShown", defaultValue: "Shown on cards")
                : String(localized: "tasks.filterPickers.fieldHidden", defaultValue: "Hidden from cards"),
              selected: shown
            ) { [weak self] in self?.toggleProjectField(field.id, in: table) }
          })
      ]
    }
    presentTaskSheet(sheet)
  }

  private func toggleProjectField(_ fieldId: String, in table: GitHubProjectTable) {
    var hidden = Set(hiddenProjectFields[table.visibilityKey] ?? [])
    if hidden.contains(fieldId) { hidden.remove(fieldId) } else { hidden.insert(fieldId) }
    hiddenProjectFields[table.visibilityKey] = hidden.isEmpty ? nil : hidden.sorted()
    persistResume()
    updateChrome()
    rebuildSections()
  }

  /// Picking the active field again flips it to descending, then back to the view's own order.
  private func cycleProjectSort(_ fieldId: String?) {
    if let fieldId, prefs.projectSortField == fieldId {
      if prefs.projectSortDescending {
        prefs.projectSortField = nil
        prefs.projectSortDescending = false
      } else {
        prefs.projectSortDescending = true
      }
    } else {
      prefs.projectSortField = fieldId
      prefs.projectSortDescending = false
    }
    savePrefs()
    updateChrome()
    rebuildSections()
  }

  private var projectViewURL: URL? {
    guard let table = projectTable, let base = table.projectURL, table.view.number > 0 else { return nil }
    return URL(string: "\(base)/views/\(table.view.number)")
  }

  private func visibleProjectRows(_ table: GitHubProjectTable) -> [GitHubProjectRow] {
    table.sortedRows(by: prefs.projectSortField.map { ($0, prefs.projectSortDescending) })
  }

  // MARK: New issue

  private func newIssue() {
    let api = session.api
    if provider == .linear {
      guard !linearTeams.isEmpty else { return }
      let teams = linearTeams
      let compose = NewTaskIssueViewController(
        providerLabel: "Linear", isLinear: true,
        targets: teams.map { .init(id: $0.id, label: $0.name, detail: $0.workspaceName ?? $0.key) },
        selected: teams.first { selectedTeamIds.contains($0.id) }?.id
      ) { teamId, title, body in
        guard let team = teams.first(where: { $0.id == teamId }) else { return }
        _ = try await api.createLinearIssue(team: team, title: title, description: body)
      } onCreated: { [weak self] in
        self?.reload(force: true)
      }
      presentCompose(compose)
      return
    }
    // The list may not have read the projects yet (or the read failed); read them now rather than ignore the tap.
    guard !repos.isEmpty else {
      Task { [weak self] in
        guard let self, let loaded = try? await self.loadRepos(force: false), !loaded.isEmpty else { return }
        self.newIssue()
      }
      return
    }
    let compose = NewTaskIssueViewController(
      providerLabel: "GitHub", isLinear: false,
      targets: repos.map { .init(id: $0.id, label: $0.displayName, detail: nil) },
      selected: repos.first { selectedRepoIds.contains($0.id) }?.id,
      issueSource: { [weak self] repoId in
        guard let self, let sources = self.issueSources[repoId], sources.hasChoice else { return nil }
        return .init(
          upstream: sources.upstreamCandidate?.slug ?? "", origin: sources.prs?.slug ?? "",
          usesOrigin: self.repos.first { $0.id == repoId }?.issueSourcePreference == "origin")
      },
      setIssueSource: { [weak self] repoId, origin in
        try await api.setIssueSourcePreference(repoId: repoId, origin ? "origin" : "upstream")
        if let repos = try? await api.taskRepos() { self?.repos = repos }
      }
    ) { repoId, title, body in
      try await api.createGitHubIssue(repoId: repoId, title: title, body: body)
    } onCreated: { [weak self] in
      self?.reload(force: true)
    }
    presentCompose(compose)
  }

  private func presentCompose(_ compose: UIViewController) {
    let navigation = UINavigationController(rootViewController: compose)
    navigation.sheetPresentationController?.detents = [.large()]
    navigation.sheetPresentationController?.prefersGrabberVisible = true
    topPresenter.present(navigation, animated: true)
  }

  // MARK: Loading

  private var requestKey: String {
    [
      provider.rawValue, githubMode == .project ? "project" : "items", appliedQuery, linearFilter, jiraFilter,
      prefs.gitlabView, prefs.gitlabFilter, jiraAccount?.selection ?? "", linearAccount?.selectedWorkspaceId ?? "",
      projectSettings.activeProject?.key ?? "", projectSettings.activeProject.flatMap { projectSettings.lastViewByProject[$0.key] } ?? "",
      selectedRepoIds.sorted().joined(separator: ","),
    ].joined(separator: "|")
  }

  private func refresh() {
    if provider == .jira { jiraAccount = nil }
    if provider == .linear { linearAccount = nil }
    reload(force: true)
  }

  private func reload(force: Bool = false) {
    guard session.connectionState == .connected else {
      showState()
      return
    }
    guard !hydrating else { return }
    loadedKey = requestKey
    loadTask?.cancel()
    loading = true
    loadError = nil
    // A new view or search starts empty; Refresh keeps the rows up while it reads.
    if !force {
      pages = []
      currentPage = 0
      countedTotalPages = nil
      gitlabItems = []
      todos = []
      issues = []
      if isProjectMode { projectTable = nil }
    }
    rebuildSections()
    switch provider {
    case .github where githubMode == .project: loadProject(force: force)
    case .github: loadGitHub(force: force)
    case .gitlab: loadGitLab(force: force)
    case .linear: loadLinear(force: force)
    case .jira: loadJira(force: force)
    }
  }

  /// The repositories the list reads: the picked ones, or all, each project once.
  private var queriedRepos: [TaskRepo] {
    let picked = repos.filter { selectedRepoIds.contains($0.id) }
    return picked.isEmpty ? repos : picked
  }

  private func loadRepos(force: Bool) async throws -> [TaskRepo] {
    let loaded = force || repos.isEmpty ? try await session.api.taskRepos() : repos
    if repos != loaded {
      repos = loaded
      // Picked repositories that are gone widen the filter rather than hide every row.
      let ids = Set(loaded.map(\.id))
      let kept = selectedRepoIds.filter(ids.contains)
      if kept.count != selectedRepoIds.count { selectedRepoIds = kept }
      updateChrome()
    }
    return queriedRepos
  }

  private func loadGitHub(force: Bool) {
    let key = requestKey
    let api = session.api
    let query = appliedQuery
    let narrowed = !selectedRepoIds.isEmpty
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let queried = try await self.loadRepos(force: force)
        guard !Task.isCancelled else { return }
        if queried.isEmpty {
          self.finishGitHub(page: [], failures: 0, of: 0, key: key)
          return
        }
        let (items, failures) = await self.fetchGitHubPage(queried, query: query, page: 0)
        guard !Task.isCancelled else { return }
        self.finishGitHub(page: items, failures: failures.count, of: queried.count, error: failures.first, key: key)
        // A narrowed list counts its pages; all-repo mode relies on a full page to reach the next.
        if narrowed {
          let limit = GitHubTaskPaging.perRepoLimit(repoCount: queried.count)
          let counts = await withTaskGroup(of: Int.self) { group in
            for repo in queried { group.addTask { (try? await api.countGitHubWorkItems(in: repo, query: query)) ?? 0 } }
            return await group.reduce(into: [Int]()) { $0.append($1) }
          }
          guard key == self.loadedKey else { return }
          let total = GitHubTaskPaging.countedTotalPages(counts, perRepoLimit: limit)
          self.countedTotalPages = total > 0 ? total : nil
          self.rebuildSections()
        }
      } catch {
        guard !Task.isCancelled else { return }
        self.finishGitHub(page: [], failures: 1, of: 1, error: Self.message(error), key: key)
      }
    }
  }

  /// One task page across repositories, four at a time as the desktop runs them.
  private func fetchGitHubPage(_ queried: [TaskRepo], query: String, page: Int) async -> ([GitHubWorkItem], [String]) {
    let api = session.api
    let limit = GitHubTaskPaging.perRepoLimit(repoCount: queried.count)
    var collected: [GitHubWorkItem] = []
    var failures: [String] = []
    for chunk in stride(from: 0, to: queried.count, by: 4).map({ Array(queried[$0..<min($0 + 4, queried.count)]) }) {
      await withTaskGroup(of: (String, Result<(items: [GitHubWorkItem], sources: GitHubIssueSources?), Error>).self) {
        group in
        for repo in chunk {
          group.addTask {
            (repo.id, await Result { try await api.githubWorkItemPage(in: repo, query: query, limit: limit, page: page + 1) })
          }
        }
        for await (repoId, result) in group {
          switch result {
          case .success(let reply):
            collected += reply.items
            if let sources = reply.sources { issueSources[repoId] = sources }
          case .failure(let error): failures.append(Self.message(error))
          }
        }
      }
      if Task.isCancelled { break }
    }
    // Host pages come in issue-number order; merge them the same way so rows don't reshuffle.
    return (collected.sorted { $0.number > $1.number }, failures)
  }

  private func finishGitHub(page: [GitHubWorkItem], failures: Int, of total: Int, error: String? = nil, key: String) {
    guard key == loadedKey else { return }
    loading = false
    loadError = failures > 0 && failures == total ? error : nil
    notice = failures > 0 && failures < total ? Self.partialNotice(failures, of: total) : nil
    pages = [page]
    currentPage = 0
    if loadError == nil { persistResume() }
    rebuildSections()
  }

  private static func partialNotice(_ failed: Int, of total: Int) -> String {
    String.localizedStringWithFormat(
      String(localized: "orcaios.tasks.partialFailure", defaultValue: "%1$@ of %2$lld repositories failed to load."),
      String(failed), total)
  }

  /// GitHub's page count: counted when the list is narrowed, else as many as are loaded.
  private var totalPages: Int { max(countedTotalPages ?? pages.count, pages.count) }

  /// One full per-repository page may have more behind it.
  private var canLoadUncountedNext: Bool {
    guard countedTotalPages == nil, let last = pages.last else { return false }
    let limit = GitHubTaskPaging.perRepoLimit(repoCount: queriedRepos.count)
    return Dictionary(grouping: last, by: \.repoId).values.contains { $0.count >= limit }
  }

  private func goToPage(_ target: Int) {
    guard target >= 0, !pageLoading, !loading, target <= pages.count else { return }
    if target < pages.count {
      currentPage = target
      rebuildSections()
      table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
      return
    }
    let key = requestKey
    let query = appliedQuery
    let queried = queriedRepos
    pageLoading = true
    rebuildSections()
    Task {
      let (items, failures) = await fetchGitHubPage(queried, query: query, page: target)
      pageLoading = false
      guard key == loadedKey else { return }
      if items.isEmpty {
        let page = String(target + 1)
        alert(
          failures.isEmpty
            ? String(format: String(localized: "tasks.pagination.noMoreResults", defaultValue: "No more results on page %@."), page)
            : String(
              format: String(localized: "tasks.pagination.loadPageFailed", defaultValue: "Page %@ could not be loaded from GitHub."),
              page))
        // A page past the end proves the count.
        if failures.isEmpty { countedTotalPages = pages.count }
        rebuildSections()
        return
      }
      pages.append(items)
      currentPage = target
      rebuildSections()
      table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    }
  }

  private func loadGitLab(force: Bool) {
    let key = requestKey
    let api = session.api
    let query = appliedQuery
    let view = prefs.gitlabView
    let state = prefs.gitlabFilter
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let queried = try await self.loadRepos(force: force)
        guard !Task.isCancelled else { return }
        if view == "todos" {
          guard let first = queried.first else {
            self.finishGitLab(items: [], todos: [], failures: 0, of: 0, key: key)
            return
          }
          let todos = try await api.gitlabTodos(via: first)
          self.finishGitLab(items: [], todos: todos.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }, failures: 0, of: 1, key: key)
          return
        }
        var collected: [GitHubWorkItem] = []
        var failures: [String] = []
        for chunk in stride(from: 0, to: queried.count, by: 4).map({ Array(queried[$0..<min($0 + 4, queried.count)]) }) {
          await withTaskGroup(of: Result<(items: [GitHubWorkItem], error: String?), Error>.self) { group in
            for repo in chunk {
              group.addTask { await Result { try await api.gitlabWorkItems(in: repo, state: state, query: query) } }
            }
            for await result in group {
              switch result {
              case .success(let reply):
                if let error = reply.error { failures.append(error) } else { collected += reply.items }
              case .failure(let error): failures.append(Self.message(error))
              }
            }
          }
          if Task.isCancelled { return }
        }
        self.finishGitLab(
          items: collected, todos: [], failures: failures.count, of: queried.count, error: failures.first, key: key)
      } catch {
        guard !Task.isCancelled else { return }
        self.finishGitLab(items: [], todos: [], failures: 1, of: 1, error: Self.message(error), key: key)
      }
    }
  }

  private func finishGitLab(
    items: [GitHubWorkItem], todos: [GitLabTodo], failures: Int, of total: Int, error: String? = nil, key: String
  ) {
    guard key == loadedKey else { return }
    loading = false
    loadError = failures > 0 && failures == total ? error : nil
    notice = failures > 0 && failures < total ? Self.partialNotice(failures, of: total) : nil
    gitlabItems = items
    self.todos = todos
    rebuildSections()
  }

  /// Linear: whether the desktop has the account, its teams for the workspace read, then the issues.
  private func loadLinear(force: Bool) {
    let key = requestKey
    let api = session.api
    let query = appliedQuery
    let filter = linearFilter
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let account = try await api.linearAccount()
        guard !Task.isCancelled else { return }
        let changed = self.linearConnected != account.connected
        self.linearConnected = account.connected
        // A workspace picked here outlives the desktop's own choice until the next status read.
        let workspace = self.linearAccount?.selectedWorkspaceId ?? account.selectedWorkspaceId
        self.linearAccount = account
        self.linearAccount?.selectedWorkspaceId = workspace
        if changed { self.updateChrome() }
        guard account.connected else {
          self.finishTracker([], error: nil, key: key)
          return
        }
        if force || self.teamsWorkspace != .some(workspace) {
          let teams = (try? await api.linearTeams(workspaceId: workspace)) ?? []
          self.linearTeams = teams
          self.teamsWorkspace = .some(workspace)
          // Saved teams that are gone widen back to all.
          let ids = Set(teams.map(\.id))
          let kept = self.selectedTeamIds.filter(ids.contains)
          self.selectedTeamIds = kept.isEmpty || kept.count == teams.count ? [] : kept
          self.updateChrome()
        }
        let issues = try await api.linearIssues(filter: filter, query: query, workspaceId: workspace)
        guard !Task.isCancelled else { return }
        self.finishTracker(issues, error: nil, key: key)
      } catch {
        guard !Task.isCancelled else { return }
        self.finishTracker([], error: Self.message(error), key: key)
      }
    }
  }

  /// Jira: its sites (read once), then the preset's issues, or the search run as Jira reads typed input.
  private func loadJira(force: Bool) {
    let key = requestKey
    let api = session.api
    let query = appliedQuery
    let filter = jiraFilter
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        if force || self.jiraAccount == nil {
          var account = try await api.jiraAccount()
          if let saved = self.prefs.jiraSite, saved == "all" || account.sites.contains(where: { $0.id == saved }) {
            account.selection = saved
          }
          self.jiraAccount = account
          self.jiraConnected = account.connected
          self.updateChrome()
          // The site changed the key; this read still belongs to the screen.
          self.loadedKey = self.requestKey
        }
        let current = self.loadedKey ?? key
        guard let account = self.jiraAccount, account.connected else {
          self.finishTracker([], error: nil, key: current)
          return
        }
        if query.isEmpty {
          let issues = try await api.jiraIssues(filter: filter, siteId: account.selection)
          self.finishTracker(issues, error: nil, key: current)
        } else {
          let (issues, rejection) = try await api.searchJira(query, siteId: account.selection)
          if let rejection, issues.isEmpty {
            // Nothing matched as text either, so Jira's JQL error is the answer, not an empty list.
            let reason = String(
              localized: "auto.components.taskPageJiraLoadState.jqlFailed",
              defaultValue: "Jira couldn't run this JQL query. Check the syntax and try again.")
            self.finishTracker([], error: [reason, rejection].filter { !$0.isEmpty }.joined(separator: " "), key: current)
            return
          }
          self.finishTracker(
            issues, error: nil,
            notice: rejection.map {
              [
                String(
                  localized: "auto.components.TaskPage.jiraTextMatchesNotice",
                  defaultValue: "Showing text matches. Jira couldn't run this search as JQL."), $0,
              ].filter { !$0.isEmpty }.joined(separator: " ")
            }, key: current)
        }
      } catch {
        guard !Task.isCancelled else { return }
        self.finishTracker([], error: Self.message(error), key: self.loadedKey ?? key)
      }
    }
  }

  private func finishTracker(_ issues: [TrackerIssue], error: String?, notice: String? = nil, key: String) {
    guard key == loadedKey else { return }
    loading = false
    loadError = error
    self.notice = notice
    self.issues = issues
    if error == nil { persistResume() }
    rebuildSections()
  }

  /// The active project's remembered view, read with the search in place of its filter.
  private func loadProject(force: Bool) {
    let key = requestKey
    let api = session.api
    guard let project = projectSettings.activeProject else {
      loading = false
      persistResume()
      rebuildSections()
      return
    }
    guard let viewId = projectSettings.lastViewByProject[project.key] else {
      loading = false
      selectProject(project)
      return
    }
    let query = projectQuery
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        if self.projectViews.isEmpty { self.projectViews = (try? await api.githubProjectViews(project)) ?? [] }
        let table = try await api.githubProjectTable(project, viewId: viewId, query: query)
        guard !Task.isCancelled, key == self.loadedKey else { return }
        self.loading = false
        self.projectError = nil
        self.projectTable = table
        if query == nil, let filter = table?.filter {
          self.appliedQuery = filter
          self.search.searchBar.text = filter
          self.loadedKey = self.requestKey
        }
        self.persistResume()
        self.updateChrome()
        self.rebuildSections()
      } catch {
        guard !Task.isCancelled, key == self.loadedKey else { return }
        self.loading = false
        self.projectTable = nil
        self.projectError = Self.message(error)
        self.rebuildSections()
      }
    }
  }

  static func message(_ error: Error) -> String {
    if let error = error as? RPCError, !error.message.isEmpty { return error.message }
    return error.localizedDescription
  }

  // MARK: Sections

  private func rebuildSections() {
    var useBoard = false
    switch provider {
    case .github where githubMode == .project:
      sections = projectSections()
    case .github:
      sections = itemSections(pages.indices.contains(currentPage) ? pages[currentPage] : [])
    case .gitlab:
      sections =
        prefs.gitlabView == "todos"
        ? (todos.isEmpty ? [] : [ListSection(key: "todos", rows: todos.map(Row.todo))])
        : itemSections(gitlabItems)
    case .linear:
      let sorted = TrackerIssue.sorted(filteredLinear, by: LinearOrder(rawValue: prefs.linearOrder) ?? .priority)
      let grouping = LinearGrouping(rawValue: prefs.linearGroup) ?? .none
      if prefs.linearLayout == "board", !sorted.isEmpty {
        useBoard = true
        // No grouping still needs columns: the board falls back to status.
        let groups = TrackerIssue.grouped(sorted, by: grouping == .none ? .status : grouping)
        board.show(
          groups.map { group in
            let first = group.issues[0]
            return .init(
              title: linearGroupLabel(first, grouping == .none ? .status : grouping),
              color: linearGroupColor(first, grouping == .none ? .status : grouping), issues: group.issues)
          })
        sections = []
      } else if grouping == .none {
        sections = sorted.isEmpty ? [] : [ListSection(key: "all", rows: sorted.map(Row.tracker))]
      } else {
        sections = TrackerIssue.grouped(sorted, by: grouping).map { group in
          let first = group.issues[0]
          return ListSection(
            key: group.key, title: linearGroupLabel(first, grouping), color: linearGroupColor(first, grouping),
            count: group.issues.count, rows: group.issues.map(Row.tracker))
        }
      }
    case .jira:
      let sorted = issues.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
      if sort == .repository {
        var order: [String] = []
        var byProject: [String: [TrackerIssue]] = [:]
        for issue in sorted {
          let key = issue.projectName ?? issue.group ?? ""
          if byProject[key] == nil { order.append(key) }
          byProject[key, default: []].append(issue)
        }
        sections = order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
          ListSection(key: $0, title: $0, rows: (byProject[$0] ?? []).map(Row.tracker))
        }
      } else {
        sections = sorted.isEmpty ? [] : [ListSection(key: "all", rows: sorted.map(Row.tracker))]
      }
    }
    board.isHidden = !useBoard
    table.isHidden = useBoard
    table.reloadData()
    updateNotice()
    updatePager()
    showState()
  }

  private var filteredLinear: [TrackerIssue] {
    guard !selectedTeamIds.isEmpty, selectedTeamIds.count < linearTeams.count else { return issues }
    return issues.filter { $0.teamId.map(selectedTeamIds.contains) ?? false }
  }

  private func itemSections(_ items: [GitHubWorkItem]) -> [ListSection] {
    switch sort {
    case .updated:
      let sorted = items.sorted {
        ($0.updatedDate ?? .distantPast, $0.number) > ($1.updatedDate ?? .distantPast, $1.number)
      }
      return sorted.isEmpty ? [] : [ListSection(key: "all", rows: sorted.map(Row.item))]
    case .repository:
      var order: [String] = []
      var byRepo: [String: [GitHubWorkItem]] = [:]
      for item in items {
        if byRepo[item.repoId] == nil { order.append(item.repoId) }
        byRepo[item.repoId, default: []].append(item)
      }
      return order.sorted {
        (byRepo[$0]?.first?.repoName ?? "").localizedStandardCompare(byRepo[$1]?.first?.repoName ?? "")
          == .orderedAscending
      }.map { id in
        let rows = (byRepo[id] ?? []).sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
        return ListSection(
          key: id, title: rows.first?.repoName, color: repos.first { $0.id == id }.map(Self.repoColor),
          rows: rows.map(Row.item))
      }
    }
  }

  private func projectSections() -> [ListSection] {
    guard let table = projectTable else { return [] }
    let rows = visibleProjectRows(table)
    guard !rows.isEmpty else { return [] }
    return table.groups(rows).map { group in
      let collapsed = collapsedGroups.contains(group.key)
      return ListSection(
        key: group.key,
        title: table.groupBy == nil
          ? nil : (group.label.isEmpty ? String(localized: "tasks.githubProjectList.items", defaultValue: "Items") : group.label),
        count: table.groupBy == nil ? nil : group.rows.count, collapsible: table.groupBy != nil,
        rows: collapsed ? [] : group.rows.map(Row.project))
    }
  }

  private func linearGroupLabel(_ issue: TrackerIssue, _ grouping: LinearGrouping) -> String {
    switch grouping {
    case .none: String(localized: "tasks.reviewerLinear.issues", defaultValue: "Issues")
    case .status: issue.state ?? ""
    case .assignee: issue.assignee ?? String(localized: "tasks.reviewerLinear.unassigned", defaultValue: "Unassigned")
    case .priority: TrackerIssueDetailViewController.priorityLabel(issue.priority)
    case .team: issue.teamName ?? issue.group ?? ""
    }
  }

  private func linearGroupColor(_ issue: TrackerIssue, _ grouping: LinearGrouping) -> UIColor {
    switch grouping {
    case .status, .team: issue.stateColor.flatMap { UIColor(hex: $0) } ?? Palette.textMuted
    case .priority: issue.priority == 1 ? Palette.statusRed : Palette.accentBlue
    case .none, .assignee: Palette.accentBlue
    }
  }

  /// Linear's row text: identifier, then the chosen properties (reviewerLinear linearIssueSecondaryParts).
  private func linearSubtitle(_ issue: TrackerIssue) -> String {
    let shown = Set(linearDisplay)
    var parts = [issue.identifier]
    if shown.contains("state"), let state = issue.state { parts.append(state) }
    if shown.contains("priority") { parts.append(TrackerIssueDetailViewController.priorityLabel(issue.priority)) }
    if shown.contains("assignee"), let assignee = issue.assignee { parts.append(assignee) }
    if shown.contains("team"), let team = issue.teamName { parts.append(team) }
    if shown.contains("labels"), !issue.labels.isEmpty { parts.append(issue.labels.prefix(2).joined(separator: ", ")) }
    if shown.contains("updated"), let date = issue.updatedDate,
      let age = RelativeTime.short(date.timeIntervalSince1970 * 1000)
    {
      parts.append(age)
    }
    return parts.joined(separator: " · ")
  }

  /// Partial failures and Jira's fallback note, above the rows.
  private func updateNotice() {
    guard let notice, !notice.isEmpty, !sections.isEmpty else {
      table.tableHeaderView = nil
      return
    }
    let label = UILabel()
    label.text = notice
    label.font = .systemFont(ofSize: 13)
    label.textColor = Palette.statusAmber
    label.numberOfLines = 0
    let width = max(table.bounds.width - 2 * Spacing.xl, 100)
    let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let header = UIView(frame: CGRect(x: 0, y: 0, width: table.bounds.width, height: height + Spacing.md))
    label.frame = CGRect(x: Spacing.xl, y: Spacing.sm, width: width, height: height)
    label.autoresizingMask = [.flexibleWidth]
    header.addSubview(label)
    table.tableHeaderView = header
  }

  /// Previous, the page (which opens the page list) and Next under GitHub's rows (mobile-tasks-provider-item-list.tsx).
  private func updatePager() {
    let show =
      provider == .github && githubMode == .items && !loading && !pages.isEmpty
      && (totalPages > 1 || canLoadUncountedNext)
    guard show else {
      table.tableFooterView = nil
      return
    }
    let previous = UIButton(configuration: .glass())
    previous.configuration?.image = Lucide.chevronLeft.image(size: 17)
    previous.accessibilityLabel = String(localized: "tasks.providerItemList.previousPage", defaultValue: "Previous page")
    previous.isEnabled = currentPage > 0 && !pageLoading
    previous.addAction(UIAction { [weak self] _ in self?.goToPage((self?.currentPage ?? 1) - 1) }, for: .primaryActionTriggered)
    let next = UIButton(configuration: .glass())
    next.configuration?.image = Lucide.chevronRight.image(size: 17)
    next.configuration?.showsActivityIndicator = pageLoading
    next.accessibilityLabel = String(localized: "tasks.providerItemList.nextPage", defaultValue: "Next page")
    next.isEnabled = !pageLoading && (canLoadUncountedNext || currentPage < totalPages - 1)
    next.addAction(UIAction { [weak self] _ in self?.goToPage((self?.currentPage ?? -1) + 1) }, for: .primaryActionTriggered)
    let page = UIButton(configuration: .plain())
    let pageText =
      countedTotalPages == nil
      ? String(format: String(localized: "tasks.providerItemList.page", defaultValue: "Page %@"), String(currentPage + 1))
      : String(
        format: String(localized: "tasks.providerItemList.pageOfTotal", defaultValue: "Page %1$@ of %2$@"),
        String(currentPage + 1), String(totalPages))
    var attributes = AttributeContainer()
    attributes.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    page.configuration?.attributedTitle = AttributedString(pageText, attributes: attributes)
    page.configuration?.baseForegroundColor = Palette.textPrimary
    page.isEnabled = !pageLoading
    page.addAction(UIAction { [weak self] _ in self?.showPagePicker() }, for: .primaryActionTriggered)
    let stack = UIStackView(arrangedSubviews: [previous, page, next])
    stack.spacing = Spacing.md
    stack.alignment = .center
    let footer = UIView(frame: CGRect(x: 0, y: 0, width: table.bounds.width, height: 72))
    stack.translatesAutoresizingMaskIntoConstraints = false
    footer.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
      previous.widthAnchor.constraint(equalToConstant: 44),
      previous.heightAnchor.constraint(equalToConstant: 44),
      next.widthAnchor.constraint(equalToConstant: 44),
      next.heightAnchor.constraint(equalToConstant: 44),
    ])
    table.tableFooterView = footer
  }

  private var rowCount: Int {
    if !board.isHidden { return 1 }
    return sections.reduce(0) { $0 + $1.rows.count } + sections.filter(\.collapsible).count
  }

  private func showState() {
    guard isViewLoaded else { return }
    var config: UIContentUnavailableConfiguration?
    if session.connectionState != .connected {
      config = .empty()
      config?.image = Lucide.wifiOff.image(size: 24, strokeWidth: 1.75)
      config?.text = String(
        format: String(localized: "common.offline.waitingFor", defaultValue: "Waiting for %@"), session.name)
      config?.secondaryText = String(
        localized: "common.offline.message", defaultValue: "Check that the host is awake and Orca is running.")
    } else if (loading || hydrating) && rowCount == 0 {
      config = .loading()
      config?.text =
        isProjectMode
        ? String(localized: "tasks.githubProjectList.loading", defaultValue: "Loading project…")
        : String(localized: "tasks.listState.loading", defaultValue: "Loading tasks…")
    } else if provider == .linear, linearConnected == false {
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
    } else if provider == .jira, jiraConnected == false {
      config = .empty()
      config?.image = Lucide.listTodo.image(size: 24, strokeWidth: 1.75)
      config?.text = String(localized: "components.jiraConnectPrompt.connectOnDesktop", defaultValue: "Connect Jira on your desktop")
      config?.secondaryText = String(
        localized: "components.jiraConnectPrompt.connectHint",
        defaultValue: "Add your Jira site in Orca desktop under Settings → Integrations, then check again.")
      var check = UIButton.Configuration.glass()
      check.title = String(localized: "components.jiraConnectPrompt.checkAgain", defaultValue: "Check again")
      config?.button = check
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.refresh() }
    } else if isProjectMode, projectSettings.activeProject == nil {
      config = .empty()
      config?.image = Lucide.listTodo.image(size: 24, strokeWidth: 1.75)
      config?.text = String(localized: "tasks.githubProjectList.chooseProject", defaultValue: "Choose a GitHub project")
      var browse = UIButton.Configuration.glass()
      browse.title = String(localized: "tasks.githubProjectList.browseProjects", defaultValue: "Browse projects")
      config?.button = browse
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.showProjectPicker() }
    } else if let error = isProjectMode ? projectError : loadError, rowCount == 0 {
      config = .empty()
      config?.image = Lucide.circleAlert.image(size: 24, strokeWidth: 1.75)
      config?.text = String(localized: "common.loadError.title", defaultValue: "Unable to Load")
      config?.secondaryText = error
      var retry = UIButton.Configuration.glass()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config?.button = retry
      config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload(force: true) }
    } else if rowCount == 0, !loading {
      config = .empty()
      config?.image = Lucide.inbox.image(size: 24, strokeWidth: 1.75)
      let searched =
        isProjectMode
        ? projectQuery != nil
        : provider == .github ? appliedQuery != preset.query : !appliedQuery.isEmpty
      let empty =
        switch provider {
        case .github:
          isProjectMode
            ? String(localized: "tasks.githubProjectList.noItems", defaultValue: "No project items")
            : String(localized: "tasks.taskViewOptions.noGitHubTasks", defaultValue: "No GitHub tasks")
        case .gitlab: String(localized: "tasks.taskViewOptions.noGitLabTasks", defaultValue: "No GitLab tasks")
        case .linear: String(localized: "tasks.taskViewOptions.noLinearTasks", defaultValue: "No Linear tasks")
        case .jira: String(localized: "tasks.taskViewOptions.noJiraTasks", defaultValue: "No Jira tasks")
        }
      config?.text =
        searched
        ? (isProjectMode
          ? String(localized: "tasks.githubProjectList.noMatches", defaultValue: "No project items match.")
          : String(localized: "tasks.connectionPresentation.noMatchingTasks", defaultValue: "No matching tasks"))
        : empty
    }
    // components/feedback/MobileStateView.tsx: a 24 pt muted glyph over a 15 pt semibold title.
    config?.imageProperties.tintColor = Palette.textMuted
    config?.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
    config?.textProperties.color = Palette.textPrimary
    config?.secondaryTextProperties.font = .systemFont(ofSize: 13)
    config?.secondaryTextProperties.color = Palette.textSecondary
    // Behind the list, so the source switch and chips above it stay live.
    table.backgroundView = config.map { UIContentUnavailableView(configuration: $0) }
    if config != nil {
      board.isHidden = true
      table.isHidden = false
    }
  }

  private func connectLinear() {
    let alert = UIAlertController(
      title: String(localized: "tasks.tasksCreateDrawers.connectLinearWorkspace", defaultValue: "Connect Linear workspace"),
      message: String(
        localized: "tasks.tasksCreateDrawers.linearConnectSubtitle",
        defaultValue: "Paste a Personal API key to browse issues from that workspace."), preferredStyle: .alert)
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
            if !self.providers.contains(.linear) {
              self.providers.append(.linear)
              self.rebuildProviderControl()
            }
            self.linearAccount = nil
            self.reload(force: true)
          } catch {
            self.alert(Self.message(error))
          }
        }
      })
    topPresenter.present(alert, animated: true)
  }

  // MARK: Opening rows

  private func open(_ issue: TrackerIssue) {
    navigationController?.pushViewController(TrackerIssueDetailViewController(session: session, issue: issue), animated: true)
  }

  private func openDetail(_ item: GitHubWorkItem) {
    let detail = TaskDetailViewController(session: session, item: item)
    detail.onOpenWorkspace = onOpenWorkspace
    navigationController?.pushViewController(detail, animated: true)
  }

  /// A project row's issue or pull request opens on its own page when a project here points at its repository.
  private func open(_ row: GitHubProjectRow) {
    let fallback = { if let url = row.url.flatMap(URL.init(string:)) { UIApplication.shared.open(url) } }
    guard let slug = row.repository?.lowercased(), row.number != nil, row.itemType != "DRAFT_ISSUE" else {
      fallback()
      return
    }
    let api = session.api
    Task {
      if repoSlugs == nil {
        let repos = (try? await loadRepos(force: false)) ?? []
        let all = self.repos.isEmpty ? repos : self.repos
        var slugs: [String: TaskRepo] = [:]
        await withTaskGroup(of: (TaskRepo, GitHubOwnerRepo?).self) { group in
          for repo in all { group.addTask { (repo, try? await api.githubRepoSlug(repoId: repo.id)) } }
          for await (repo, owner) in group {
            if let owner { slugs[owner.slug.lowercased()] = slugs[owner.slug.lowercased()] ?? repo }
          }
        }
        repoSlugs = slugs
      }
      guard let repo = repoSlugs?[slug], let item = row.workItem(in: repo) else {
        fallback()
        return
      }
      openDetail(item)
    }
  }

  // MARK: Rows

  private func configure(_ cell: UITableViewCell, _ row: Row) {
    var content = UIListContentConfiguration.subtitleCell()
    content.textProperties.font = .systemFont(ofSize: 16)
    content.textProperties.numberOfLines = 2
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.font = .systemFont(ofSize: 13)
    content.secondaryTextProperties.numberOfLines = 2
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    switch row {
    case .item(let item):
      content.text = item.title
      let marker = provider == .gitlab && item.kind == .pr ? "!" : "#"
      var meta = ["\(item.repoName) \(marker)\(item.number)"]
      if let author = item.author, !author.isEmpty { meta.append(author) }
      if let date = item.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) { meta.append(age) }
      content.secondaryText = meta.joined(separator: " · ")
      let glyph = TaskStateGlyph(item)
      content.image = glyph.icon.image(size: 18)
      content.imageProperties.tintColor = glyph.color
      cell.accessibilityLabel = "\(item.title), \(glyph.label)"
    case .tracker(let issue):
      content.text = issue.title
      if issue.provider == .linear {
        content.secondaryText = linearSubtitle(issue)
      } else {
        var meta = [issue.identifier]
        if let project = issue.projectName ?? issue.group { meta.append(project) }
        if let state = issue.state { meta.append(state) }
        if let date = issue.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) { meta.append(age) }
        content.secondaryText = meta.joined(separator: " · ")
      }
      let glyph = TrackerIssueGlyph(issue)
      content.image = glyph.icon.image(size: 18)
      content.imageProperties.tintColor = glyph.color
      cell.accessibilityLabel = "\(issue.identifier), \(issue.title)"
    case .todo(let todo):
      content.text = todo.targetTitle ?? todo.targetUrl
      var meta = [todo.targetRef.isEmpty ? todo.projectPath : "\(todo.projectPath) \(todo.targetRef)"]
      meta.append(todo.actionName.replacingOccurrences(of: "_", with: " "))
      if let date = todo.updatedDate, let age = RelativeTime.short(date.timeIntervalSince1970 * 1000) { meta.append(age) }
      content.secondaryText = meta.joined(separator: " · ")
      content.image = (todo.targetType == "MergeRequest" ? Lucide.gitPullRequest : Lucide.circleDot).image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
    case .project(let item):
      content.text = item.title
      let repository = item.repository ?? projectTable?.projectTitle ?? ""
      let number = item.number.map { " #\($0)" } ?? ""
      let kind =
        switch item.itemType {
        case "PULL_REQUEST":
          String(
            format: String(localized: "tasks.githubProjectList.pullRequestSubtitle", defaultValue: "Pull request · %1$@%2$@"),
            repository, number)
        case "ISSUE":
          String(
            format: String(localized: "tasks.githubProjectList.issueSubtitle", defaultValue: "Issue · %1$@%2$@"), repository,
            number)
        default:
          String(
            format: String(localized: "tasks.githubProjectList.itemSubtitle", defaultValue: "Project item · %1$@%2$@"),
            repository, number)
        }
      var lines = [kind]
      if let table = projectTable {
        let hidden = Set(hiddenProjectFields[table.visibilityKey] ?? [])
        let fields = table.summaryFields.filter { !hidden.contains($0.id) && $0.id != table.groupBy?.id }
        let values = fields.prefix(4).compactMap { field in item.value(for: field).map { "\(field.name): \($0)" } }
        var line = values.joined(separator: " · ")
        if fields.count > 4 {
          line += " "
            + String.localizedStringWithFormat(
              String(localized: "tasks.githubProjectList.moreFields", defaultValue: "+%lld fields"), fields.count - 4)
        }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
      }
      content.secondaryText = lines.joined(separator: "\n")
      content.secondaryTextProperties.numberOfLines = 3
      let state = (item.state ?? "OPEN").lowercased()
      let glyph: (Lucide, UIColor) =
        switch (item.itemType, state) {
        case ("PULL_REQUEST", "merged"): (.gitMerge, Palette.statusPurple)
        case ("PULL_REQUEST", "closed"): (.gitPullRequestClosed, Palette.statusRed)
        case ("PULL_REQUEST", _): (item.isDraft ? .gitPullRequestDraft : .gitPullRequest, item.isDraft ? Palette.textMuted : Palette.statusGreen)
        case ("ISSUE", "closed"): (.circleCheck, Palette.statusPurple)
        case ("ISSUE", _): (.circleDot, Palette.statusGreen)
        default: (.circleDashed, Palette.textMuted)
        }
      content.image = glyph.0.image(size: 18)
      content.imageProperties.tintColor = glyph.1
      cell.accessibilityLabel = item.title
    }
    cell.contentConfiguration = content
  }

  private func url(of row: Row) -> String? {
    switch row {
    case .item(let item): item.url
    case .tracker(let issue): issue.url
    case .todo(let todo): todo.targetUrl
    case .project(let item): item.url
    }
  }
}

extension TasksViewController: UISearchBarDelegate {
  // Typing is a draft; Search sends it, as the official bottom bar does.
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    let text = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    searchBar.resignFirstResponder()
    if isProjectMode {
      // A project search replaces the view's own filter; the view's filter itself clears the override.
      projectQuery = text == projectTable?.filter ? nil : text
      appliedQuery = text
      reload()
      return
    }
    appliedQuery = provider == .github ? preset.scoped(text) : text
    searchBar.text = appliedQuery
    updateChrome()
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
    if isProjectMode {
      guard projectQuery != nil else {
        search.searchBar.text = projectTable?.filter ?? ""
        return
      }
      projectQuery = nil
      reload()
      return
    }
    let cleared = provider == .github ? preset.query : ""
    search.searchBar.text = cleared
    guard appliedQuery != cleared else { return }
    appliedQuery = cleared
    updateChrome()
    reload()
  }
}

extension TasksViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    let group = sections[section]
    guard let title = group.title else { return nil }
    let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "group") ?? UITableViewHeaderFooterView()
    var content = UIListContentConfiguration.prominentInsetGroupedHeader()
    content.text = title
    content.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
    content.secondaryText = group.count.map(String.init)
    content.secondaryTextProperties.color = Palette.textMuted
    content.prefersSideBySideTextAndSecondaryText = true
    if group.collapsible {
      let collapsed = collapsedGroups.contains(group.key)
      content.image = (collapsed ? Lucide.chevronRight : Lucide.chevronDown).image(size: 14)
      content.imageProperties.tintColor = Palette.textMuted
    } else if let color = group.color {
      content.image = UIImage(systemName: "circle.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 8))
      content.imageProperties.tintColor = color
    }
    header.contentConfiguration = content
    header.gestureRecognizers?.forEach { header.removeGestureRecognizer($0) }
    if group.collapsible {
      let key = group.key
      header.addGestureRecognizer(
        UITapGestureRecognizer(target: self, action: #selector(toggleGroup(_:))))
      header.accessibilityIdentifier = key
      header.accessibilityTraits = .button
    }
    return header
  }

  @objc private func toggleGroup(_ gesture: UITapGestureRecognizer) {
    guard let key = gesture.view?.accessibilityIdentifier else { return }
    Haptics.select()
    if collapsedGroups.contains(key) { collapsedGroups.remove(key) } else { collapsedGroups.insert(key) }
    rebuildSections()
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    sections[section].title == nil ? (section == 0 ? Spacing.sm : Spacing.lg) : UITableView.automaticDimension
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    cell.accessoryType = .disclosureIndicator
    configure(cell, sections[indexPath.section].rows[indexPath.row])
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .item(let item):
      // GitLab items have no page here yet; they open on GitLab.
      if provider == .gitlab {
        if let url = URL(string: item.url) { UIApplication.shared.open(url) }
      } else {
        openDetail(item)
      }
    case .tracker(let issue): open(issue)
    case .todo(let todo): if let url = URL(string: todo.targetUrl) { UIApplication.shared.open(url) }
    case .project(let row): open(row)
    }
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    let row = sections[indexPath.section].rows[indexPath.row]
    guard let link = url(of: row), let url = URL(string: link), !link.isEmpty else { return nil }
    let copyTitle: String =
      switch (provider, row) {
      case (.github, _): String(localized: "tasks.itemActions.copyGitHubLink", defaultValue: "Copy GitHub link")
      case (.linear, _): String(localized: "tasks.itemActions.copyLinearLink", defaultValue: "Copy Linear link")
      default: String(localized: "tasks.itemActions.copyLink", defaultValue: "Copy link")
      }
    let openTitle =
      provider == .github
      ? String(localized: "tasks.projectDetailDrawer.openInGitHub", defaultValue: "Open in GitHub")
      : String(localized: "common.open", defaultValue: "Open")
    return UIContextMenuConfiguration(actionProvider: { _ in
      UIMenu(children: [
        UIAction(title: openTitle, image: Lucide.externalLink.image(size: 18)) { _ in UIApplication.shared.open(url) },
        UIAction(title: copyTitle, image: Lucide.copy.image(size: 18)) { _ in UIPasteboard.general.string = link },
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

extension UIViewController {
  fileprivate func alert(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    topPresenter.present(alert, animated: true)
  }
}

/// A reason Tasks words itself, shown as the error's message.
struct TaskMessage: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}
