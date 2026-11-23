import OrcaCore
import UIKit

/// The sources this desktop can search, read once when the form opens (new-workspace-runtime-context.ts).
struct WorkspaceSourceAvailability: Equatable {
  var gitlab = false
  var linear = false
  var jira = false
  var linearWorkspaceId: String?
  var jiraSites: [JiraSite] = []
  var jiraSiteId: String?
}

/// Start from (source-selection/presentation/SmartWorkspaceSourceDrawer.tsx): the name field docked above the
/// keyboard, the search modes above it, and what the typed text finds: a name to use, the project's issues and pull
/// requests, GitLab, Linear or Jira items, its branches. A pasted link finds its item, and one from another project
/// offers to switch to it. Picking a row, Done or Return goes back to the form with the name kept.
final class WorkspaceSourcePickerViewController: UIViewController {
  /// source-selection/mobile-smart-source-modes.ts SMART_MODE_OPTIONS, in its order.
  private enum Mode: CaseIterable {
    case smart, github, linear, jira, gitlab, branches, text

    var title: String {
      switch self {
      case .smart: String(localized: "tasks.smartSourceModes.smart", defaultValue: "Smart")
      case .github: "GitHub"
      case .linear: "Linear"
      case .jira: "Jira"
      case .gitlab: "GitLab"
      case .branches: String(localized: "tasks.smartSourceModes.branch", defaultValue: "Branch")
      case .text: String(localized: "tasks.smartSourceModes.name", defaultValue: "Name")
      }
    }

    var icon: Lucide? {
      switch self {
      case .smart: .sparkles
      case .branches: .gitBranch
      case .text: .caseSensitive
      default: nil
      }
    }

    /// shared/new-workspace/smart-workspace-source-results.ts EMPTY_HINT_BY_MODE, English there too.
    var emptyHint: String {
      switch self {
      case .smart: "Start typing to create a name or find a source."
      case .github: "Start typing to search GitHub PRs and issues."
      case .gitlab: "Start typing to search GitLab MRs and issues."
      case .branches: "No matching branches."
      case .linear: "Start typing to search Linear issues."
      case .jira: "Start typing to search Jira issues, or paste an issue URL."
      case .text: ""
      }
    }

    /// Linear and Jira aren't read through the project, so they work before it is connected.
    var needsRepo: Bool { self != .linear && self != .jira && self != .text }
  }

  /// MR_STATE_FILTER_OPTIONS.
  private static let mrStates: [(id: String, title: String)] = [
    ("opened", String(localized: "tasks.smartSourceModes.openState", defaultValue: "Open")),
    ("merged", String(localized: "tasks.smartSourceModes.mergedState", defaultValue: "Merged")),
    ("closed", String(localized: "tasks.smartSourceModes.closedState", defaultValue: "Closed")),
    ("all", String(localized: "tasks.smartSourceModes.allStates", defaultValue: "All")),
  ]

  private enum Row {
    case useName(String)
    case createBranch(String)
    case github(GitHubWorkItem)
    case gitlab(GitHubWorkItem)
    case branch(BranchRef)
    case linear(TrackerIssue)
    case jira(TrackerIssue)
  }

  /// What one search found (smart-source-fan-out.ts), with the item a pasted link or number names.
  private struct Found {
    var github: [GitHubWorkItem] = []
    var gitlab: [GitHubWorkItem] = []
    var linear: [TrackerIssue] = []
    var jira: [TrackerIssue] = []
    var branches: [BranchRef] = []
    var pastedGitHub: GitHubWorkItem?
    var pastedGitLab: GitHubWorkItem?
    var pastedJira: TrackerIssue?
    /// A pasted link into another project the user has: its slug and that project.
    var crossRepo: (owner: String, repo: String, link: WorkspaceSourceLink, target: Repo)?
    var needsGitHubRemote = false
    var error: String?
  }

  private let session: HostSession
  private let repo: Repo
  private let availability: WorkspaceSourceAvailability
  /// The SSH project is connected (or local), so its sources can be read.
  private let repoReady: Bool
  private let onName: (String) -> Void
  private let onPick: (WorkspaceStart, String?) -> Void
  private let onSwitchRepo: (Repo, GitHubWorkItem) -> Void
  private var mode: Mode
  private var mrState = "opened"
  private var name: String
  private var found = Found()
  private var rows: [Row] = []
  private var loading = false
  /// The pasted text whose switch prompt was dismissed; it isn't offered again.
  private var dismissedPaste = ""
  private var searchTask: Task<Void, Never>?
  /// Each project's GitHub slug, read once (`github.repoSlug`) to match pasted links.
  private var slugs: [String: GitHubOwnerRepo?] = [:]

  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let modeBar = UIStackView()
  private let mrBar = UISegmentedControl()
  private let field = UITextField()
  private let notice = UILabel()
  private let crossRepoBox = UIStackView()

  init(
    session: HostSession, repo: Repo, name: String, availability: WorkspaceSourceAvailability, repoReady: Bool,
    onName: @escaping (String) -> Void, onPick: @escaping (WorkspaceStart, String?) -> Void,
    onSwitchRepo: @escaping (Repo, GitHubWorkItem) -> Void
  ) {
    self.session = session
    self.repo = repo
    self.name = name
    self.availability = availability
    self.repoReady = repoReady
    self.onName = onName
    self.onPick = onPick
    self.onSwitchRepo = onSwitchRepo
    // A folder only takes a name.
    mode = repo.isFolder ? .text : .smart
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// resolveAvailableSmartModes.
  private var availableModes: [Mode] {
    if repo.isFolder { return [.text] }
    return Mode.allCases.filter { mode in
      switch mode {
      case .gitlab: availability.gitlab
      case .linear: availability.linear
      case .jira: availability.jira
      default: true
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    title =
      repo.isFolder
      ? String(localized: "components.smartWorkspaceSourceDrawer.workspaceName", defaultValue: "Workspace name")
      : String(localized: "components.smartWorkspaceSourceDrawer.startFrom", defaultValue: "Start from")
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: String(localized: "common.done", defaultValue: "Done"), style: .done, target: nil, action: nil)
    navigationItem.rightBarButtonItem?.primaryAction = UIAction(
      title: String(localized: "common.done", defaultValue: "Done")
    ) { [weak self] _ in self?.close() }

    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .none
    table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    table.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(table)

    notice.font = .systemFont(ofSize: 13)
    notice.numberOfLines = 0
    notice.isHidden = true
    buildCrossRepoBox()
    let top = UIStackView(arrangedSubviews: [crossRepoBox, notice])
    top.axis = .vertical
    top.spacing = Spacing.sm
    top.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(top)

    for (index, state) in Self.mrStates.enumerated() {
      mrBar.insertSegment(withTitle: state.title, at: index, animated: false)
    }
    mrBar.selectedSegmentIndex = 0
    mrBar.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.mrState = Self.mrStates[self.mrBar.selectedSegmentIndex].id
        self.search()
      }, for: .valueChanged)

    modeBar.axis = .horizontal
    modeBar.spacing = Spacing.xs
    let modeScroll = UIScrollView()
    modeScroll.showsHorizontalScrollIndicator = false
    modeScroll.translatesAutoresizingMaskIntoConstraints = false
    modeBar.translatesAutoresizingMaskIntoConstraints = false
    modeScroll.addSubview(modeBar)
    modeScroll.isHidden = availableModes.count < 2
    rebuildModeBar()

    field.text = name
    field.placeholder = String(
      localized: "components.smartWorkspaceSourceDrawer.searchPlaceholder", defaultValue: "Type a name or search a source")
    field.font = .systemFont(ofSize: 16)
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.returnKeyType = .done
    field.clearButtonMode = .whileEditing
    field.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.name = self.field.text ?? ""
        self.onName(self.name)
        self.search()
      }, for: .editingChanged)
    field.addAction(UIAction { [weak self] _ in self?.close() }, for: .editingDidEndOnExit)
    let box = UIView()
    box.layer.cornerRadius = Radius.control
    box.layer.cornerCurve = .continuous
    box.layer.borderWidth = 1
    box.layer.borderColor = Palette.accentBlue.resolvedColor(with: traitCollection).cgColor
    field.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(field)

    let dock = UIStackView(arrangedSubviews: [mrBar, modeScroll, box])
    dock.axis = .vertical
    dock.spacing = Spacing.sm
    dock.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(dock)
    NSLayoutConstraint.activate([
      top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
      top.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      top.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      table.topAnchor.constraint(equalTo: top.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -Spacing.sm),
      dock.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      dock.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm),
      modeScroll.heightAnchor.constraint(equalToConstant: 34),
      modeBar.leadingAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.leadingAnchor),
      modeBar.trailingAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.trailingAnchor),
      modeBar.topAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.topAnchor),
      modeBar.bottomAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.bottomAnchor),
      modeBar.heightAnchor.constraint(equalTo: modeScroll.frameLayoutGuide.heightAnchor),
      box.heightAnchor.constraint(equalToConstant: 44),
      field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Spacing.md),
      field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Spacing.sm),
      field.topAnchor.constraint(equalTo: box.topAnchor),
      field.bottomAnchor.constraint(equalTo: box.bottomAnchor),
    ])
    search()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  private func close() {
    navigationController?.popViewController(animated: true)
  }

  // MARK: Chrome

  /// The modes as bordered tabs, the picked one filled (SmartSourceModeIcon + label).
  private func rebuildModeBar() {
    modeBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for option in availableModes {
      var configuration: UIButton.Configuration = option == mode ? .prominentGlass() : .glass()
      configuration.title = option.title
      configuration.image = option.icon?.image(size: 14)
      configuration.imagePadding = 4
      configuration.buttonSize = .small
      configuration.baseBackgroundColor = option == mode ? Palette.textPrimary : nil
      configuration.baseForegroundColor = option == mode ? Palette.bgBase : Palette.textSecondary
      let button = UIButton(configuration: configuration)
      button.accessibilityTraits = option == mode ? [.button, .selected] : .button
      button.addAction(
        UIAction { [weak self] _ in
          guard let self, self.mode != option else { return }
          Haptics.select()
          self.mode = option
          self.found = Found()
          self.rebuildModeBar()
          self.search()
        }, for: .primaryActionTriggered)
      modeBar.addArrangedSubview(button)
    }
    mrBar.isHidden = mode != .gitlab
  }

  /// "This item lives in owner/repo." with Cancel and Switch to that project.
  private func buildCrossRepoBox() {
    crossRepoBox.axis = .vertical
    crossRepoBox.spacing = Spacing.xs
    crossRepoBox.isLayoutMarginsRelativeArrangement = true
    crossRepoBox.directionalLayoutMargins = .init(top: Spacing.md, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md)
    crossRepoBox.backgroundColor = Palette.sheetSurface
    crossRepoBox.layer.cornerRadius = Radius.control
    crossRepoBox.layer.cornerCurve = .continuous
    crossRepoBox.isHidden = true
  }

  private func updateCrossRepoBox() {
    crossRepoBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard let prompt = found.crossRepo else {
      crossRepoBox.isHidden = true
      return
    }
    crossRepoBox.isHidden = false
    let label = UILabel()
    label.font = .systemFont(ofSize: 14)
    label.textColor = Palette.textPrimary
    label.numberOfLines = 0
    label.text = String(
      format: String(
        localized: "components.smartWorkspaceSourceDrawer.crossRepoMessage",
        defaultValue: "This item lives in %1$@/%2$@."), prompt.owner, prompt.repo)
    var cancel = UIButton.Configuration.plain()
    cancel.title = String(localized: "common.cancel", defaultValue: "Cancel")
    cancel.baseForegroundColor = Palette.textSecondary
    var switchTo = UIButton.Configuration.plain()
    switchTo.title = String(
      format: String(localized: "components.smartWorkspaceSourceDrawer.switchRepo", defaultValue: "Switch to %1$@"),
      prompt.target.displayName)
    switchTo.baseForegroundColor = Palette.accentBlue
    let cancelButton = UIButton(
      configuration: cancel,
      primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        self.dismissedPaste = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.found.crossRepo = nil
        self.updateCrossRepoBox()
      })
    let switchButton = UIButton(
      configuration: switchTo, primaryAction: UIAction { [weak self] _ in self?.acceptCrossRepo() })
    let actions = UIStackView(arrangedSubviews: [UIView(), cancelButton, switchButton])
    actions.spacing = Spacing.sm
    crossRepoBox.addArrangedSubview(label)
    crossRepoBox.addArrangedSubview(actions)
  }

  /// Reads the pasted item through the project it lives in, switches the form to it and picks it.
  private func acceptCrossRepo() {
    guard let prompt = found.crossRepo,
      case .github(let owner, let repoName, let host, let number, let isPR) = prompt.link
    else { return }
    let api = session.api
    let target = prompt.target
    Task {
      do {
        guard
          let item = try await api.githubWorkItem(
            repoId: target.id, repoName: target.displayName, owner: owner, ownerRepo: repoName, host: host,
            number: number, isPR: isPR)
        else { throw CancellationError() }
        onSwitchRepo(target, item)
        close()
      } catch {
        dismissedPaste = name.trimmingCharacters(in: .whitespacesAndNewlines)
        found.crossRepo = nil
        updateCrossRepoBox()
      }
    }
  }

  // MARK: Search

  /// What the typed text finds in this mode (use-smart-workspace-source.ts); a typed burst reads once, 200 ms
  /// after it stops.
  private func search() {
    searchTask?.cancel()
    let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let mode = mode
    guard mode != .text, name.utf8.count <= WorkspaceSourceLink.maxQueryBytes else {
      found = Found()
      loading = false
      rebuild()
      return
    }
    loading = true
    rebuild()
    let api = session.api
    let repo = repo
    let availability = availability
    let repoReady = repoReady
    let mrState = mrState
    let dismissed = dismissedPaste
    let repos = otherProjects
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled, let self else { return }
      let next = await self.run(
        api: api, mode: mode, query: query, repo: repo, availability: availability, repoReady: repoReady,
        mrState: mrState, dismissed: dismissed, repos: repos)
      guard !Task.isCancelled else { return }
      self.found = next
      self.loading = false
      self.updateCrossRepoBox()
      self.rebuild()
    }
  }

  /// Projects a pasted GitHub link may belong to: the git ones on this host, one row per id.
  private var otherProjects: [Repo] {
    var seen = Set<String>()
    return session.repos.filter { !$0.isFolder && seen.insert($0.id).inserted }
  }

  private func run(
    api: HostAPI, mode: Mode, query: String, repo: Repo, availability: WorkspaceSourceAvailability, repoReady: Bool,
    mrState: String, dismissed: String, repos: [Repo]
  ) async -> Found {
    var next = Found()
    // A pasted Jira link resolves to its one issue; nothing else is searched.
    if availability.jira, mode == .smart || mode == .jira, let link = WorkspaceSourceLink.Jira(query) {
      for site in availability.jiraSites where link.matches(siteUrl: site.siteUrl) {
        if let issue = try? await api.jiraIssue(key: link.issueKey, siteId: site.id),
          issue.identifier.uppercased() == link.issueKey
        {
          next.pastedJira = issue
          break
        }
      }
      return next
    }
    let isSmart = mode == .smart
    let canReadRepo = repoReady
    func fail(_ error: Error) {
      if !isSmart { next.error = TasksViewController.message(error) }
    }
    async let github: Result<[GitHubWorkItem], Error>? =
      (mode == .smart || mode == .github) && canReadRepo
      ? await Result { try await api.searchWorkItems(repoId: repo.id, repoName: repo.displayName, query: query) } : nil
    async let gitlab: Result<[GitHubWorkItem], Error>? =
      availability.gitlab && (mode == .smart || mode == .gitlab) && canReadRepo
      ? await Result {
        try await api.searchGitLabItems(repoId: repo.id, repoName: repo.displayName, query: query, state: mrState)
      } : nil
    async let linear: Result<[TrackerIssue], Error>? =
      availability.linear && (mode == .smart || mode == .linear)
      ? await Result { try await api.searchLinearSource(query: query, workspaceId: availability.linearWorkspaceId) }
      : nil
    async let jira: Result<[TrackerIssue], Error>? =
      availability.jira && mode == .jira && !query.isEmpty
      ? await Result { try await api.searchJira(query, siteId: availability.jiraSiteId).issues } : nil
    async let branches: Result<[BranchRef], Error>? =
      (mode == .branches || (mode == .smart && !query.isEmpty)) && canReadRepo
      ? await Result { try await api.searchBranches(repoId: repo.id, query: query) } : nil
    async let pasted = mode == .branches || dismissed == query || !canReadRepo
      ? Found() : await lookUpPaste(api: api, query: query, repo: repo, repos: repos)
    let (githubReply, gitlabReply, linearReply, jiraReply, branchReply, paste) = await (
      github, gitlab, linear, jira, branches, pasted
    )
    switch githubReply {
    case .success(let items): next.github = items
    case .failure(let error):
      // An SSH project without a GitHub remote can't list issues; that is said, not shown as an error.
      if TasksViewController.message(error).localizedCaseInsensitiveContains("GitHub remote") {
        next.needsGitHubRemote = true
      } else {
        fail(error)
      }
    case nil: break
    }
    switch gitlabReply {
    case .success(let items): next.gitlab = items
    case .failure(let error): fail(error)
    case nil: break
    }
    switch linearReply {
    case .success(let issues): next.linear = issues
    case .failure(let error): fail(error)
    case nil: break
    }
    switch jiraReply {
    case .success(let issues): next.jira = issues
    case .failure(let error): fail(error)
    case nil: break
    }
    switch branchReply {
    case .success(let refs): next.branches = refs
    case .failure(let error): fail(error)
    case nil: break
    }
    next.pastedGitHub = paste.pastedGitHub
    next.pastedGitLab = paste.pastedGitLab
    next.crossRepo = paste.crossRepo
    return next
  }

  /// A pasted number or link's item (smart-source-paste-intent.ts): a GitHub link into another project offers to
  /// switch rather than reading it here.
  private func lookUpPaste(api: HostAPI, query: String, repo: Repo, repos: [Repo]) async -> Found {
    var found = Found()
    switch WorkspaceSourceLink.parse(query) {
    case .githubNumber(let number):
      found.pastedGitHub = try? await api.githubWorkItem(repoId: repo.id, repoName: repo.displayName, number: number)
    case .github(let owner, let ownerRepo, let host, let number, let isPR):
      if let match = await project(owner: owner, repo: ownerRepo, among: repos, api: api), match.id != repo.id {
        found.crossRepo = (owner, ownerRepo, .github(owner: owner, repo: ownerRepo, host: host, number: number, isPR: isPR), match)
        return found
      }
      found.pastedGitHub = try? await api.githubWorkItem(
        repoId: repo.id, repoName: repo.displayName, owner: owner, ownerRepo: ownerRepo, host: host, number: number,
        isPR: isPR)
    case .gitlab(let host, let path, let iid, let isMR):
      found.pastedGitLab = try? await api.gitlabWorkItem(
        repoId: repo.id, repoName: repo.displayName, host: host, path: path, iid: iid, isMR: isMR)
    case nil: break
    }
    return found
  }

  /// The project a GitHub slug points at: its remote's key when the list carries one, else `github.repoSlug`.
  private func project(owner: String, repo: String, among repos: [Repo], api: HostAPI) async -> Repo? {
    let wanted = "\(owner)/\(repo)".lowercased()
    func matches(_ slug: String) -> Bool {
      var text = slug.lowercased()
      if text.hasSuffix(".git") { text.removeLast(4) }
      return text == wanted || text.hasSuffix("/\(wanted)")
    }
    if let projected = repos.first(where: { $0.projectKey.hasPrefix("remote:") && matches($0.projectKey) }) {
      return projected
    }
    for candidate in repos {
      if slugs[candidate.id] == nil {
        slugs[candidate.id] = .some((try? await api.githubRepoSlug(repoId: candidate.id)) ?? nil)
      }
      if let slug = slugs[candidate.id] ?? nil, matches(slug.slug) { return candidate }
    }
    return nil
  }

  /// buildSmartWorkspaceSourceRows, as the phone builds them.
  private func rebuild() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var next: [Row] = []
    if availability.jira, mode == .smart || mode == .jira, WorkspaceSourceLink.Jira(trimmed) != nil {
      next = found.pastedJira.map { [.jira($0)] } ?? []
    } else if name.utf8.count <= WorkspaceSourceLink.maxQueryBytes {
      if !trimmed.isEmpty, mode == .smart { next.append(.useName(trimmed)) }
      if mode != .text {
        if mode == .smart || mode == .github {
          next += (found.pastedGitHub.map { [$0] } ?? found.github).map(Row.github)
        }
        if availability.gitlab, mode == .smart || mode == .gitlab {
          next += (found.pastedGitLab.map { [$0] } ?? found.gitlab).map(Row.gitlab)
        }
        if mode == .branches || (mode == .smart && !trimmed.isEmpty) {
          let exact = found.branches.contains { $0.label == trimmed || $0.localBranchName == trimmed }
          if !trimmed.isEmpty, mode == .branches, !exact { next.append(.createBranch(trimmed)) }
          next += found.branches.map(Row.branch)
        }
        if availability.linear, mode == .smart || mode == .linear { next += found.linear.map(Row.linear) }
        if mode == .jira { next += found.jira.map(Row.jira) }
      }
    }
    rows = Array(next.prefix(37))
    table.reloadData()
    updateNotice()
    updateFooter()
  }

  private func updateNotice() {
    let text: String?
    if !repoReady, mode.needsRepo {
      text = String(
        localized: "components.smartWorkspaceSourceDrawer.connectRepository",
        defaultValue: "Connect the repository to search sources.")
    } else if found.needsGitHubRemote {
      text = String(
        localized: "components.smartWorkspaceSourceDrawer.gitHubRemoteRequired",
        defaultValue: "This SSH repo needs a GitHub remote to list issues and PRs.")
    } else {
      text = found.error
    }
    notice.text = text
    notice.textColor = found.error != nil && text == found.error ? Palette.statusRed : Palette.textSecondary
    notice.isHidden = text == nil
  }

  private func updateFooter() {
    let text: String?
    if loading || !notice.isHidden {
      text = nil
    } else if mode == .text, rows.isEmpty {
      text = String(
        localized: "components.smartWorkspaceSourceDrawer.typeWorkspaceName",
        defaultValue: "Type a workspace name in the field below.")
    } else if rows.isEmpty {
      text =
        mode.emptyHint.isEmpty || !name.trimmingCharacters(in: .whitespaces).isEmpty
        ? String(localized: "components.smartWorkspaceSourceDrawer.noResults", defaultValue: "No results found.")
        : mode.emptyHint
    } else {
      text = nil
    }
    let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: loading || text != nil ? 64 : 0))
    if loading && rows.isEmpty {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      spinner.translatesAutoresizingMaskIntoConstraints = false
      footer.addSubview(spinner)
      spinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor).isActive = true
      spinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor).isActive = true
    } else if let text {
      let label = UILabel()
      label.text = text
      label.font = .systemFont(ofSize: 14)
      label.textColor = Palette.textSecondary
      label.textAlignment = .center
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
      footer.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Spacing.xl),
        label.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Spacing.xl),
        label.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
      ])
    }
    table.tableFooterView = footer
  }

  private func pick(_ row: Row) {
    switch row {
    case .useName(let text): onPick(.name, text)
    case .createBranch(let branch): onPick(.newBranch(branch), branch)
    case .github(let item):
      onPick(.workItem(item), WorkspaceSourceName.hosted(title: item.title, number: item.number, kind: item.kind.rawValue).seed)
    case .gitlab(let item):
      onPick(
        .gitlab(item),
        WorkspaceSourceName.hosted(title: item.title, number: item.number, kind: item.kind == .pr ? "mr" : "issue").seed)
    case .branch(let ref): onPick(.branch(ref), ref.localBranchName)
    case .linear(let issue):
      onPick(.linear(issue), WorkspaceSourceName.identified(identifier: issue.identifier, title: issue.title).seed)
    case .jira(let issue):
      onPick(.jira(issue), WorkspaceSourceName.identified(identifier: issue.identifier, title: issue.title).seed)
    }
    close()
  }
}

extension WorkspaceSourcePickerViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.secondaryTextProperties.color = Palette.textSecondary
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    content.imageProperties.tintColor = Palette.textSecondary
    cell.accessoryView = nil
    // SmartWorkspaceSourceRow.tsx: each kind's glyph, title and second line.
    switch rows[indexPath.row] {
    case .useName(let text):
      content.image = Lucide.sparkles.image(size: 18)
      content.text = String(
        format: String(localized: "components.smartWorkspaceSourceRow.useName", defaultValue: "Use \"%@\""), text)
      content.secondaryText = String(
        localized: "components.smartWorkspaceSourceRow.nameWorkspace", defaultValue: "Name this workspace")
    case .createBranch(let branch):
      content.image = Lucide.gitBranch.image(size: 18)
      content.imageProperties.tintColor = Palette.accentBlue
      content.text = String(
        format: String(localized: "components.smartWorkspaceSourceRow.createBranch", defaultValue: "Create branch \"%@\""),
        branch)
      content.secondaryText = String(localized: "components.smartWorkspaceSourceRow.newBranch", defaultValue: "New branch")
    case .github(let item):
      content.image = (item.kind == .pr ? Lucide.gitPullRequest : Lucide.circleDot).image(size: 18)
      content.text = item.title
      content.secondaryText =
        item.kind == .pr
        ? String(
          format: String(localized: "components.smartWorkspaceSourceRow.pullRequest", defaultValue: "PR #%@"),
          "\(item.number)")
        : String(
          format: String(localized: "components.smartWorkspaceSourceRow.issue", defaultValue: "Issue #%@"),
          "\(item.number)")
      cell.accessoryView = Self.pill(item.state)
    case .gitlab(let item):
      content.image = (item.kind == .pr ? Lucide.gitMerge : Lucide.circleDot).image(size: 18)
      content.text = item.title
      content.secondaryText =
        item.kind == .pr
        ? String(
          format: String(localized: "components.smartWorkspaceSourceRow.mergeRequest", defaultValue: "MR !%1$@"),
          "\(item.number)")
        : String(
          format: String(localized: "components.smartWorkspaceSourceRow.issue", defaultValue: "Issue #%@"),
          "\(item.number)")
      cell.accessoryView = Self.pill(item.state)
    case .branch(let ref):
      content.image = Lucide.gitBranch.image(size: 18)
      content.text = ref.label
      content.secondaryText = ref.localBranchName != ref.label ? ref.localBranchName : nil
    case .linear(let issue):
      content.image = Lucide.listTodo.image(size: 18)
      content.text = issue.title
      content.secondaryText = "\(issue.identifier) · \(issue.group ?? "Linear")"
      cell.accessoryView = issue.state.map(Self.pill)
    case .jira(let issue):
      content.image = Lucide.listChecks.image(size: 18)
      content.text = issue.title
      content.secondaryText = "\(issue.identifier) · \(issue.group ?? "Jira")"
      cell.accessoryView = issue.state.map(Self.pill)
    }
    content.textProperties.numberOfLines = 1
    cell.contentConfiguration = content
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    pick(rows[indexPath.row])
  }

  /// The state, capitalised in a small pill, at most 120 pt wide.
  private static func pill(_ state: String) -> UIView {
    let label = StatePillLabel()
    label.text = state.capitalized
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = Palette.textSecondary
    label.backgroundColor = Palette.sheetSurface
    label.layer.cornerRadius = 9
    label.layer.masksToBounds = true
    label.lineBreakMode = .byTruncatingTail
    label.sizeToFit()
    label.frame.size.width = min(label.frame.width, 120)
    return label
  }
}

/// A label with the pill's 8 pt sides and 2 pt top and bottom.
private final class StatePillLabel: UILabel {
  private let insets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }
}
