import OrcaCore
import UIKit

/// Source Control for one workspace (source-control/MobileSourceControlPanel.tsx): Changes and Pull request
/// under the title. Changes holds the branch line (tap to switch branch) with how it stands against its
/// upstream, a paused merge or rebase, the branch's commits, the changed files under Conflicts, Uncommitted
/// and Staged. Pull request holds the branch's PR, its gates toward merge and its description. At the foot sits
/// the one next step: the commit box, push or pull, Create PR, Fix or Resolve with an agent, or Merge. The ⋯
/// menu holds the rarer git actions, then Refresh, then Force Push; on the PR segment, the PR's own actions.
final class SourceControlViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
  private enum Tab: Int { case changes, pr }

  private struct FileSection {
    let id: String
    let title: String
    let entries: [GitStatusEntry]
  }

  /// The commit area's decision (source-control-primary-action-decision.ts), for the bar and its label.
  private enum Primary: Equatable {
    case commit(enabled: Bool), stageAll, push(Int), pull(Int), sync, publish, forcePush, none
  }

  private let session: HostSession
  private let worktreeId: String
  private var status: GitStatus?
  private var sections: [FileSection] = []
  private var loadError: String?
  /// The git action running now ("commit", "push", a row's path …); one at a time, as the official screen.
  private var busyAction: String?
  /// A failed action, shown over the bar until the next one.
  private var notice: String?
  private var commitMessage = ""
  private var hubTab = Tab.changes
  private var loadTask: Task<Void, Never>?
  private var foregroundObserver: NSObjectProtocol?
  private lazy var prController = PullRequestController(session: session, worktreeId: worktreeId)
  private var prObservation: PRObservation?
  private var expandedDescription = false
  /// The base PRs and rebases target, and the branch's commits over it: the commits row and the PR tab's empty state.
  private var baseRef: String?
  private var commitsAhead: Int?
  private var compareTask: Task<Void, Never>?
  private var generatingMessage = false
  private weak var commitsPage: CommitsViewController?

  private let segments = UISegmentedControl()
  private let table = UITableView(frame: .zero, style: .plain)
  private let header = ChangesHeaderView()
  private let cleanState = UIStackView()
  private let prView = UIScrollView()
  private let prStack = UIStackView()
  private let bar = NextStepBar()
  private let stateView = UIView()

  init(session: HostSession, worktreeId: String) {
    self.session = session
    self.worktreeId = worktreeId
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    loadTask?.cancel()
    if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
  }

  private var api: HostAPI { session.api }
  private var busy: Bool { busyAction != nil }
  private var worktree: Worktree? { session.worktree(id: worktreeId) }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    title = String(localized: "sourceControl.header.title", defaultValue: "Source Control")
    navigationItem.subtitle = worktree?.displayName
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: Lucide.ellipsis.image(size: 20),
      menu: UIMenu(children: [
        UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.actionsMenu() ?? []) }
      ]))
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "sourceControl.header.moreActions", defaultValue: "More source control actions")

    // Changes / Pull request, under the title like the official NavBar accessory.
    segments.insertSegment(withTitle: String(localized: "sourceControl.hubTab.changes", defaultValue: "Changes"), at: 0, animated: false)
    segments.insertSegment(
      withTitle: String(localized: "sourceControl.hubTab.pullRequest", defaultValue: "Pull request"), at: 1, animated: false)
    segments.selectedSegmentIndex = 0
    segments.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        Haptics.select()
        self.hubTab = Tab(rawValue: self.segments.selectedSegmentIndex) ?? .changes
        self.rebuild()
      }, for: .valueChanged)
    let accessory = UIView()
    accessory.backgroundColor = Palette.bgBase
    segments.translatesAutoresizingMaskIntoConstraints = false
    accessory.addSubview(segments)
    let border = Hairline()
    accessory.addSubview(border)
    NSLayoutConstraint.activate([
      segments.topAnchor.constraint(equalTo: accessory.topAnchor, constant: Spacing.sm),
      segments.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: Spacing.md),
      segments.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -Spacing.md),
      segments.bottomAnchor.constraint(equalTo: border.topAnchor, constant: -Spacing.sm),
      border.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
      border.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
      border.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
    ])

    table.backgroundColor = Palette.bgBase
    table.separatorStyle = .none
    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .interactive
    table.sectionHeaderTopPadding = 0
    table.register(GitFileCell.self, forCellReuseIdentifier: GitFileCell.reuseIdentifier)
    table.register(FileSectionHeader.self, forHeaderFooterViewReuseIdentifier: FileSectionHeader.reuseIdentifier)
    let refresh = UIRefreshControl()
    refresh.addAction(UIAction { [weak self] _ in self?.reload(refresh: true) }, for: .valueChanged)
    table.refreshControl = refresh
    let prRefresh = UIRefreshControl()
    prRefresh.addAction(UIAction { [weak self] _ in self?.reload(refresh: true) }, for: .valueChanged)
    prView.refreshControl = prRefresh
    header.branchButton.showsMenuAsPrimaryAction = true
    header.branchButton.menu = UIMenu(children: [
      UIDeferredMenuElement { [weak self] completion in
        guard let self else { return completion([]) }
        self.branchMenu(completion)
      }
    ])
    header.onAbort = { [weak self] operation in self?.abort(operation) }
    header.onOpenCommits = { [weak self] in self?.openCommits() }
    prObservation = prController.observe { [weak self] in self?.prChanged() }

    // Clean: the branch line stays on top, and the clean state sits in the middle of what's left.
    let cleanTitle = TextLabel(
      String(localized: "sourceControl.content.emptyTitle", defaultValue: "No local changes"), size: 16, weight: .bold,
      alignment: .center)
    let cleanText = TextLabel(
      String(localized: "sourceControl.content.emptyMessage", defaultValue: "Working tree is clean."),
      size: Typography.bodySize, color: Palette.textSecondary, lineHeight: 20, alignment: .center, lines: 0)
    cleanState.addArrangedSubview(cleanTitle)
    cleanState.addArrangedSubview(cleanText)
    cleanState.axis = .vertical
    cleanState.alignment = .center
    cleanState.spacing = Spacing.xs
    cleanState.isUserInteractionEnabled = false
    cleanState.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cleanState)

    prView.alwaysBounceVertical = true
    prStack.axis = .vertical
    prStack.spacing = Spacing.md
    prStack.translatesAutoresizingMaskIntoConstraints = false
    prView.addSubview(prStack)
    NSLayoutConstraint.activate([
      prStack.topAnchor.constraint(equalTo: prView.contentLayoutGuide.topAnchor, constant: Spacing.lg),
      prStack.leadingAnchor.constraint(equalTo: prView.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      prStack.trailingAnchor.constraint(equalTo: prView.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      prStack.bottomAnchor.constraint(equalTo: prView.contentLayoutGuide.bottomAnchor, constant: -Spacing.lg),
    ])

    stateView.isHidden = true
    for part in [accessory, table, prView, stateView, bar] as [UIView] {
      part.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(part)
    }
    view.bringSubviewToFront(cleanState)
    view.bringSubviewToFront(bar)
    NSLayoutConstraint.activate([
      accessory.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      accessory.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      accessory.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.topAnchor.constraint(equalTo: accessory.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      prView.topAnchor.constraint(equalTo: accessory.bottomAnchor),
      prView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      prView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      prView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.topAnchor.constraint(equalTo: accessory.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      cleanState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cleanState.centerYAnchor.constraint(equalTo: table.centerYAnchor),
      cleanState.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Spacing.xl),
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // The bar rides the keyboard for its commit box.
      bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])
    view.keyboardLayoutGuide.usesBottomSafeArea = false
    bar.messageView.delegate = self

    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
    rebuild()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // A pushed diff shows its own toolbar; this screen has its bar instead.
    navigationController?.setToolbarHidden(true, animated: animated)
    reload()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    sizeHeader()
    // The list and the PR body scroll clear of the bar floating over them.
    let inset = bar.isHidden ? view.safeAreaInsets.bottom : bar.frame.height
    for scroll in [table, prView] as [UIScrollView] where scroll.contentInset.bottom != inset + Spacing.lg {
      scroll.contentInset.bottom = inset + Spacing.lg
      scroll.verticalScrollIndicatorInsets.bottom = inset
    }
  }

  private func sizeHeader() {
    let width = table.bounds.width
    guard width > 0 else { return }
    let size = header.systemLayoutSizeFitting(
      CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    if table.tableHeaderView !== header || header.frame.size != CGSize(width: width, height: size.height) {
      header.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
      table.tableHeaderView = header
    }
  }

  // MARK: Loading

  /// Reads status, then the branch's PR and how far it is past its base. `refresh` asks the host past its caches.
  private func reload(refresh: Bool = false) {
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let status = try await api.gitStatus(worktreeId: worktreeId)
        guard !Task.isCancelled else { return }
        let pushed = (self.status?.upstream?.ahead ?? 0) > 0 && status.upstream?.ahead == 0
        let moved = self.status?.head != status.head || self.status?.branch != status.branch
        self.status = status
        loadError = nil
        // A push moves the PR's checks to the pushed head, so the PR is read again then too.
        if refresh || moved || pushed || prController.state == .idle {
          prController.load(branch: status.branch, headSha: status.head, gitStatus: status, refresh: refresh)
        }
        if refresh || moved || pushed || baseRef == nil { readBranchCompare() }
        commitsPage?.reload()
      } catch {
        guard !Task.isCancelled else { return }
        loadError = Self.message(error)
      }
      table.refreshControl?.endRefreshing()
      prView.refreshControl?.endRefreshing()
      rebuild()
    }
  }

  /// The effective base and the branch's commits over it (`git.branchCompare`).
  private func readBranchCompare() {
    compareTask?.cancel()
    let api = api
    let worktreeId = worktreeId
    let repoId = worktree?.repoId ?? ""
    compareTask = Task { [weak self] in
      let base = await api.effectiveBaseRef(worktreeId: worktreeId, repoId: repoId)
      var summary: GitBranchCompareSummary?
      if let base { summary = try? await api.gitBranchCompare(worktreeId: worktreeId, baseRef: base) }
      guard !Task.isCancelled, let self else { return }
      baseRef = base
      commitsAhead = summary?.status == "ready" ? summary?.commitsAhead : nil
      rebuild()
    }
  }

  private static func message(_ error: Error) -> String {
    (error as? RPCError)?.message ?? error.localizedDescription
  }

  private func rebuild() {
    sections = []
    if let status {
      let conflicts = status.entries.filter(\.isConflict).sorted { $0.path < $1.path }
      let rest = status.entries.filter { !$0.isConflict }
      let uncommitted = rest.filter { $0.area != .staged }.sorted { $0.path < $1.path }
      let staged = rest.filter { $0.area == .staged }.sorted { $0.path < $1.path }
      let merging = status.conflictOperation == "merge"
      if !conflicts.isEmpty {
        sections.append(
          FileSection(
            id: "conflicts", title: String(localized: "sourceControl.gitStatus.conflicts", defaultValue: "Conflicts"),
            entries: conflicts))
      }
      if !uncommitted.isEmpty {
        sections.append(
          FileSection(
            id: "unstaged", title: String(localized: "sourceControl.gitStatus.uncommitted", defaultValue: "Uncommitted"),
            entries: uncommitted))
      }
      if !staged.isEmpty {
        sections.append(
          FileSection(
            id: "staged",
            title: merging
              ? String(localized: "sourceControl.fileList.mergedCleanly", defaultValue: "Merged cleanly")
              : String(localized: "sourceControl.gitStatus.staged", defaultValue: "Staged"),
            entries: staged))
      }
    }
    let ready = status != nil
    header.show(
      branch: status?.branch ?? String(localized: "sourceControl.remoteDropdown.statusNoBranch", defaultValue: "No branch"),
      meta: syncMeta, operation: operation, unresolved: entries.filter { $0.conflictStatus == "unresolved" }.count,
      busy: busy, aborting: busyAction == "abort", readError: status?.readError)
    header.show(commits: commitsAhead ?? 0)
    header.isHidden = !ready
    table.reloadData()
    sizeHeader()
    table.isHidden = hubTab != .changes || !ready
    cleanState.isHidden = hubTab != .changes || !ready || !sections.isEmpty
    prView.isHidden = hubTab != .pr || !ready
    if hubTab == .pr { buildPullRequest() }
    showGate()
    updateBar()
    // The Commits page's Push and Update branch follow what runs here.
    commitsPage?.tableView.reloadData()
    navigationItem.rightBarButtonItem?.isEnabled = ready
  }

  /// Loading, or why status can't be read, in place of both tabs.
  private func showGate() {
    stateView.subviews.forEach { $0.removeFromSuperview() }
    guard status == nil else {
      stateView.isHidden = true
      return
    }
    stateView.isHidden = false
    var config: UIContentUnavailableConfiguration
    if let loadError {
      config = .empty()
      config.image = Lucide.gitBranch.image(size: 32)
      config.text = String(localized: "sourceControl.panel.unavailableTitle", defaultValue: "Source Control Unavailable")
      config.secondaryText = loadError
      var retry = UIButton.Configuration.gray()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config.button = retry
      config.buttonProperties.primaryAction = UIAction { [weak self] _ in
        self?.loadError = nil
        self?.rebuild()
        self?.reload()
      }
    } else {
      config = .loading()
      config.text = String(localized: "sourceControl.panel.loading", defaultValue: "Loading changes…")
    }
    let content = UIContentUnavailableView(configuration: config)
    content.translatesAutoresizingMaskIntoConstraints = false
    stateView.addSubview(content)
    content.pin(to: stateView)
  }

  // MARK: Facts

  private var entries: [GitStatusEntry] { status?.entries ?? [] }
  private var stagedCount: Int { entries.filter { $0.area == .staged }.count }
  private var stageablePaths: [String] { entries.filter(\.canStage).map(\.path) }
  private var unstageablePaths: [String] { entries.filter(\.canUnstage).map(\.path) }
  private var hasUnresolvedConflicts: Bool { entries.contains { $0.conflictStatus == "unresolved" } }
  private var hasMessage: Bool { !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var hasBranch: Bool { status?.branch != nil }
  private var published: Bool { status?.upstream?.hasUpstream == true }
  private var operation: String? {
    let operation = status?.conflictOperation
    return operation == "unknown" ? nil : operation
  }

  /// Desktop's commit-area decision, the local half; `nextStep` layers the review's steps on it.
  private var primary: Primary {
    guard let status else { return .none }
    if hasUnresolvedConflicts { return .commit(enabled: false) }
    if stagedCount > 0 { return .commit(enabled: hasMessage) }
    if !stageablePaths.isEmpty { return .stageAll }
    guard let upstream = status.upstream else { return .none }
    guard upstream.hasUpstream else { return hasBranch ? .publish : .none }
    if upstream.ahead > 0, upstream.behind > 0 { return .sync }
    if upstream.ahead > 0 { return .push(upstream.ahead) }
    if upstream.behind > 0 { return .pull(upstream.behind) }
    return .none
  }

  private var syncMeta: String? {
    switch operation {
    case "merge": return String(localized: "sourceControl.changesHeader.merging", defaultValue: "Merging")
    case "rebase": return String(localized: "sourceControl.changesHeader.rebasing", defaultValue: "Rebasing")
    case "cherry-pick": return String(localized: "sourceControl.changesHeader.cherryPicking", defaultValue: "Cherry-picking")
    default: break
    }
    guard let upstream = status?.upstream else { return nil }
    if !upstream.hasUpstream {
      return String(localized: "sourceControl.changesHeader.notPublished", defaultValue: "Not published")
    }
    if upstream.ahead > 0, upstream.behind > 0 {
      return String(
        format: String(localized: "sourceControl.state.syncStatus", defaultValue: "%1$@ ahead, %2$@ behind"),
        "\(upstream.ahead)", "\(upstream.behind)")
    }
    if upstream.ahead > 0 {
      return String.localizedStringWithFormat(
        String(localized: "sourceControl.changesHeader.notPushed", defaultValue: "%1$lld not pushed"), upstream.ahead)
    }
    if upstream.behind > 0 {
      return String.localizedStringWithFormat(
        String(localized: "sourceControl.changesHeader.behind", defaultValue: "%1$lld behind"), upstream.behind)
    }
    return String(localized: "sourceControl.changesHeader.upToDate", defaultValue: "Up to date")
  }

  // MARK: Next step

  /// The commit area's decision as the next step reads it.
  private var localStep: SourceControlNextStep.Local {
    switch primary {
    case .commit: return .commit
    case .stageAll: return .stage
    case .push, .publish: return .remote(pushOrPublish: true, ready: !busy)
    case .pull, .sync, .forcePush: return .remote(pushOrPublish: false, ready: !busy)
    case .none: return .idle
    }
  }

  /// What Create offers for the branch, from the host's eligibility.
  private var reviewCreation: SourceControlNextStep.Creation {
    guard let eligibility = prController.eligibility, eligibility.isSupported else { return .unavailable }
    if eligibility.needsPush { return .pushAndCreate }
    return eligibility.canCreate ? .create : .unavailable
  }

  private var reviewInput: SourceControlNextStep.Review {
    switch prController.state {
    case .idle, .loading: return hasBranch ? .loading : .none
    case .none, .error: return .none
    case .ready(let pr):
      let checks = prController.checks
      return .github(pr, failedChecks: checks.filter(\.isBroken).count, pendingChecks: PullRequestCheck.summarize(checks).pending)
    }
  }

  /// The one next action (source-control-next-step-decision.ts): local conflicts, the commit box, push or pull,
  /// create a review, then the review's own steps toward merge.
  private var nextStep: SourceControlNextStep {
    SourceControlNextStep.resolve(
      local: localStep, conflictOperation: operation, hasUnresolvedConflicts: hasUnresolvedConflicts,
      hasChangesToCommit: stagedCount > 0 || !stageablePaths.isEmpty, creation: reviewCreation, review: reviewInput)
  }

  private var agentLabel: String {
    prController.agentLabel ?? String(localized: "sourceControl.nextStep.genericAgent", defaultValue: "AI")
  }

  /// The one next action at the foot (MobileSourceControlNextStepBar.tsx, mobile-source-control-next-step.ts).
  private func updateBar() {
    guard status != nil else {
      bar.isHidden = true
      return
    }
    let agentNotice = prController.agentNotice
    let prError = hubTab == .pr ? nil : prController.error
    bar.notice = notice.map { ($0, true) } ?? prError.map { ($0, true) } ?? agentNotice
    let step = nextStep
    if case .resolveConflicts = step { prController.loadAgentLabel() }
    if case .fixChecks = step { prController.loadAgentLabel() }
    switch step {
    case .commit:
      showComposer()
    case .remote:
      showRemoteStep()
    case .completeMerge:
      bar.showButton(
        label: busyAction == "complete-merge"
          ? String(localized: "sourceControl.branchCard.completingMerge", defaultValue: "Completing…")
          : String(localized: "sourceControl.branchCard.completeMerge", defaultValue: "Complete merge"),
        icon: .check, enabled: !busy, loading: busyAction == "complete-merge", reason: nil
      ) { [weak self] in self?.completeMerge() }
    case .resolveConflicts(let review):
      bar.showButton(
        label: String(format: String(localized: "sourceControl.nextStep.resolveWithAgent", defaultValue: "Resolve with %1$@"), agentLabel),
        icon: .sparkles, enabled: true, loading: prController.isBusy(.agent), reason: nil
      ) { [weak self] in self?.resolveConflicts(review: review) }
    case .createReview(let pushFirst):
      showCreateReview(pushFirst: pushFirst, enabled: true)
    case .fixChecks(let failed):
      bar.showButton(
        label: String(format: String(localized: "sourceControl.nextStep.fixWithAgent", defaultValue: "Fix with %1$@"), agentLabel),
        icon: .sparkles, enabled: true, loading: prController.isBusy(.agent),
        reason: (
          String(localized: "sourceControl.nextStep.cantMergeYet", defaultValue: "Can’t merge yet:"),
          String.localizedStringWithFormat(
            String(localized: "sourceControl.nextStep.checksFailing", defaultValue: "%lld checks failing"), failed)
        )
      ) { [weak self] in
        guard let self else { return }
        prController.launchAgent(prompt: prController.fixChecksPrompt())
      }
    case .mergeWhenReady(let mergeState, let pending):
      bar.showButton(
        label: String(localized: "sourceControl.nextStep.mergeWhenReady", defaultValue: "Merge when ready"), icon: .gitMerge,
        tone: .secondary, enabled: true, loading: prController.isBusy(.autoMerge),
        reason: (nil, waitingReason(mergeState: mergeState, pending: pending))
      ) { [weak self] in self?.prController.setAutoMerge(true) }
    case .autoMergeOn:
      bar.showAutoMergeOn(loading: prController.isBusy(.autoMerge), enabled: true) { [weak self] in
        self?.prController.setAutoMerge(false)
      }
    case .merge:
      bar.showButton(
        label: Self.mergeLabel(prController.pr?.mergeMethods.defaultMethod ?? "squash"), icon: .gitMerge, tone: .merge,
        enabled: true, loading: prController.isBusy(.merge), reason: nil
      ) { [weak self] in self?.openMergeSheet() }
    case .mergeBlocked(let mergeState):
      bar.showButton(
        label: String(localized: "sourceControl.nextStep.merge", defaultValue: "Merge"), icon: .gitMerge, tone: .merge,
        enabled: false, loading: false, reason: Self.mergeStateHint(mergeState).map { (nil, $0) }
      ) {}
    case .merged:
      bar.showMerged(base: prController.pr?.baseRefName)
    case .none:
      // No review and Create is blocked: say why instead of hiding the bar.
      if reviewInput == .none, let eligibility = prController.eligibility, eligibility.isSupported, !eligibility.canCreate {
        showCreateReview(pushFirst: false, enabled: false)
      } else {
        bar.showNothing()
      }
    }
    bar.isHidden = bar.isEmpty && bar.notice == nil
    view.setNeedsLayout()
  }

  private func showComposer() {
    let primary = primary
    let enabled: Bool = { if case .commit(let enabled) = primary { enabled } else { true } }() && !busy
    // As desktop, the AI button needs something staged; a running generation stays cancelable.
    let generate: (running: Bool, enabled: Bool, action: () -> Void)? =
      stagedCount > 0 || generatingMessage
      ? (generatingMessage, generatingMessage || (!busy && !hasMessage), { [weak self] in self?.generateCommitMessage() })
      : nil
    bar.showComposer(
      message: stagedCount == 0 ? "" : commitMessage, editable: stagedCount > 0 && !busy && !generatingMessage,
      label: commitLabel, enabled: enabled && !generatingMessage, loading: busyAction == "commit" || busyAction == "stage-all",
      generate: generate
    ) { [weak self] in
      if self?.primary == .stageAll { self?.stageAll() } else { self?.commit() }
    }
  }

  /// The branch's push, pull, sync or publish; nil when it has none.
  private var remoteStep: (label: String, icon: Lucide, id: String, run: () -> Void)? {
    switch primary {
    case .push(let count):
      return (
        String.localizedStringWithFormat(
          String(localized: "sourceControl.primaryAction.pushCommits", defaultValue: "Push %lld commits"), count), .arrowUp, "push",
        { [weak self] in self?.run("push") { try await $0.gitPush(worktreeId: $1) } }
      )
    case .pull(let count):
      return (
        String.localizedStringWithFormat(
          String(localized: "sourceControl.primaryAction.pullCommits", defaultValue: "Pull %lld commits"), count), .arrowDown, "pull",
        { [weak self] in self?.run("pull") { try await $0.gitPull(worktreeId: $1) } }
      )
    case .sync:
      return (
        String(localized: "sourceControl.primaryAction.sync", defaultValue: "Sync"), .arrowDownUp, "sync",
        { [weak self] in self?.sync() }
      )
    case .publish:
      return (
        String(localized: "sourceControl.primaryAction.publishBranch", defaultValue: "Publish Branch"), .arrowUp, "publish",
        { [weak self] in self?.run("publish") { try await $0.gitPush(worktreeId: $1, publish: true) } }
      )
    default:
      return nil
    }
  }

  private func showRemoteStep() {
    guard let step = remoteStep else { return bar.showNothing() }
    bar.showButton(label: step.label, icon: step.icon, enabled: !busy, loading: busyAction == step.id, reason: nil, action: step.run)
  }

  /// Create pull request, or Push & create when the branch needs a push first; disabled with why when it can't.
  private func showCreateReview(pushFirst: Bool, enabled: Bool) {
    let review =
      prController.eligibility?.provider == "gitlab"
      ? String(localized: "sourceControl.hostedReview.mrCopy.reviewLabel", defaultValue: "merge request")
      : String(localized: "sourceControl.hostedReview.prCopy.reviewLabel", defaultValue: "pull request")
    let label =
      pushFirst
      ? String(format: String(localized: "sourceControl.nextStep.pushAndCreateReview", defaultValue: "Push & create %1$@"), review)
      : String(format: String(localized: "sourceControl.nextStep.createReview", defaultValue: "Create %1$@"), review)
    let hint: String? =
      enabled
      ? nil
      : String(
        format: String(localized: "sourceControl.prCreate.notReady", defaultValue: "This branch is not ready for a %1$@ yet."), review)
    bar.showButton(
      label: label, icon: .gitPullRequest, enabled: enabled && !busy, loading: busyAction == "create-pr",
      reason: hint.map { (nil, $0) }
    ) { [weak self] in self?.createPullRequest(pushFirst: pushFirst) }
  }

  private func waitingReason(mergeState: String, pending: Int) -> String {
    if pending > 0 {
      return String.localizedStringWithFormat(
        String(localized: "sourceControl.nextStep.checksRunning", defaultValue: "%lld checks still running"), pending)
    }
    if mergeState == "review_required" {
      if let reviewer = prController.details?.reviewRequests.first?.login {
        return String(
          format: String(localized: "sourceControl.nextStep.waitingOnReviewer", defaultValue: "Waiting on review from %1$@"), reviewer)
      }
      return String(localized: "sourceControl.nextStep.waitingOnReview", defaultValue: "Waiting on review")
    }
    return Self.mergeStateHint(mergeState) ?? ""
  }

  /// Why a PR can't merge yet, in desktop's words (pr-actions-state.ts prMergeStateCopy).
  static func mergeStateHint(_ kind: String) -> String? {
    switch kind {
    case "merged": String(localized: "pullRequest.prActionsState.mergedHint", defaultValue: "This pull request is already merged")
    case "closed": String(localized: "pullRequest.prActionsState.closedHint", defaultValue: "This pull request is closed")
    case "draft": String(localized: "pullRequest.prActionsState.draftHint", defaultValue: "This pull request is still a draft")
    case "review_required":
      String(
        localized: "pullRequest.prActionsState.reviewRequiredHint",
        defaultValue: "GitHub requires review approval before this pull request can merge")
    case "changes_requested":
      String(
        localized: "pullRequest.prActionsState.changesRequestedHint", defaultValue: "GitHub reports requested changes on this pull request")
    case "conflicts": String(localized: "pullRequest.prActionsState.conflictsHint", defaultValue: "GitHub reports merge conflicts")
    case "merge_queue", "merge_queue_auto_merge_on":
      String(localized: "pullRequest.prActionsState.mergeQueueHint", defaultValue: "This base branch uses GitHub merge queue")
    case "behind": String(localized: "pullRequest.prActionsState.behindHint", defaultValue: "Update the branch before merging")
    case "blocked":
      String(localized: "pullRequest.prActionsState.blockedHint", defaultValue: "GitHub reports this pull request is blocked")
    case "checking":
      String(
        localized: "pullRequest.prActionsState.checkingHint", defaultValue: "GitHub is still computing this pull request merge status")
    case "merge_status_unavailable":
      String(
        localized: "pullRequest.prActionsState.mergeStatusUnavailableHint", defaultValue: "Merge status is unavailable for this PR")
    default: nil
    }
  }

  static func mergeLabel(_ method: String) -> String {
    switch method {
    case "merge": String(localized: "pullRequest.prActionsState.methodMerge", defaultValue: "Create merge commit")
    case "rebase": String(localized: "pullRequest.prActionsState.methodRebase", defaultValue: "Rebase and merge")
    default: String(localized: "pullRequest.prActionsState.methodSquash", defaultValue: "Squash and merge")
    }
  }


  private var commitLabel: String {
    if primary == .stageAll { return String(localized: "sourceControl.primaryAction.stageAll", defaultValue: "Stage all") }
    return stagedCount > 0
      ? String.localizedStringWithFormat(
        String(localized: "sourceControl.primaryAction.commitFiles", defaultValue: "Commit %lld files"), stagedCount)
      : String(localized: "sourceControl.primaryAction.commit", defaultValue: "Commit")
  }

  // MARK: Menus

  /// The ⋯ menu (groupMobileSourceControlMenu): commit-and-send, the remote actions, Switch branch, then
  /// Refresh, then Force Push alone and red.
  private func actionsMenu() -> [UIMenuElement] {
    let upstream = status?.upstream
    let ahead = upstream?.ahead ?? 0
    let behind = upstream?.behind ?? 0
    let canCommit = stagedCount > 0 && hasMessage && !hasUnresolvedConflicts
    func action(
      _ title: String, _ icon: Lucide, enabled: Bool, hint: String? = nil, status: String? = nil,
      attributes: UIMenuElement.Attributes = [], _ handler: @escaping () -> Void
    ) -> UIAction {
      let subtitle = enabled ? status : hint
      return UIAction(
        title: title, subtitle: subtitle, image: icon.image(size: 18),
        attributes: attributes.union(enabled && !busy ? [] : .disabled)
      ) { _ in handler() }
    }
    let commitHint: String? =
      stagedCount == 0
      ? String(localized: "sourceControl.commitDropdown.stageFile", defaultValue: "Stage at least one file to commit")
      : !hasMessage ? String(localized: "sourceControl.commitDropdown.enterMessage", defaultValue: "Enter a commit message to commit") : nil
    let commits: [UIMenuElement] = [
      action(
        String(localized: "sourceControl.commitDropdown.commitPush", defaultValue: "Commit & Push"), .arrowUp,
        enabled: canCommit && hasBranch, hint: commitHint
      ) { [weak self] in self?.commit(then: "push") },
      action(
        String(localized: "sourceControl.commitDropdown.commitSync", defaultValue: "Commit & Sync"), .arrowDownUp,
        enabled: canCommit && published,
        hint: commitHint
          ?? String(localized: "sourceControl.commitDropdown.publishBranchFirstToSync", defaultValue: "Publish the branch first to sync commits")
      ) { [weak self] in self?.commit(then: "sync") },
    ]
    let publishFirst = { (key: String) -> String in
      switch key {
      case "pull":
        String(localized: "sourceControl.remoteDropdown.publishBranchFirstToPull", defaultValue: "Publish the branch first to pull commits")
      case "fast":
        String(
          localized: "sourceControl.remoteDropdown.publishBranchFirstToFastForward",
          defaultValue: "Publish the branch first to fast-forward")
      default:
        String(localized: "sourceControl.remoteDropdown.publishBranchFirstToSync", defaultValue: "Publish the branch first to sync commits")
      }
    }
    let upToDate = String(localized: "sourceControl.remoteDropdown.statusUpToDate", defaultValue: "Up to date")
    var remote: [UIMenuElement] = [
      action(
        String(localized: "sourceControl.remoteDropdown.push", defaultValue: "Push"), .arrowUp, enabled: hasBranch,
        hint: String(localized: "sourceControl.remoteDropdown.checkOutBranchToPush", defaultValue: "Check out a branch before pushing commits"),
        status: !published
          ? String(localized: "sourceControl.remoteDropdown.statusSetsUpstream", defaultValue: "Sets upstream")
          : ahead > 0 ? "↑\(ahead)" : upToDate
      ) { [weak self] in self?.run("push") { try await $0.gitPush(worktreeId: $1) } }
    ]
    if hasBranch, !published {
      remote.append(
        action(
          String(localized: "sourceControl.remoteDropdown.publishBranch", defaultValue: "Publish Branch"), .cloudUpload, enabled: true
        ) { [weak self] in self?.run("publish") { try await $0.gitPush(worktreeId: $1, publish: true) } })
    }
    remote += [
      action(
        String(localized: "sourceControl.remoteDropdown.fetch", defaultValue: "Fetch"), .download, enabled: true,
        status: String(localized: "sourceControl.remoteDropdown.fetchTitle", defaultValue: "Fetch from remote without merging")
      ) { [weak self] in self?.run("fetch") { try await $0.gitFetch(worktreeId: $1) } },
      action(
        String(localized: "sourceControl.remoteDropdown.pull", defaultValue: "Pull"), .arrowDown, enabled: published,
        hint: publishFirst("pull"), status: behind > 0 ? "↓\(behind)" : upToDate
      ) { [weak self] in self?.run("pull") { try await $0.gitPull(worktreeId: $1) } },
      action(
        String(localized: "sourceControl.remoteDropdown.fastForward", defaultValue: "Fast-forward"), .arrowDown, enabled: published,
        hint: publishFirst("fast"), status: behind > 0 ? "↓\(behind)" : upToDate
      ) { [weak self] in self?.run("fast-forward") { try await $0.gitFastForward(worktreeId: $1) } },
      action(
        String(localized: "sourceControl.remoteDropdown.sync", defaultValue: "Sync"), .arrowDownUp, enabled: published,
        hint: publishFirst("sync"), status: ahead > 0 || behind > 0 ? "↓\(behind) ↑\(ahead)" : upToDate
      ) { [weak self] in self?.sync() },
    ]
    // Rebase onto the base the branch's PR targets; only a remote base can be fetched and rebased onto.
    let rebaseLabel = baseRef.map(Self.rebaseLabel)
    let remoteBase = rebaseLabel?.contains("/") == true
    let dirty = !entries.isEmpty
    remote.append(
      action(
        rebaseLabel.map {
          String(format: String(localized: "sourceControl.remoteDropdown.rebaseFromNamedBase", defaultValue: "Rebase from %1$@"), $0)
        } ?? String(localized: "sourceControl.remoteDropdown.rebaseFromBase", defaultValue: "Rebase from Base"),
        .gitBranch, enabled: remoteBase,
        hint: String(
          localized: "sourceControl.remoteDropdown.rebaseChooseRemoteBase", defaultValue: "Choose a remote base branch to rebase from"),
        status: dirty ? String(localized: "sourceControl.remoteDropdown.statusStashFirst", defaultValue: "Stash first") : nil
      ) { [weak self] in self?.rebase() })
    // Switch branch opens the same branch list the branch line does.
    let branch: [UIMenuElement] = [
      UIMenu(
        title: String(localized: "sourceControl.actions.switchBranch", defaultValue: "Switch branch"),
        image: Lucide.gitBranch.image(size: 18),
        children: [UIDeferredMenuElement { [weak self] completion in self?.branchMenu(completion) ?? completion([]) }]),
      action(String(localized: "sourceControl.actions.openCommits", defaultValue: "Open commits"), .history, enabled: true) {
        [weak self] in self?.openCommits()
      },
    ]
    let refresh = action(
      String(localized: "sourceControl.header.refresh", defaultValue: "Refresh source control"), .refreshCw, enabled: true
    ) { [weak self] in self?.reload(refresh: true) }
    let force = action(
      String(localized: "sourceControl.remoteDropdown.forcePush", defaultValue: "Force Push"), .arrowUp, enabled: hasBranch,
      hint: String(
        localized: "sourceControl.remoteDropdown.checkOutBranchToForcePush", defaultValue: "Check out a branch before force pushing commits"),
      status: behind > 0
        ? String(format: String(localized: "sourceControl.remoteDropdown.statusReplaces", defaultValue: "Replaces ↓%1$@"), "\(behind)")
        : ahead > 0 ? "↑\(ahead)" : upToDate,
      attributes: .destructive
    ) { [weak self] in self?.run("force-push") { try await $0.gitPush(worktreeId: $1, forceWithLease: true) } }
    if hubTab == .pr { return pullRequestMenu() }
    var groups: [[UIMenuElement]] = [remote, branch, [refresh], [force]]
    if stagedCount > 0 { groups.insert(commits, at: 0) }
    return groups.map { UIMenu(options: .displayInline, children: $0) }
  }

  /// `refs/remotes/origin/main` as the menu names it.
  private static func rebaseLabel(_ ref: String) -> String {
    ref.replacingOccurrences(of: "^refs/remotes/", with: "", options: .regularExpression)
      .replacingOccurrences(of: "^remotes/", with: "", options: .regularExpression)
  }

  /// The PR segment's ⋯ menu (use-pr-tab-menu.ts): the web, then edits that don't compete with Merge, then
  /// Refresh, Unlink and Close in red. Without a PR, only Refresh.
  private func pullRequestMenu() -> [UIMenuElement] {
    let refresh = UIAction(
      title: String(localized: "pullRequest.menu.refresh", defaultValue: "Refresh"), image: Lucide.refreshCw.image(size: 18)
    ) { [weak self] _ in self?.reload(refresh: true) }
    guard let pr = prController.pr else { return [refresh] }
    var web: [UIMenuElement] = []
    if let url = URL(string: pr.url), !pr.url.isEmpty {
      web.append(
        UIAction(
          title: String(localized: "pullRequest.menu.openOnGitHub", defaultValue: "Open on GitHub"),
          image: Lucide.externalLink.image(size: 18)
        ) { _ in UIApplication.shared.open(url) })
      web.append(
        UIAction(title: String(localized: "pullRequest.menu.copyLink", defaultValue: "Copy link"), image: Lucide.link.image(size: 18)) { _ in
          UIPasteboard.general.url = url
          UINotificationFeedbackGenerator().notificationOccurred(.success)
        })
    }
    var edit: [UIMenuElement] = []
    if pr.isOpen {
      edit.append(
        UIAction(title: String(localized: "pullRequest.menu.editTitle", defaultValue: "Edit title"), image: Lucide.pencil.image(size: 18)) {
          [weak self] _ in self?.editTitle()
        })
    }
    if PullRequestMergeState(pr).autoMergeAction != nil {
      let on = pr.autoMergeEnabled == true
      edit.append(
        UIAction(
          title: String(localized: "pullRequest.menu.autoMerge", defaultValue: "Auto-merge"), image: Lucide.gitMerge.image(size: 18),
          attributes: prController.isBusy(.autoMerge) ? .disabled : [], state: on ? .on : .off
        ) { [weak self] _ in self?.prController.setAutoMerge(!on) })
    }
    if pr.state == "draft" {
      edit.append(
        UIAction(
          title: String(localized: "pullRequest.prActionsSection.markReadyButton", defaultValue: "Ready for review"),
          image: Lucide.eye.image(size: 18)
        ) { [weak self] _ in self?.prController.setDraft(false) })
    } else if pr.state == "open" {
      edit.append(
        UIAction(
          title: String(localized: "pullRequest.menu.markDraft", defaultValue: "Mark as draft"),
          image: Lucide.gitPullRequestDraft.image(size: 18)
        ) { [weak self] _ in self?.prController.setDraft(true) })
    }
    var manage: [UIMenuElement] = [
      refresh,
      UIAction(
        title: String(localized: "pullRequest.menu.unlink", defaultValue: "Unlink from workspace"), image: Lucide.unlink.image(size: 18),
        attributes: prController.isBusy(.unlink) ? .disabled : []
      ) { [weak self] _ in self?.confirmPullRequest(.unlink) },
    ]
    if pr.isOpen {
      manage.append(
        UIAction(
          title: String(localized: "pullRequest.menu.close", defaultValue: "Close pull request"),
          image: Lucide.gitPullRequestClosed.image(size: 18), attributes: .destructive
        ) { [weak self] _ in self?.confirmPullRequest(.close) })
    } else if pr.state == "closed" {
      manage.append(
        UIAction(
          title: String(localized: "pullRequest.prActionsSection.reopenAccessibilityLabel", defaultValue: "Reopen pull request"),
          image: Lucide.gitPullRequest.image(size: 18)
        ) { [weak self] _ in self?.confirmPullRequest(.reopen) })
    }
    return [web, edit, manage].filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
  }

  /// The branch picker (Switch Branch): the local branches, the current one checked.
  private func branchMenu(_ completion: @escaping ([UIMenuElement]) -> Void) {
    let api = api
    let worktreeId = worktreeId
    Task { [weak self] in
      let branches = try? await api.gitLocalBranches(worktreeId: worktreeId)
      let busy = self?.busy ?? true
      let items: [UIMenuElement] = (branches?.branches ?? []).map { name in
        let current = name == branches?.current
        return UIAction(
          title: name, subtitle: current ? String(localized: "sourceControl.modals.currentBranch", defaultValue: "current") : nil,
          attributes: busy ? .disabled : [], state: current ? .on : .off
        ) { [weak self] _ in
          guard !current else { return }
          self?.run("checkout") { try await $0.gitCheckout(worktreeId: $1, branch: name) }
        }
      }
      completion([
        UIMenu(
          title: String(localized: "sourceControl.modals.switchBranchTitle", defaultValue: "Switch Branch"), options: .displayInline,
          children: items)
      ])
    }
  }

  // MARK: Actions

  /// Runs one git call as `id`, then reads status again; a failure shows over the bar.
  private func run(_ id: String, _ body: @escaping (HostAPI, String) async throws -> Void) {
    guard !busy else { return }
    busyAction = id
    notice = nil
    rebuild()
    let api = api
    let worktreeId = worktreeId
    Task { [weak self] in
      var failure: String?
      do {
        try await body(api, worktreeId)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        failure = Self.message(error)
      }
      guard let self else { return }
      busyAction = nil
      notice = failure
      rebuild()
      reload()
    }
  }

  private func stageAll() {
    let paths = stageablePaths
    guard !paths.isEmpty else { return }
    run("stage-all") { try await $0.gitStage(worktreeId: $1, paths: paths) }
  }

  private func unstageAll() {
    let paths = unstageablePaths
    guard !paths.isEmpty else { return }
    run("unstage-all") { try await $0.gitUnstage(worktreeId: $1, paths: paths) }
  }

  private func sync() {
    run("sync") {
      try await $0.gitPull(worktreeId: $1)
      try await $0.gitPush(worktreeId: $1)
    }
  }

  private func completeMerge() {
    run("complete-merge") { try await $0.gitConflictOperation("git.completeMerge", worktreeId: $1) }
  }

  private func abort(_ operation: String) {
    run("abort") {
      try await $0.gitConflictOperation(operation == "rebase" ? "git.abortRebase" : "git.abortMerge", worktreeId: $1)
    }
  }

  /// Commits what's staged; `then` sends it on ("push" or "sync") once the commit landed.
  private func commit(then next: String? = nil) {
    let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, stagedCount > 0 else { return }
    view.endEditing(true)
    let failed = String(localized: "sourceControl.commitRunners.commitFailed", defaultValue: "Commit failed")
    run(next.map { "commit-\($0)" } ?? "commit") { [weak self] api, worktreeId in
      let outcome = try await api.gitCommit(worktreeId: worktreeId, message: message)
      guard outcome.success else { throw CommitFailure(message: outcome.error ?? failed) }
      await MainActor.run { self?.commitMessage = "" }
      if next == "sync" { try await api.gitPull(worktreeId: worktreeId) }
      if next != nil { try await api.gitPush(worktreeId: worktreeId) }
    }
  }

  private struct CommitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private func stage(_ entry: GitStatusEntry) {
    run(entry.path) { try await $0.gitStage(worktreeId: $1, path: entry.path) }
  }

  private func unstage(_ entry: GitStatusEntry) {
    run(entry.path) { try await $0.gitUnstage(worktreeId: $1, path: entry.path) }
  }

  private func confirmDiscard(_ entry: GitStatusEntry) {
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
      ) { [weak self] _ in self?.run(entry.path) { try await $0.gitDiscard(worktreeId: $1, path: entry.path) } })
    present(alert, animated: true)
  }

  private func open(_ entry: GitStatusEntry) {
    guard entry.canOpen, !busy else { return }
    navigationController?.pushViewController(
      GitDiffViewController(session: session, worktreeId: worktreeId, entry: entry), animated: true)
  }

  // MARK: Pull request

  /// The PR segment (MobilePrTabBody): the branch's PR with its gates, changes and description, or the empty state.
  private func buildPullRequest() {
    let ahead: (count: Int, base: String)? =
      commitsAhead.flatMap { count in baseRef.map { (count, Self.rebaseLabel($0)) } }
    PullRequestTabContent(
      controller: prController, branch: status?.branch, commitsAhead: ahead,
      openChecks: { [weak self] in self?.push { PullRequestChecksViewController(controller: $0) } },
      openComments: { [weak self] in self?.push { PullRequestCommentsViewController(controller: $0) } },
      openReviewers: { [weak self] in self?.push { PullRequestReviewersViewController(controller: $0) } },
      openChanges: { [weak self] in self?.selectTab(.changes) },
      editDescription: { [weak self] in self?.editDescription() },
      linkPullRequest: { [weak self] in self?.linkPullRequest() },
      retry: { [weak self] in self?.reload(refresh: true) }
    ).build(into: prStack, expandedDescription: expandedDescription) { [weak self] in
      guard let self else { return }
      expandedDescription.toggle()
      buildPullRequest()
    }
  }

  private func push(_ make: (PullRequestController) -> UIViewController) {
    Haptics.select()
    navigationController?.pushViewController(make(prController), animated: true)
  }

  private func selectTab(_ tab: Tab) {
    hubTab = tab
    segments.selectedSegmentIndex = tab.rawValue
    rebuild()
  }

  /// The PR read moved on: its tab, the bar, and the menu.
  private func prChanged() {
    if hubTab == .pr { buildPullRequest() }
    updateBar()
  }

  /// Links a PR by number or GitHub URL (MobileLinkPrForm.tsx); an issue URL is not a PR link.
  private func linkPullRequest() {
    let alert = UIAlertController(
      title: String(localized: "pullRequest.linkPrForm.title", defaultValue: "Link existing pull request"),
      message: String(localized: "pullRequest.linkPrForm.referenceLabel", defaultValue: "PR number or GitHub URL"),
      preferredStyle: .alert)
    let link = UIAlertAction(
      title: String(localized: "pullRequest.linkPrForm.linkButton", defaultValue: "Link pull request"), style: .default
    ) { [weak self, weak alert] _ in
      guard let self, let number = Self.pullRequestNumber(alert?.textFields?.first?.text ?? "") else { return }
      Task {
        if !(await self.prController.link(number)) { self.updateBar() }
        self.reload(refresh: true)
      }
    }
    link.isEnabled = false
    alert.addTextField { field in
      field.placeholder = String(
        localized: "pullRequest.linkPrForm.referencePlaceholder", defaultValue: "#123 or https://github.com/owner/repo/pull/123")
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.keyboardType = .URL
      field.addAction(
        UIAction { [weak field] _ in link.isEnabled = Self.pullRequestNumber(field?.text ?? "") != nil }, for: .editingChanged)
    }
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(link)
    present(alert, animated: true)
  }

  /// `#123`, `123`, or a GitHub (or Enterprise) `/pull/123` URL; nil for anything else.
  static func pullRequestNumber(_ input: String) -> Int? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = text.range(of: "^#?(\\d+)$", options: .regularExpression) {
      return Int(text[match].trimmingCharacters(in: CharacterSet(charactersIn: "#"))).flatMap { $0 > 0 ? $0 : nil }
    }
    guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
    let parts = url.path.split(separator: "/")
    guard parts.count >= 4, parts[2] == "pull" else { return nil }
    return Int(parts[3]).flatMap { $0 > 0 ? $0 : nil }
  }

  private func editTitle() {
    guard let pr = prController.pr else { return }
    let sheet = PullRequestTextSheet(
      title: String(localized: "pullRequest.editSheet.title", defaultValue: "Edit title"), initial: pr.title,
      submitTitle: String(localized: "common.save", defaultValue: "Save"), singleLine: true
    ) { [weak self] title in
      guard let self else { return nil }
      return await prController.updateTitle(title) ? nil : prController.error
    }
    present(sheet.presented(), animated: true)
  }

  private func editDescription() {
    guard prController.pr != nil else { return }
    let sheet = PullRequestTextSheet(
      title: String(localized: "pullRequest.editSheet.description", defaultValue: "Edit description"),
      initial: prController.details?.body ?? "", submitTitle: String(localized: "common.save", defaultValue: "Save"),
      allowsEmpty: true
    ) { [weak self] body in
      guard let self else { return nil }
      return await prController.updateBody(body) ? nil : prController.error
    }
    present(sheet.presented(), animated: true)
  }

  private enum PullRequestConfirm { case close, reopen, unlink }

  /// Close, Reopen and Unlink ask first (MobilePrTabSheets.tsx PrTabConfirm).
  private func confirmPullRequest(_ kind: PullRequestConfirm) {
    guard let pr = prController.pr else { return }
    let number = "\(pr.number)"
    let (title, message, button, style): (String, String, String, UIAlertAction.Style) =
      switch kind {
      case .close:
        (
          String(localized: "pullRequest.prActionsSection.closeConfirmTitle", defaultValue: "Close pull request?"),
          String(
            format: String(
              localized: "pullRequest.prActionsSection.closeConfirmMessage", defaultValue: "#%1$@ will be closed without merging."),
            number),
          String(localized: "common.close", defaultValue: "Close"), .destructive
        )
      case .reopen:
        (
          String(localized: "pullRequest.prActionsSection.reopenConfirmTitle", defaultValue: "Reopen pull request?"),
          String(format: String(localized: "pullRequest.prActionsSection.reopenConfirmMessage", defaultValue: "#%1$@ will be reopened."), number),
          String(localized: "pullRequest.prActionsSection.reopenButton", defaultValue: "Reopen"), .default
        )
      case .unlink:
        (
          String(localized: "pullRequest.tab.unlinkConfirmTitle", defaultValue: "Unlink pull request?"),
          String(
            format: String(
              localized: "pullRequest.tab.unlinkConfirmMessage", defaultValue: "#%1$@ stays open on GitHub; this workspace stops tracking it."),
            number),
          String(localized: "pullRequest.prActionsSection.unlinkButton", defaultValue: "Unlink"), .destructive
        )
      }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: button, style: style) { [weak self] _ in
        guard let self else { return }
        switch kind {
        case .close: prController.setOpen(false)
        case .reopen: prController.setOpen(true)
        case .unlink: prController.unlink()
        }
      })
    present(alert, animated: true)
  }

  /// The repo's merge methods, its default first (MobilePrTabSheets.tsx PrMergeSheet); a pick merges the head
  /// the sheet opened on.
  private func openMergeSheet() {
    guard let pr = prController.pr else { return }
    let sheet = PullRequestMergeSheet(controller: prController, pr: pr, label: Self.mergeLabel)
    let navigation = UINavigationController(rootViewController: sheet)
    navigation.sheetPresentationController?.detents = [.medium()]
    navigation.sheetPresentationController?.prefersGrabberVisible = true
    present(navigation, animated: true)
  }

  /// Opens Create PR; `pushFirst` pushes the branch (publishing it when it has no upstream) before creating.
  private func createPullRequest(pushFirst: Bool) {
    guard let branch = status?.branch else { return }
    view.endEditing(true)
    let create = CreatePullRequestViewController(
      session: session, worktreeId: worktreeId, branch: branch, eligibility: prController.eligibility, pushFirst: pushFirst,
      publish: !published
    ) { [weak self] _, _ in
      guard let self else { return }
      selectTab(.pr)
      reload(refresh: true)
    }
    let navigation = UINavigationController(rootViewController: create)
    navigation.sheetPresentationController?.detents = [.large()]
    present(navigation, animated: true)
  }

  /// Hands the conflicts to an agent: the worktree's own, or the ones GitHub reports for the PR.
  private func resolveConflicts(review: Bool) {
    let path = worktree?.path
    if review, let pr = prController.pr {
      let prompt = SourceControlPrompts.resolvePullRequestConflicts(
        baseRef: pr.conflictBaseRef ?? pr.baseRefName, files: pr.conflictFiles, worktreePath: path)
      prController.launchAgent { prompt }
    } else {
      let prompt = SourceControlPrompts.resolveConflicts(
        operation: status?.conflictOperation ?? "unknown",
        entries: entries.filter { $0.conflictStatus == "unresolved" }.map { ($0.path, $0.conflictKind) }, worktreePath: path)
      prController.launchAgent { prompt }
    }
  }

  // MARK: Commits

  /// The branch's commits, pushed over the hub; its Not pushed header carries the branch's remote step.
  private func openCommits() {
    Haptics.select()
    let page = CommitsViewController(
      session: session, worktreeId: worktreeId, branchName: status?.branch,
      actions: CommitsPageActions(
        remoteStep: { [weak self] in
          guard let self, let step = remoteStep else { return nil }
          return (step.label, !busy, busyAction == step.id)
        },
        runRemoteStep: { [weak self] in self?.remoteStep?.run() },
        rebase: { [weak self] base in self?.rebase(onto: base) },
        isRebasing: { [weak self] in self?.busyAction == "rebase" },
        actionError: { [weak self] in self?.notice }))
    commitsPage = page
    navigationController?.pushViewController(page, animated: true)
  }

  /// `git.rebaseFromBase` onto the effective base (Update branch, Rebase from Base).
  private func rebase(onto base: String? = nil) {
    guard let base = base ?? baseRef else {
      notice = String(localized: "sourceControl.actionSheetRunners.noBaseBranch", defaultValue: "No base branch to rebase onto")
      return updateBar()
    }
    run("rebase") { try await $0.gitRebaseFromBase(worktreeId: $1, baseRef: base) }
  }

  // MARK: Commit message AI

  /// `git.generateCommitMessage` from what is staged; tapping again while it runs cancels. Text typed meanwhile wins.
  private func generateCommitMessage() {
    let api = api
    let worktreeId = worktreeId
    if generatingMessage {
      generatingMessage = false
      updateBar()
      Task { await api.cancelGenerateCommitMessage(worktreeId: worktreeId) }
      return
    }
    guard !busy, !hasMessage else { return }
    generatingMessage = true
    notice = nil
    updateBar()
    Task { [weak self] in
      do {
        let message = try await api.generateCommitMessage(worktreeId: worktreeId)
        guard let self, generatingMessage else { return }
        if let message, !hasMessage {
          commitMessage = message
          UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
      } catch {
        guard let self, generatingMessage else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        notice = Self.message(error)
      }
      self?.generatingMessage = false
      self?.updateBar()
      self?.bar.updatePlaceholder()
    }
  }

  // MARK: Table

  func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].entries.count }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    let section = sections[section]
    let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: FileSectionHeader.reuseIdentifier) as? FileSectionHeader
    var actions: [UIAction] = []
    let merging = status?.conflictOperation == "merge"
    if section.id == "unstaged" {
      actions.append(
        UIAction(
          title: String(localized: "sourceControl.fileList.stageAll", defaultValue: "Stage all"),
          attributes: stageablePaths.isEmpty || busy ? .disabled : []
        ) { [weak self] _ in self?.stageAll() })
    } else if section.id == "staged", !merging {
      actions.append(
        UIAction(
          title: String(localized: "sourceControl.fileList.unstageAll", defaultValue: "Unstage all"),
          attributes: unstageablePaths.isEmpty || busy ? .disabled : []
        ) { [weak self] _ in self?.unstageAll() })
    }
    header?.configure(title: "\(section.title) \(section.entries.count)", actions: actions)
    return header
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: GitFileCell.reuseIdentifier, for: indexPath) as! GitFileCell
    let entry = sections[indexPath.section].entries[indexPath.row]
    cell.configure(entry: entry, rowBusy: busyAction == entry.path, busy: busy) { [weak self] in
      if entry.canUnstage { self?.unstage(entry) } else { self?.stage(entry) }
    }
    return cell
  }

  private func entry(at indexPath: IndexPath) -> GitStatusEntry { sections[indexPath.section].entries[indexPath.row] }

  func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    entry(at: indexPath).canOpen && !busy
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    open(entry(at: indexPath))
  }

  /// Discard sits behind a left swipe and still asks first.
  func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration?
  {
    let entry = entry(at: indexPath)
    guard entry.canDiscard, !busy else { return nil }
    let discard = UIContextualAction(
      style: .destructive, title: String(localized: "sourceControl.fileRows.discard", defaultValue: "Discard")
    ) { [weak self] _, _, done in
      self?.confirmDiscard(entry)
      done(false)
    }
    discard.image = Lucide.undo2.image(size: 18)
    discard.backgroundColor = Palette.statusRed
    let configuration = UISwipeActionsConfiguration(actions: [discard])
    configuration.performsFirstActionWithFullSwipe = false
    return configuration
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    let entry = entry(at: indexPath)
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
        UIAction(title: String(localized: "session.sheets.copyPath", defaultValue: "Copy Path"), image: Lucide.copy.image(size: 18)) { _ in
          UIPasteboard.general.string = entry.path
        })
      if entry.canDiscard {
        children.append(
          UIMenu(
            options: .displayInline,
            children: [
              UIAction(
                title: String(localized: "sourceControl.fileRows.discard", defaultValue: "Discard"),
                image: Lucide.undo2.image(size: 18), attributes: busy ? [.destructive, .disabled] : .destructive
              ) { [weak self] _ in self?.confirmDiscard(entry) }
            ]))
      }
      return UIMenu(children: children)
    })
  }

  // MARK: Commit message

  func textViewDidChange(_ textView: UITextView) {
    commitMessage = textView.text
    bar.updatePlaceholder()
    updateBar()
  }
}

// MARK: - Header

/// Above the Changes list: the branch (a button that switches it) and its sync state, then a paused
/// merge or rebase with Abort (MobileSourceControlChangesHeader.tsx).
private final class ChangesHeaderView: UIView {
  let branchButton = UIButton(type: .system)
  var onAbort: ((String) -> Void)?
  private let meta = TextLabel(size: Typography.metaSize, color: Palette.textSecondary)
  private let banner = UIStackView()
  private let bannerTitle = TextLabel(size: Typography.bodySize, weight: .semibold)
  private let bannerText = TextLabel(size: Typography.metaSize, color: Palette.textSecondary, lines: 0)
  private let abortButton = UIButton(type: .system)
  private let readError = TextLabel(size: Typography.metaSize, color: Palette.statusRed, lines: 0)
  private let commitsRow = PressableControl()
  private let commitsText = TextLabel(size: Typography.bodySize)
  var onOpenCommits: (() -> Void)?
  private var operation: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Palette.bgBase
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = .zero
    configuration.image = Lucide.gitBranch.image(size: 15, strokeWidth: 2.1).withTintColor(
      Palette.textSecondary, renderingMode: .alwaysOriginal)
    configuration.imagePadding = 6
    configuration.titleLineBreakMode = .byTruncatingTail
    branchButton.configuration = configuration
    let chevron = LucideView(.chevronDown, size: 14, strokeWidth: 2.2, color: Palette.textMuted)
    let branchRow = UIStackView(arrangedSubviews: [branchButton, chevron])
    branchRow.spacing = 6
    branchRow.alignment = .center
    // The whole branch line opens the picker, chevron included.
    chevron.isUserInteractionEnabled = false
    meta.setContentCompressionResistancePriority(.required, for: .horizontal)
    meta.setContentHuggingPriority(.required, for: .horizontal)
    let statusLine = UIStackView(arrangedSubviews: [branchRow, UIView(), meta])
    statusLine.alignment = .center
    statusLine.spacing = Spacing.sm
    statusLine.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

    let warning = LucideView(.triangleAlert, size: 17, strokeWidth: 2.1, color: Palette.statusAmber)
    var abort = UIButton.Configuration.plain()
    abort.baseForegroundColor = Palette.statusAmber
    abort.background.backgroundColor = Palette.bgRaised
    abort.background.strokeColor = Palette.statusAmber
    abort.background.strokeWidth = 1
    abort.background.cornerRadius = Radius.control
    abort.contentInsets = NSDirectionalEdgeInsets(top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md)
    abortButton.configuration = abort
    abortButton.addAction(UIAction { [weak self] _ in self.map { $0.onAbort?($0.operation ?? "merge") } }, for: .touchUpInside)
    let titleRow = UIStackView(arrangedSubviews: [warning, bannerTitle, abortButton])
    titleRow.spacing = Spacing.sm
    titleRow.alignment = .center
    bannerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
    banner.addArrangedSubview(titleRow)
    banner.addArrangedSubview(bannerText)
    banner.axis = .vertical
    banner.spacing = Spacing.sm
    banner.isLayoutMarginsRelativeArrangement = true
    banner.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.md, leading: Spacing.md, bottom: Spacing.md, trailing: Spacing.md)
    banner.backgroundColor = Palette.bgPanel
    banner.layer.cornerRadius = Radius.surface
    banner.layer.borderWidth = 1 / UIScreen.main.scale
    banner.layer.borderColor = Palette.statusAmber.cgColor

    // The branch's commits over its base, a row that opens the Commits page.
    let commitsIcon = LucideView(.gitCommitHorizontal, size: 16, strokeWidth: 2.1, color: Palette.textSecondary)
    let commitsChevron = LucideView(.chevronRight, size: 16, strokeWidth: 2.2, color: Palette.textMuted)
    commitsText.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let commitsLine = UIStackView(arrangedSubviews: [commitsIcon, commitsText, commitsChevron])
    commitsLine.spacing = Spacing.sm
    commitsLine.alignment = .center
    commitsLine.isUserInteractionEnabled = false
    commitsRow.addSubview(commitsLine)
    commitsLine.translatesAutoresizingMaskIntoConstraints = false
    let commitsBorder = Hairline()
    commitsRow.addSubview(commitsBorder)
    NSLayoutConstraint.activate([
      commitsLine.leadingAnchor.constraint(equalTo: commitsRow.leadingAnchor),
      commitsLine.trailingAnchor.constraint(equalTo: commitsRow.trailingAnchor),
      commitsLine.centerYAnchor.constraint(equalTo: commitsRow.centerYAnchor),
      commitsRow.heightAnchor.constraint(equalToConstant: 48),
      commitsBorder.leadingAnchor.constraint(equalTo: commitsRow.leadingAnchor),
      commitsBorder.trailingAnchor.constraint(equalTo: commitsRow.trailingAnchor),
      commitsBorder.bottomAnchor.constraint(equalTo: commitsRow.bottomAnchor),
    ])
    commitsRow.onPressedChange = { [weak self] pressed in self?.commitsRow.alpha = pressed ? Feedback.pressedOpacity : 1 }
    commitsRow.onPress = { [weak self] in self?.onOpenCommits?() }
    commitsRow.isAccessibilityElement = true
    commitsRow.accessibilityTraits = .button
    commitsRow.isHidden = true

    let column = UIStackView(arrangedSubviews: [statusLine, banner, readError, commitsRow])
    column.axis = .vertical
    column.spacing = Spacing.sm
    column.setCustomSpacing(Spacing.xs, after: statusLine)
    column.isLayoutMarginsRelativeArrangement = true
    column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.md + Spacing.xs, leading: Spacing.lg, bottom: Spacing.xs, trailing: Spacing.lg)
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    column.pin(to: self)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(branch: String, meta text: String?, operation: String?, unresolved: Int, busy: Bool, aborting: Bool, readError error: String?) {
    self.operation = operation
    branchButton.configuration?.attributedTitle = AttributedString(
      branch,
      attributes: AttributeContainer([.font: Typography.font(Typography.bodySize, .semibold), .foregroundColor: Palette.textPrimary]))
    branchButton.isEnabled = !busy
    branchButton.accessibilityLabel = String(
      format: String(localized: "sourceControl.changesHeader.switchBranch", defaultValue: "Switch branch from %1$@"), branch)
    meta.text = text
    meta.isHidden = text == nil
    banner.isHidden = operation == nil
    switch operation {
    case "merge": bannerTitle.text = String(localized: "sourceControl.changesHeader.mergeInProgress", defaultValue: "Merge in progress")
    case "rebase": bannerTitle.text = String(localized: "sourceControl.changesHeader.rebaseInProgress", defaultValue: "Rebase in progress")
    default:
      bannerTitle.text = String(localized: "sourceControl.changesHeader.cherryPickInProgress", defaultValue: "Cherry-pick in progress")
    }
    abortButton.isHidden = operation != "merge" && operation != "rebase"
    abortButton.isEnabled = !busy
    abortButton.alpha = busy ? 0.45 : 1
    let abortTitle: String =
      aborting
      ? String(localized: "sourceControl.conflictAbort.aborting", defaultValue: "Aborting…")
      : operation == "rebase"
      ? String(localized: "sourceControl.conflictAbort.abortRebase", defaultValue: "Abort rebase")
      : String(localized: "sourceControl.conflictAbort.abortMerge", defaultValue: "Abort merge")
    abortButton.configuration?.attributedTitle = AttributedString(
      abortTitle, attributes: AttributeContainer([.font: Typography.font(Typography.bodySize, .semibold)]))
    bannerText.text =
      unresolved > 0
      ? String.localizedStringWithFormat(
        String(
          localized: "sourceControl.changesHeader.filesNeedDecision",
          defaultValue: "%lld files need a decision before you can finish."), unresolved)
      : operation == "merge"
        ? String(localized: "sourceControl.changesHeader.conflictsResolved", defaultValue: "Every conflict is resolved. Finish from the bar below.")
        : String(
          localized: "sourceControl.changesHeader.continueOnComputer",
          defaultValue: "Every conflict is resolved. Continue on your computer to finish.")
    readError.text = error
    readError.isHidden = error == nil
  }

  /// The "N commits" row, shown while the branch has commits over its base.
  func show(commits: Int) {
    commitsRow.isHidden = commits <= 0
    commitsText.text = String.localizedStringWithFormat(
      String(localized: "sourceControl.changesHeader.commits", defaultValue: "%lld commits"), commits)
    commitsRow.accessibilityLabel = commitsText.text
  }
}

/// A section's title with its count, then its action (Stage all, Unstage all) at the trailing edge.
private final class FileSectionHeader: UITableViewHeaderFooterView {
  static let reuseIdentifier = "fileSection"

  private let title = TextLabel(size: 13, weight: .medium, color: Palette.textSecondary)
  private let actions = UIStackView()

  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    var background = UIBackgroundConfiguration.clear()
    background.backgroundColor = Palette.bgBase
    backgroundConfiguration = background
    actions.spacing = Spacing.lg
    let row = UIStackView(arrangedSubviews: [title, UIView(), actions])
    row.alignment = .center
    row.spacing = 6
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.lg),
      row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.lg),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.lg),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(title text: String, actions items: [UIAction]) {
    title.text = text
    actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for item in items {
      var configuration = UIButton.Configuration.plain()
      configuration.contentInsets = .zero
      configuration.attributedTitle = AttributedString(
        item.title,
        attributes: AttributeContainer([.font: Typography.font(13, .semibold), .foregroundColor: Palette.textPrimary]))
      let button = UIButton(configuration: configuration, primaryAction: item)
      button.isEnabled = !item.attributes.contains(.disabled)
      button.alpha = button.isEnabled ? 1 : 0.45
      actions.addArrangedSubview(button)
    }
  }
}

// MARK: - Rows

/// A changed file (MobileSourceControlFileRows.tsx): status letter, name over its folder, +/- line counts,
/// then Stage or Unstage.
final class GitFileCell: UITableViewCell {
  static let reuseIdentifier = "gitFile"

  private let statusLabel = UILabel()
  private let nameLabel = UILabel()
  private let folderLabel = UILabel()
  private let statsLabel = UILabel()
  private let toggle = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var onToggle: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = Palette.bgBase
    var selected = UIBackgroundConfiguration.clear()
    selected.backgroundColor = Palette.bgPanel
    selectedBackgroundView = UIView()
    selectedBackgroundView?.backgroundColor = Palette.bgPanel
    statusLabel.font = UIFont(name: "Menlo-Bold", size: Typography.metaSize) ?? .monospacedSystemFont(ofSize: Typography.metaSize, weight: .bold)
    nameLabel.font = Typography.font(Typography.bodySize)
    nameLabel.textColor = Palette.textPrimary
    nameLabel.lineBreakMode = .byTruncatingTail
    folderLabel.font = Typography.font(Typography.metaSize)
    folderLabel.textColor = Palette.textMuted
    folderLabel.lineBreakMode = .byTruncatingTail
    statsLabel.font = Typography.mono(Typography.metaSize)
    for view in [statsLabel, toggle] as [UIView] {
      view.setContentCompressionResistancePriority(.required, for: .horizontal)
      view.setContentHuggingPriority(.required, for: .horizontal)
    }
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = .zero
    configuration.background.cornerRadius = Radius.control
    toggle.configuration = configuration
    toggle.tintColor = Palette.textSecondary
    toggle.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
    spinner.color = Palette.textSecondary
    let text = UIStackView(arrangedSubviews: [nameLabel, folderLabel])
    text.axis = .vertical
    text.spacing = 2
    let row = UIStackView(arrangedSubviews: [statusLabel, text, statsLabel, toggle, spinner])
    row.alignment = .center
    row.spacing = Spacing.sm
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    let separator = Hairline()
    contentView.addSubview(separator)
    NSLayoutConstraint.activate([
      statusLabel.widthAnchor.constraint(equalToConstant: 24),
      toggle.widthAnchor.constraint(equalToConstant: 32),
      toggle.heightAnchor.constraint(equalToConstant: 32),
      row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.lg),
      row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.lg),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.sm),
      row.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -Spacing.sm),
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
      separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(entry: GitStatusEntry, rowBusy: Bool, busy: Bool, onToggle: @escaping () -> Void) {
    self.onToggle = onToggle
    let slash = entry.path.lastIndex(of: "/")
    let name = slash.map { String(entry.path[entry.path.index(after: $0)...]) } ?? entry.path
    let folder = slash.map { String(entry.path[..<$0]) } ?? ""
    statusLabel.text = Self.letter(entry.status)
    statusLabel.textColor = Self.color(entry.status)
    let gone = entry.status == "deleted"
    nameLabel.attributedText = NSAttributedString(
      string: name,
      attributes: gone ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Palette.textSecondary] : [:])
    var detail: String?
    if let oldPath = entry.oldPath {
      detail = String(format: String(localized: "sourceControl.fileRows.renamedFrom", defaultValue: "from %1$@"), oldPath)
    } else if entry.conflictStatus == "unresolved" {
      detail = Self.conflictLabel(entry.conflictKind)
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
    let canToggle = (entry.canStage || entry.canUnstage) && entry.conflictStatus != "unresolved"
    toggle.isHidden = rowBusy || !canToggle
    toggle.configuration?.image = (entry.canUnstage ? Lucide.minus : Lucide.plus).image(size: 18, strokeWidth: 2.2)
    toggle.isEnabled = !busy
    toggle.alpha = busy ? 0.45 : 1
    toggle.accessibilityLabel = String(
      format: entry.canUnstage
        ? String(localized: "sourceControl.fileRows.unstageFile", defaultValue: "Unstage %1$@")
        : String(localized: "sourceControl.fileRows.stageFile", defaultValue: "Stage %1$@"), entry.path)
    spinner.isHidden = !rowBusy
    if rowBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
    contentView.alpha = !entry.canOpen && entry.conflictStatus != "unresolved" ? 0.72 : 1
    accessibilityLabel = String(
      format: String(localized: "sourceControl.fileRows.openChangedFile", defaultValue: "Open changed file %1$@"), entry.path)
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

// MARK: - Next step bar

/// The foot of the screen (MobileSourceControlNextStepBar.tsx): a full-width action with its icon (merge in
/// green, waiting steps in grey), or the commit box with its capsule and the AI button; auto-merge's Cancel and
/// a merged PR's note; why a step can't run, and a failed action's message, above either.
private final class NextStepBar: UIView {
  enum Tone { case primary, secondary, merge }

  let messageView = UITextView()
  private let noticeLabel = TextLabel(size: Typography.metaSize, color: Palette.statusRed, alignment: .center, lines: 3)
  private let reasonLabel = TextLabel(size: Typography.metaSize, color: Palette.textSecondary, alignment: .center, lines: 2)
  private let button = UIButton(type: .system)
  private let secondaryButton = UIButton(type: .system)
  private let statusLabel = TextLabel(size: Typography.bodySize, color: Palette.textSecondary, alignment: .center)
  private let buttonRow = UIStackView()
  private let composer = UIView()
  private let placeholder = UILabel()
  private let generateButton = UIButton(type: .system)
  private let commitButton = UIButton(type: .system)
  private let column = UIStackView()
  private var buttonAction: (() -> Void)?
  private var secondaryAction: (() -> Void)?
  private var commitAction: (() -> Void)?
  private var generateAction: (() -> Void)?
  private(set) var isEmpty = true

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Palette.bgBase

    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = Palette.surfaceBright
    configuration.baseForegroundColor = Palette.bgBase
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = Radius.control
    configuration.imagePadding = Spacing.sm
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg)
    button.configuration = configuration
    button.addAction(UIAction { [weak self] _ in self?.buttonAction?() }, for: .touchUpInside)
    secondaryButton.configuration = configuration
    secondaryButton.addAction(UIAction { [weak self] _ in self?.secondaryAction?() }, for: .touchUpInside)
    secondaryButton.setContentHuggingPriority(.required, for: .horizontal)
    statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    buttonRow.addArrangedSubview(statusLabel)
    buttonRow.addArrangedSubview(button)
    buttonRow.addArrangedSubview(secondaryButton)
    buttonRow.spacing = Spacing.sm
    buttonRow.alignment = .center
    buttonRow.heightAnchor.constraint(equalToConstant: 48).isActive = true
    button.heightAnchor.constraint(equalToConstant: 48).isActive = true
    secondaryButton.heightAnchor.constraint(equalToConstant: 48).isActive = true

    // The commit box: the message over a row with the AI button and the action's capsule.
    composer.backgroundColor = Palette.composerSurface
    composer.layer.cornerRadius = Radius.floating
    composer.layer.borderWidth = 1
    composer.layer.borderColor = Palette.composerBorder.cgColor
    messageView.font = Typography.font(16)
    messageView.textColor = Palette.textPrimary
    messageView.backgroundColor = .clear
    messageView.isScrollEnabled = false
    messageView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
    messageView.textContainer.lineFragmentPadding = 0
    placeholder.font = messageView.font
    placeholder.textColor = Palette.textMuted
    placeholder.text = String(localized: "sourceControl.content.commitMessagePlaceholder", defaultValue: "Commit message")
    var commit = UIButton.Configuration.filled()
    commit.cornerStyle = .capsule
    commit.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg)
    commitButton.configuration = commit
    commitButton.addAction(UIAction { [weak self] _ in self?.commitAction?() }, for: .touchUpInside)
    var generate = UIButton.Configuration.filled()
    generate.cornerStyle = .capsule
    generate.baseBackgroundColor = Palette.composerControl
    generate.baseForegroundColor = Palette.textSecondary
    generate.image = Lucide.sparkles.image(size: 17, strokeWidth: 2)
    generate.contentInsets = .zero
    generateButton.configuration = generate
    generateButton.addAction(UIAction { [weak self] _ in self?.generateAction?() }, for: .touchUpInside)
    for part in [messageView, placeholder, generateButton, commitButton] as [UIView] {
      part.translatesAutoresizingMaskIntoConstraints = false
      composer.addSubview(part)
    }
    NSLayoutConstraint.activate([
      messageView.topAnchor.constraint(equalTo: composer.topAnchor, constant: Spacing.md),
      messageView.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: Spacing.md),
      messageView.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -Spacing.md),
      messageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
      messageView.heightAnchor.constraint(lessThanOrEqualToConstant: 7 * 22 + 4),
      placeholder.leadingAnchor.constraint(equalTo: messageView.leadingAnchor),
      placeholder.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 2),
      generateButton.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: Spacing.md),
      generateButton.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),
      generateButton.widthAnchor.constraint(equalToConstant: 38),
      generateButton.heightAnchor.constraint(equalToConstant: 38),
      commitButton.topAnchor.constraint(equalTo: messageView.bottomAnchor, constant: Spacing.sm),
      commitButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -Spacing.md),
      commitButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -Spacing.md),
      commitButton.heightAnchor.constraint(equalToConstant: 38),
    ])

    column.addArrangedSubview(noticeLabel)
    column.addArrangedSubview(reasonLabel)
    column.addArrangedSubview(buttonRow)
    column.addArrangedSubview(composer)
    column.axis = .vertical
    column.spacing = Spacing.sm
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
      column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
      column.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.md),
    ])
    reasonLabel.isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// A failed action, or an agent launch's word, over the bar.
  var notice: (text: String, failed: Bool)? {
    didSet {
      noticeLabel.text = notice?.text
      noticeLabel.textColor = notice?.failed == false ? Palette.textSecondary : Palette.statusRed
      noticeLabel.isHidden = notice == nil
    }
  }

  private func reason(_ reason: (lead: String?, text: String)?) {
    reasonLabel.isHidden = reason == nil
    guard let reason else { return }
    reasonLabel.runs = (reason.lead.map { [($0 + " ", Palette.textPrimary)] } ?? []) + [(reason.text, Palette.textSecondary)]
  }

  func showNothing() {
    isEmpty = true
    buttonRow.isHidden = true
    composer.isHidden = true
    reason(nil)
  }

  private func style(_ target: UIButton, label: String, icon: Lucide?, tone: Tone, enabled: Bool, loading: Bool) {
    let off = !enabled && !loading
    let foreground: UIColor =
      off ? Palette.textMuted : tone == .merge ? Palette.onMergeGreen : tone == .secondary ? Palette.textPrimary : Palette.bgBase
    target.configuration?.baseBackgroundColor =
      off || tone == .secondary ? Palette.bgRaised : tone == .merge ? Palette.mergeGreen : Palette.surfaceBright
    target.configuration?.attributedTitle = AttributedString(
      label, attributes: AttributeContainer([.font: Typography.font(Typography.bodySize, .semibold), .foregroundColor: foreground]))
    target.configuration?.image = icon?.image(size: 17, strokeWidth: 2.2).withTintColor(foreground, renderingMode: .alwaysOriginal)
    target.configuration?.showsActivityIndicator = loading
    target.configuration?.activityIndicatorColorTransformer = UIConfigurationColorTransformer { _ in foreground }
    target.isEnabled = enabled && !loading
  }

  func showButton(
    label: String, icon: Lucide, tone: Tone = .primary, enabled: Bool, loading: Bool, reason why: (lead: String?, text: String)?,
    action: @escaping () -> Void
  ) {
    isEmpty = false
    composer.isHidden = true
    buttonRow.isHidden = false
    statusLabel.isHidden = true
    secondaryButton.isHidden = true
    button.isHidden = false
    buttonAction = action
    style(button, label: label, icon: icon, tone: tone, enabled: enabled, loading: loading)
    reason(why)
  }

  /// Auto-merge is on: the note, and Cancel to turn it off.
  func showAutoMergeOn(loading: Bool, enabled: Bool, onCancel: @escaping () -> Void) {
    isEmpty = false
    composer.isHidden = true
    buttonRow.isHidden = false
    button.isHidden = true
    statusLabel.isHidden = false
    statusLabel.runs = nil
    statusLabel.text = String(localized: "sourceControl.nextStep.willMergeWhenReady", defaultValue: "Will merge when ready")
    statusLabel.textAlignment = .natural
    secondaryButton.isHidden = false
    secondaryAction = onCancel
    style(
      secondaryButton, label: String(localized: "sourceControl.nextStep.cancelAutoMerge", defaultValue: "Cancel"), icon: nil,
      tone: .secondary, enabled: enabled, loading: loading)
    secondaryButton.accessibilityLabel = String(
      localized: "sourceControl.nextStep.cancelAutoMergeLabel", defaultValue: "Cancel auto-merge")
    reason(nil)
  }

  /// The PR is merged: a quiet note, no action.
  func showMerged(base: String?) {
    isEmpty = false
    composer.isHidden = true
    buttonRow.isHidden = false
    button.isHidden = true
    secondaryButton.isHidden = true
    statusLabel.isHidden = false
    statusLabel.textAlignment = .center
    statusLabel.text =
      base.map { String(format: String(localized: "sourceControl.nextStep.mergedInto", defaultValue: "Merged into %1$@"), $0) }
      ?? String(localized: "sourceControl.nextStep.merged", defaultValue: "Merged")
    reason(nil)
  }

  /// The commit box. `generate` shows the AI button: nil hides it, `running` turns it into a spinner that cancels.
  func showComposer(
    message: String, editable: Bool, label: String, enabled: Bool, loading: Bool,
    generate: (running: Bool, enabled: Bool, action: () -> Void)? = nil, action: (() -> Void)? = nil
  ) {
    isEmpty = false
    buttonRow.isHidden = true
    composer.isHidden = false
    reason(nil)
    commitAction = action
    if messageView.text != message { messageView.text = message }
    messageView.isEditable = editable
    if !editable, messageView.isFirstResponder { messageView.resignFirstResponder() }
    messageView.accessibilityLabel =
      editable
      ? nil
      : String(localized: "sourceControl.content.commitMessageDisabled", defaultValue: "Commit message disabled. No staged files.")
    updatePlaceholder()
    let foreground = enabled ? Palette.bgBase : Palette.textMuted
    commitButton.configuration?.baseBackgroundColor = enabled ? Palette.surfaceBright : Palette.composerControl
    commitButton.configuration?.attributedTitle = AttributedString(
      label, attributes: AttributeContainer([.font: Typography.font(Typography.bodySize, .semibold), .foregroundColor: foreground]))
    commitButton.configuration?.showsActivityIndicator = loading
    commitButton.isEnabled = enabled && !loading
    commitButton.accessibilityLabel = label
    generateButton.isHidden = generate == nil
    generateAction = generate?.action
    if let generate {
      generateButton.configuration?.showsActivityIndicator = generate.running
      generateButton.configuration?.image = generate.running ? nil : Lucide.sparkles.image(size: 17, strokeWidth: 2)
      generateButton.isEnabled = generate.enabled
      generateButton.accessibilityLabel =
        generate.running
        ? String(localized: "sourceControl.content.cancelGeneration", defaultValue: "Cancel commit message generation")
        : String(localized: "sourceControl.content.generateMessage", defaultValue: "Generate commit message with AI")
      generateButton.accessibilityHint =
        !generate.running && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? String(localized: "sourceControl.content.regenerateHint", defaultValue: "Clear the message to regenerate.") : nil
    }
  }

  func updatePlaceholder() {
    placeholder.isHidden = !messageView.text.isEmpty
    // Past seven lines the box scrolls instead of growing.
    let fits = messageView.sizeThatFits(CGSize(width: messageView.bounds.width, height: .greatestFiniteMagnitude)).height <= 7 * 22 + 4
    messageView.isScrollEnabled = !fits
  }
}
