import OrcaCore
import UIKit

/// Create worktree (new-workspace/creation/forms/NewWorktreeFormSheet.tsx): where it goes (project and the host it
/// runs on, connecting an SSH one first), what it starts from (a name, or an issue, pull or merge request, Linear or
/// Jira issue, or branch), the agent that starts in it, and folded options with the setup script. The button at the
/// bottom makes it on this desktop, asking first before running a setup script it hasn't trusted, and opens it.
final class NewWorkspaceViewController: UITableViewController {
  /// An agent choice; a nil id is a blank terminal.
  struct Agent: Equatable {
    let id: String?
    let title: String

    static let blank = Agent(
      id: nil,
      title: String(localized: "components.newWorktreeAgentSelection.blankTerminal", defaultValue: "Blank Terminal"))

    var image: UIImage {
      AgentMark.icon(for: id)?.image(size: 20)
        ?? Lucide.terminal.image(size: 20).withTintColor(Palette.textMuted, renderingMode: .alwaysOriginal)
    }
  }

  /// The official picker's order (TUI_AGENT_AUTO_PICK_ORDER) and names (TUI_AGENT_DISPLAY_NAMES).
  static let agentOrder = [
    "claude", "claude-agent-teams", "openclaude", "codex", "grok", "copilot", "opencode2", "opencode", "mimo-code", "ante",
    "trae", "muse", "dsh", "qoder", "qoder-cn", "zcode", "pi", "omp", "prime-agent", "gemini", "antigravity", "aider",
    "goose", "amp", "kilo", "kiro", "crush", "aug", "autohand", "cline", "codebuff", "freebuff", "command-code",
    "continue", "cursor", "droid", "kimi", "mistral-vibe", "qwen-code", "rovo", "hermes", "devin", "openclaw",
    "codebuddy", "jcode",
  ]
  static let agentNames: [String: String] = [
    "claude": "Claude", "claude-agent-teams": "Claude Agent Teams", "codebuddy": "CodeBuddy", "openclaude": "OpenClaude",
    "codex": "Codex", "devin": "Devin", "ante": "Ante", "trae": "Trae", "muse": "Muse", "dsh": "DeepSeek Harness",
    "zcode": "ZCode", "autohand": "Autohand Code", "opencode": "OpenCode", "opencode2": "OpenCode 2",
    "mimo-code": "MiMo Code", "pi": "Pi", "omp": "OMP", "prime-agent": "Prime Agent", "qoder": "Qoder CLI",
    "qoder-cn": "Qoder CLI China", "gemini": "Gemini", "antigravity": "Antigravity", "aider": "Aider", "goose": "Goose",
    "amp": "Amp", "kilo": "Kilocode", "kiro": "Kiro", "crush": "Charm", "aug": "Auggie", "cline": "Cline",
    "codebuff": "Codebuff", "freebuff": "Freebuff", "command-code": "Command Code", "continue": "Continue",
    "cursor": "Cursor", "droid": "Droid", "kimi": "Kimi", "mistral-vibe": "Mistral Vibe", "qwen-code": "Qwen Code",
    "rovo": "Rovo Dev", "hermes": "Hermes", "openclaw": "OpenClaw", "copilot": "GitHub Copilot", "grok": "Grok",
    "jcode": "Jcode",
  ]

  private static func agentChoice(_ id: String) -> Agent { Agent(id: id, title: agentNames[id] ?? id) }

  private enum Section { case location, ssh, start, agent, options, setup }
  private enum Row { case project, runOn, ssh, start, agent, name, branchName, note, setupRun, setupSkip, setupToggle }

  /// How a create's setup was settled: a forced choice from the trust prompt, and the approval it carries.
  private struct SetupApproval {
    var decision: String
    /// nil: repo-wide trust, nothing pinned.
    var hash: String?
  }

  private let session: HostSession
  private let onCreated: (String) -> Void
  private var repo: Repo?
  private var sshLabels: [String: String] = [:]
  /// Until the host says which agents it has, the form offers the first one, as the official form does.
  private var agent = NewWorkspaceViewController.agentChoice("claude")
  private var agentChoices: [Agent] = [NewWorkspaceViewController.agentChoice("claude"), .blank]
  private var agentOverridden = false
  private var agentsFor: String?

  private var availability = WorkspaceSourceAvailability()
  private var trust = OrcaHookTrust(nil)

  private var start: WorkspaceStart = .name
  /// The workspace name: typed, or seeded by the source picked.
  private var name = ""
  /// The name came from the picked source and changes with it.
  private var nameAutoManaged = false
  private var branchName = ""
  /// Kept on the phone per desktop until a create succeeds (drafts/durable-draft-fields.ts).
  private var note = "" {
    didSet { UserDefaults.standard.set(note.isEmpty ? nil : note, forKey: noteKey) }
  }
  private var optionsOpen = false
  private var creating = false
  private var errorText: String?

  /// A pull or merge request's start point, read when it is picked.
  private var base: WorkspaceCreateRequest.HostedBase?
  private var baseTask: Task<Void, Never>?

  /// The picked project's setup script (`repo.hooks`) and what the user chose for it.
  private var setup: RepoSetupHooks?
  private var setupFor: String?
  private var setupChoice: String?
  private var runSetup = true

  /// The picked SSH project's connection.
  private var ssh: SSHConnectionState?
  private var sshFor: String?
  private var connecting = false

  private let createButton = UIButton(configuration: .prominentGlass())
  private let errorLabel = UILabel()

  init(session: HostSession, projects: [Repo], onCreated: @escaping (String) -> Void) {
    self.session = session
    self.onCreated = onCreated
    // The caller's pick of projects only chooses where the form opens; the picker lists every project.
    repo = projects.first ?? session.repos.first
    super.init(style: .insetGrouped)
    note = UserDefaults.standard.string(forKey: noteKey) ?? ""
    // A kept note opens Options, so it isn't sent unseen.
    optionsOpen = !note.isEmpty
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var noteKey: String { "orca.newWorkspace.note.\(session.host.id.uuidString)" }

  static func sheet(session: HostSession, projects: [Repo], onCreated: @escaping (String) -> Void) -> UIViewController {
    let navigation = UINavigationController(
      rootViewController: NewWorkspaceViewController(session: session, projects: projects, onCreated: onCreated))
    if let sheet = navigation.sheetPresentationController {
      // About the form's own height, as the official drawer opens; the source picker grows it.
      sheet.detents = [.custom(identifier: .form) { min($0.maximumDetentValue, 560) }, .large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: String(localized: "common.cancel", defaultValue: "Cancel"),
      primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.register(StartFieldCell.self, forCellReuseIdentifier: "start")
    tableView.register(LabeledFieldCell.self, forCellReuseIdentifier: "field")
    tableView.register(FormSectionHeader.self, forHeaderFooterViewReuseIdentifier: "header")
    tableView.keyboardDismissMode = .interactive
    tableView.sectionHeaderTopPadding = 0
    // The create button stays on the sheet's floor, as the official's does, above the home indicator.
    let footer = makeFooter()
    footer.translatesAutoresizingMaskIntoConstraints = false
    if let host = navigationController?.view {
      host.addSubview(footer)
      NSLayoutConstraint.activate([
        footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        footer.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
      ])
      tableView.contentInset.bottom = footer.frame.height
    } else {
      tableView.tableFooterView = footer
    }
    refresh()
    loadTargets()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Back from a picker: what it chose is drawn here.
    refresh()
  }

  // MARK: State

  private var isGit: Bool { repo.map { !$0.isFolder } ?? true }

  /// An SSH project that isn't connected can't make a workspace or search its sources yet.
  private var sshGated: Bool { repo?.connectionId != nil && ssh?.isConnected != true }

  private var formTitle: String {
    isGit
      ? String(localized: "components.newWorktreeFormSheet.createWorktree", defaultValue: "Create worktree")
      : String(localized: "components.newWorktreeFormSheet.createWorkspace", defaultValue: "Create workspace")
  }

  private var sections: [(section: Section, rows: [Row])] {
    var options: [Row] = []
    var setupRows: [Row] = []
    if optionsOpen {
      if start != .name { options.append(.name) }
      if isGit {
        switch start {
        case .name, .branch, .newBranch: options.append(.branchName)
        default: break
        }
      }
      options.append(.note)
      if setup?.command != nil {
        setupRows = setup?.runPolicy == "ask" ? [.setupRun, .setupSkip] : [.setupToggle]
      }
    }
    var result: [(Section, [Row])] = [(.location, [.project, .runOn])]
    if repo?.connectionId != nil { result.append((.ssh, [.ssh])) }
    result += [(.start, [.start]), (.agent, [.agent]), (.options, options)]
    if !setupRows.isEmpty { result.append((.setup, setupRows)) }
    return result
  }

  private func refresh() {
    title = formTitle
    var configuration = createButton.configuration
    configuration?.title = formTitle
    configuration?.showsActivityIndicator = creating
    createButton.configuration = configuration
    createButton.isEnabled = repo != nil && !creating
    navigationItem.leftBarButtonItem?.isEnabled = !creating
    errorLabel.text = errorText
    errorLabel.isHidden = errorText == nil
    tableView.reloadData()
  }

  /// The SSH targets' names, the sources and trusted scripts this desktop has, then what the picked project needs.
  private func loadTargets() {
    let api = session.api
    Task {
      async let labels = api.sshTargetLabels()
      async let gitlab = api.gitlabAvailable()
      async let linear = try? api.linearAccount()
      async let jira = try? api.jiraAccount()
      async let trusted = api.orcaHookTrust()
      let (sshLabels, gitlabInstalled, linearAccount, jiraAccount, trust) = await (labels, gitlab, linear, jira, trusted)
      self.sshLabels = sshLabels
      self.trust = trust
      availability = WorkspaceSourceAvailability(
        gitlab: gitlabInstalled, linear: linearAccount?.connected == true, jira: jiraAccount?.connected == true,
        linearWorkspaceId: linearAccount?.selectedWorkspaceId, jiraSites: jiraAccount?.sites ?? [],
        jiraSiteId: jiraAccount?.selection)
      tableView.reloadData()
    }
    loadRepoState()
  }

  /// The picked project's agents, setup script and SSH connection.
  private func loadRepoState() {
    loadAgents()
    loadSetup()
    loadSSH()
  }

  private func loadAgents() {
    guard let repo, agentsFor != repo.id, !sshGated else { return }
    agentsFor = repo.id
    let api = session.api
    let repoId = repo.id
    Task {
      async let detectedReply = try? api.automationAgents(repoId: repoId)
      async let policyReply = api.agentLaunchPolicy()
      let (detected, policy) = await (detectedReply, policyReply)
      guard agentsFor == repoId else { return }
      let disabled = policy?.disabled ?? []
      // Detected and turned on, in the official order; a blank terminal is always offered last.
      let available = Self.agentOrder.filter { id in
        !disabled.contains(id) && (detected.map { $0.contains(id) } ?? true)
      }
      agentChoices = available.map(Self.agentChoice) + [.blank]
      // The desktop's quick-create pick: its default when that one is here, else the first one found.
      let preferred: Agent =
        if policy?.defaultAgent == "blank" {
          .blank
        } else if let id = policy?.defaultAgent, available.contains(id) {
          Self.agentChoice(id)
        } else {
          available.first.map(Self.agentChoice) ?? .blank
        }
      if !agentOverridden || !agentChoices.contains(agent) {
        agent = preferred
        agentOverridden = false
      }
      refresh()
    }
  }

  /// use-new-workspace-setup-script.ts: the command, where it comes from and the project's run policy. A script that
  /// asks every time opens Options so the choice is seen.
  private func loadSetup() {
    guard let repo, setupFor != repo.id else { return }
    setupFor = repo.id
    setup = nil
    setupChoice = nil
    runSetup = true
    let api = session.api
    let repoId = repo.id
    Task {
      let hooks = try? await api.setupHooks(repoId: repoId)
      guard setupFor == repoId else { return }
      setup = hooks
      runSetup = hooks?.runPolicy != "skip-by-default"
      if hooks?.command != nil, hooks?.runPolicy == "ask" { optionsOpen = true }
      refresh()
    }
  }

  /// use-new-workspace-execution-target.ts: an SSH project's connection, read when it is picked.
  private func loadSSH() {
    guard let repo else { return }
    guard let targetId = repo.connectionId else {
      ssh = nil
      sshFor = nil
      return
    }
    guard sshFor != targetId else { return }
    sshFor = targetId
    ssh = nil
    let api = session.api
    Task {
      let state: SSHConnectionState
      do {
        state = try await api.sshState(targetId: targetId)
      } catch {
        state = SSHConnectionState(status: "error", error: TasksViewController.message(error))
      }
      guard sshFor == targetId else { return }
      ssh = state
      refresh()
      loadAgents()
    }
  }

  private func connectSSH() {
    guard let targetId = repo?.connectionId, !connecting else { return }
    connecting = true
    ssh = SSHConnectionState(status: "connecting")
    refresh()
    let api = session.api
    Task {
      let state: SSHConnectionState
      do {
        state = try await api.connectSSH(targetId: targetId)
      } catch {
        state = SSHConnectionState(status: "error", error: TasksViewController.message(error))
      }
      connecting = false
      guard sshFor == targetId else { return }
      ssh = state
      refresh()
      loadAgents()
    }
  }

  override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
    (cell as? StartFieldCell)?.unclip()
  }

  // MARK: Footer

  private func makeFooter() -> UIView {
    var configuration = UIButton.Configuration.prominentGlass()
    configuration.baseBackgroundColor = Palette.textPrimary
    configuration.baseForegroundColor = Palette.bgBase
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .systemFont(ofSize: 15, weight: .semibold)
      return attributes
    }
    createButton.configuration = configuration
    createButton.addAction(UIAction { [weak self] _ in self?.create() }, for: .primaryActionTriggered)
    createButton.translatesAutoresizingMaskIntoConstraints = false
    errorLabel.font = .systemFont(ofSize: 13)
    errorLabel.textColor = Palette.statusRed
    errorLabel.numberOfLines = 0
    errorLabel.isHidden = true

    let stack = UIStackView(arrangedSubviews: [errorLabel, createButton])
    stack.axis = .vertical
    stack.spacing = Spacing.md
    stack.isLayoutMarginsRelativeArrangement = true
    stack.directionalLayoutMargins = .init(top: Spacing.xl, leading: Spacing.lg + 4, bottom: Spacing.lg, trailing: Spacing.lg + 4)
    createButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
    let size = stack.systemLayoutSizeFitting(CGSize(width: 390, height: 0))
    stack.frame = CGRect(x: 0, y: 0, width: 0, height: size.height)
    return stack
  }

  // MARK: Create

  /// The request for what the form holds, before its setup is settled.
  private func makeRequest(repo: Repo) -> WorkspaceCreateRequest {
    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    let agentId = agent.id
    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    // A source's own name stands until the user types another (workspace-create-params.ts).
    let auto = nameAutoManaged || typed.isEmpty
    func sourced(_ repoId: String, _ named: (seed: String, display: String), _ source: WorkspaceCreateRequest.Source)
      -> WorkspaceCreateRequest
    {
      WorkspaceCreateRequest(
        repoId: repoId, name: typed.isEmpty ? named.seed : typed, displayName: auto ? named.display : typed,
        nameWasGenerated: auto, source: source, agent: agentId, note: note, base: base)
    }
    switch start {
    case .name:
      // No name typed: a sea creature, as the desktop names one.
      let generated = typed.isEmpty
      let baseName =
        generated ? WorkspaceNames.suggested(taken: session.worktrees.map { ($0.path as NSString).lastPathComponent }) : typed
      return WorkspaceCreateRequest(
        repoId: repo.id, name: baseName, displayName: generated ? nil : typed, nameWasGenerated: generated,
        branchName: branch, agent: agentId, note: note)
    case .workItem(let item):
      return sourced(
        item.repoId, WorkspaceSourceName.hosted(title: item.title, number: item.number, kind: item.kind.rawValue),
        .workItem(item))
    case .gitlab(let item):
      return sourced(
        item.repoId,
        WorkspaceSourceName.hosted(title: item.title, number: item.number, kind: item.kind == .pr ? "mr" : "issue"),
        .gitlab(item))
    case .linear(let issue):
      return sourced(repo.id, WorkspaceSourceName.identified(identifier: issue.identifier, title: issue.title), .linear(issue))
    case .jira(let issue):
      return sourced(repo.id, WorkspaceSourceName.identified(identifier: issue.identifier, title: issue.title), .jira(issue))
    case .branch(let ref):
      return WorkspaceCreateRequest(
        repoId: repo.id, name: typed.isEmpty ? ref.localBranchName : typed, displayName: typed.isEmpty ? nil : typed,
        nameWasGenerated: false, source: .branch(refName: ref.refName), branchName: branch, agent: agentId, note: note)
    case .newBranch(let newBranch):
      return WorkspaceCreateRequest(
        repoId: repo.id, name: branch.isEmpty ? newBranch : branch, displayName: typed.isEmpty ? nil : typed,
        nameWasGenerated: false, source: .newBranch, agent: agentId, note: note)
    }
  }

  /// use-new-workspace-create-submit.ts: connect first, resolve a pull or merge request's head, settle the setup
  /// script (asking when it isn't trusted), then create with retries for a taken name.
  private func create(approval: SetupApproval? = nil) {
    guard let repo, !creating else { return }
    view.endEditing(true)
    if sshGated {
      errorText = "Connect \(repo.displayName) before creating a workspace."
      refresh()
      return
    }
    var decision = approval?.decision ?? "inherit"
    if approval == nil, let setup, setup.command != nil {
      if setup.runPolicy == "ask" {
        guard let setupChoice else {
          errorText = "Choose whether to run the setup script."
          optionsOpen = true
          refresh()
          return
        }
        decision = setupChoice
      } else {
        decision = runSetup ? "run" : "skip"
      }
    }
    creating = true
    errorText = nil
    refresh()
    let api = session.api
    let start = start
    Task {
      do {
        // A pull or merge request starts from its head; resolved now if the pick's read hasn't landed.
        if base == nil {
          switch start {
          case .workItem(let item) where item.kind == .pr:
            base = try? await api.resolvePullRequestBase(repoId: item.repoId, number: item.number)
          case .gitlab(let item) where item.kind == .pr:
            base = try? await api.resolveMergeRequestBase(repoId: item.repoId, iid: item.number)
          default: break
          }
        }
        var request = makeRequest(repo: repo)
        request.setupDecision = decision
        // Setup is checked for the project the create lands in, which a work item may not share.
        guard let setupRepo = session.repos.first(where: { $0.id == request.repoId }) ?? (request.repoId == repo.id ? repo : nil)
        else {
          throw TaskMessage("This item's project isn't available on this host.")
        }
        if let approval {
          request.approvedSetupHash = approval.hash
        } else if needsTrustCheck(sameRepo: setupRepo.id == repo.id, decision: decision) {
          switch try await settleTrust(setupRepo, request: request) {
          case .approved(let hash): request.approvedSetupHash = hash
          case .ask(let prompt):
            creating = false
            refresh()
            askTrust(prompt) { run, alwaysTrust in
              // Repo-wide trust runs whatever comes; a version approval pins what was shown.
              self.navigationController?.popViewController(animated: true)
              self.create(
                approval: SetupApproval(
                  decision: run ? "run" : "skip",
                  hash: run && !(alwaysTrust && !prompt.versionOnly) ? prompt.script.contentHash : nil))
            }
            return
          }
        }
        let result = try await api.createWorkspace(request)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let mismatch = result.setupMismatch {
          // The host skipped setup: the created branch's differs from the one approved. Ask before running it there.
          creating = false
          refresh()
          let prompt = SetupHookTrustViewController.Prompt(
            repoId: setupRepo.id, repoName: setupRepo.displayName, script: mismatch,
            previouslyApproved: trust.wasPreviouslyApproved(repoId: setupRepo.id),
            versionOnly: hostCount(setupRepo.id) > 1, createdBranch: true)
          askTrust(prompt) { run, _ in
            Task {
              // Declining leaves the workspace as it is; either way it opens.
              if run { _ = try? await api.runApprovedSetup(worktreeId: result.worktreeId, contentHash: mismatch.contentHash) }
              await self.finishCreated(result.worktreeId, sent: request.note)
            }
          }
          return
        }
        await finishCreated(result.worktreeId, sent: request.note)
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        creating = false
        errorText = TasksViewController.message(error)
        refresh()
      }
    }
  }

  /// createSetupNeedsTrustCheck: setup that may run is checked; one landing in another project is checked unless
  /// skipped, as the picked project's policy says nothing about it.
  private func needsTrustCheck(sameRepo: Bool, decision: String) -> Bool {
    guard sameRepo else { return decision != "skip" }
    return decision == "run" || (decision == "inherit" && setup?.runPolicy != "skip-by-default")
  }

  private func hostCount(_ repoId: String) -> Int { session.repos.filter { $0.id == repoId }.count }

  private enum TrustOutcome {
    case approved(String?)
    case ask(SetupHookTrustViewController.Prompt)
  }

  /// resolveCreateSetupApproval: trusted projects run without asking; otherwise the setup of the ref the create
  /// checks out is read, and a version not approved before is asked about.
  private func settleTrust(_ setupRepo: Repo, request: WorkspaceCreateRequest) async throws -> TrustOutcome {
    let hosts = hostCount(setupRepo.id)
    // Read again: an approval made on the desktop since the form opened counts.
    trust = await session.api.orcaHookTrust()
    if trust.isRepoTrusted(repoId: setupRepo.id, hostsWithRepo: hosts) { return .approved(nil) }
    let source: SetupCreateSource
    switch request.source {
    case .branch(let refName): source = .base(baseBranch: refName)
    default: source = .base(baseBranch: request.base?.baseBranch)
    }
    let hooks = try await session.api.setupHooks(repoId: setupRepo.id, createSource: source)
    guard let script = hooks.trust else {
      // Approving no shared setup pins empty content, so setup the created branch adds is asked about.
      return .approved(hooks.readsSetupConfig ? OrcaHookTrust.emptyContentHash : nil)
    }
    if trust.isApproved(repoId: setupRepo.id, contentHash: script.contentHash) { return .approved(script.contentHash) }
    return .ask(
      SetupHookTrustViewController.Prompt(
        repoId: setupRepo.id, repoName: setupRepo.displayName, script: script,
        previouslyApproved: trust.wasPreviouslyApproved(repoId: setupRepo.id), versionOnly: hosts > 1,
        createdBranch: false))
  }

  /// Shows the trust prompt. An approval is saved to the desktop (`ui.set`) before `onAnswer` runs; Don't run goes
  /// straight to it. A save that fails returns to the form saying why.
  private func askTrust(
    _ prompt: SetupHookTrustViewController.Prompt, onAnswer: @escaping (_ run: Bool, _ alwaysTrust: Bool) -> Void
  ) {
    let api = session.api
    let controller = SetupHookTrustViewController(prompt: prompt) { [weak self] run, alwaysTrust in
      guard let self else { return }
      guard run else {
        onAnswer(false, false)
        return
      }
      // Run once stores nothing unless the id is on several hosts; Always trust stores repo trust.
      var next = prompt.versionOnly ? self.trust.confirming(repoId: prompt.repoId, contentHash: prompt.script.contentHash) : self.trust
      if alwaysTrust { next = next.alwaysTrusting(repoId: prompt.repoId) }
      Task {
        do {
          if next != self.trust { try await api.saveOrcaHookTrust(next) }
          self.trust = next
          onAnswer(true, alwaysTrust)
        } catch {
          self.errorText = TasksViewController.message(error)
          self.navigationController?.popViewController(animated: true)
          self.refresh()
        }
      }
    }
    push(controller, large: true)
  }

  private func finishCreated(_ worktreeId: String, sent: String?) async {
    // The kept note was sent; one typed since stays.
    if note.trimmingCharacters(in: .whitespacesAndNewlines) == (sent ?? "") { note = "" }
    await session.refresh()
    dismiss(animated: true) { self.onCreated(worktreeId) }
  }

  // MARK: Pickers

  /// The projects, one per project however many hosts it is on.
  private var projects: [Repo] {
    var seen = Set<String>()
    return session.repos.filter { seen.insert($0.projectKey).inserted }
  }

  /// The hosts the picked project is on.
  private var runTargets: [Repo] {
    guard let repo else { return [] }
    var seen = Set<String>()
    return session.repos.filter { $0.projectKey == repo.projectKey && seen.insert($0.connectionId ?? "").inserted }
  }

  /// Named like the host list's badge: the desktop itself by its platform, an SSH target by its name.
  private func runTargetLabel(_ repo: Repo) -> String {
    if let connectionId = repo.connectionId { return sshLabels[connectionId] ?? connectionId }
    switch session.status?.hostPlatform {
    case "darwin": return "Local Mac"
    case "win32": return "Local Windows"
    case "linux": return "Local Linux"
    default: return "This computer"
    }
  }

  private func select(_ next: Repo) {
    guard next.id != repo?.id else { return }
    repo = next
    // A source belongs to its project; a new project starts from a name again.
    clearSource(reload: false)
    loadRepoState()
  }

  private func openProjects() {
    let choices = projects.map { project in
      ChoiceListViewController.Choice(
        title: project.displayName, image: Self.dot(project.badgeColor), selected: project.projectKey == repo?.projectKey)
    }
    let projects = projects
    push(
      ChoiceListViewController(
        title: String(localized: "components.newWorktreeModalDrawers.project", defaultValue: "Project"),
        choices: choices
      ) { [weak self] index in self?.select(projects[index]) })
  }

  private func openRunTargets() {
    let targets = runTargets
    let choices = targets.map { target in
      ChoiceListViewController.Choice(
        title: runTargetLabel(target), subtitle: target.path, image: Self.hostIcon(target), selected: target.id == repo?.id)
    }
    push(
      ChoiceListViewController(
        title: String(localized: "components.newWorktreeModalDrawers.runOn", defaultValue: "Run on"), choices: choices
      ) { [weak self] index in self?.select(targets[index]) })
  }

  private func openAgents() {
    let agents = agentChoices
    let choices = agents.map { choice in
      ChoiceListViewController.Choice(title: choice.title, image: choice.image, selected: choice == agent)
    }
    push(
      ChoiceListViewController(
        title: String(localized: "components.newWorktreeModalDrawers.agent", defaultValue: "Agent"), choices: choices
      ) { [weak self] index in
        self?.agent = agents[index]
        self?.agentOverridden = true
      })
  }

  private func openSource() {
    guard let repo else { return }
    errorText = nil
    let picker = WorkspaceSourcePickerViewController(
      session: session, repo: repo, name: name, availability: availability, repoReady: !sshGated,
      onName: { [weak self] text in
        guard let self else { return }
        self.name = text
        self.nameAutoManaged = false
      },
      onPick: { [weak self] start, seededName in self?.pick(start, seededName: seededName) },
      onSwitchRepo: { [weak self] target, item in
        guard let self else { return }
        self.select(target)
        self.pick(.workItem(item), seededName: WorkspaceSourceName.hosted(title: item.title, number: item.number, kind: item.kind.rawValue).seed)
      })
    push(picker, large: true)
  }

  /// A picked source seeds the name; a pull or merge request's head is read now, so create starts from it.
  private func pick(_ next: WorkspaceStart, seededName: String?) {
    start = next
    if let seededName {
      name = seededName
      nameAutoManaged = next != .name
    }
    base = nil
    baseTask?.cancel()
    let api = session.api
    let read: (() async throws -> WorkspaceCreateRequest.HostedBase?)?
    switch next {
    case .workItem(let item) where item.kind == .pr:
      read = { try await api.resolvePullRequestBase(repoId: item.repoId, number: item.number) }
    case .gitlab(let item) where item.kind == .pr:
      read = { try await api.resolveMergeRequestBase(repoId: item.repoId, iid: item.number) }
    default:
      read = nil
    }
    guard let read else { return }
    baseTask = Task { [weak self] in
      do {
        let resolved = try await read()
        guard !Task.isCancelled, let self, self.start == next else { return }
        self.base = resolved
      } catch {
        guard !Task.isCancelled, let self, self.start == next else { return }
        self.errorText = TasksViewController.message(error)
        self.refresh()
      }
    }
  }

  private func clearSource(reload: Bool = true) {
    if nameAutoManaged { name = "" }
    nameAutoManaged = false
    start = .name
    base = nil
    baseTask?.cancel()
    if reload { refresh() }
  }

  private func push(_ controller: UIViewController, large: Bool = false) {
    view.endEditing(true)
    if large, let sheet = navigationController?.sheetPresentationController {
      sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
    }
    navigationController?.pushViewController(controller, animated: true)
  }

  static func dot(_ hex: String?) -> UIImage {
    let color = hex.flatMap(UIColor.init(cssHex:)) ?? UIColor(hex: 0x737373)
    return UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
      color.setFill()
      UIBezierPath(ovalIn: CGRect(x: 5, y: 5, width: 10, height: 10)).fill()
    }
  }

  static func hostIcon(_ repo: Repo?) -> UIImage {
    (repo?.connectionId == nil ? Lucide.monitor : Lucide.server).image(size: 18)
      .withTintColor(Palette.textMuted, renderingMode: .alwaysOriginal)
  }

  /// tasks.workspaceSshGate labels.
  private static func sshStatusLabel(_ status: String?) -> String {
    switch status {
    case "connected": String(localized: "tasks.workspaceSshGate.connected", defaultValue: "Connected")
    case "connecting": String(localized: "tasks.workspaceSshGate.connecting", defaultValue: "Connecting")
    case "deploying-relay": String(localized: "tasks.workspaceSshGate.deployingRelay", defaultValue: "Deploying relay")
    case "reconnecting": String(localized: "tasks.workspaceSshGate.reconnecting", defaultValue: "Reconnecting")
    case "auth-failed":
      String(localized: "tasks.workspaceSshGate.authenticationFailed", defaultValue: "Authentication failed")
    case "reconnection-failed": String(localized: "tasks.workspaceSshGate.reconnectFailed", defaultValue: "Reconnect failed")
    case "error": String(localized: "tasks.workspaceSshGate.connectionFailed", defaultValue: "Connection failed")
    default: String(localized: "tasks.workspaceSshGate.disconnected", defaultValue: "Disconnected")
    }
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "header") as? FormSectionHeader
    switch sections[section].section {
    case .location:
      header?.show(String(localized: "components.newWorktreeProjectTargetFields.where", defaultValue: "Where"))
    case .ssh:
      header?.show(String(localized: "components.newWorkspaceSshConnectionField.label", defaultValue: "SSH Connection"))
    case .start:
      header?.show(
        isGit
          ? String(localized: "components.newWorktreeFormSheet.startFrom", defaultValue: "Start from")
          : String(localized: "components.newWorktreeFormSheet.workspaceName", defaultValue: "Workspace name"),
        trailing: String(localized: "components.smartWorkspaceSourceField.optionalLabel", defaultValue: "Optional"))
    case .agent:
      header?.show(String(localized: "components.newWorktreeFormSheet.agent", defaultValue: "Agent"))
    case .options:
      header?.show(
        String(localized: "components.newWorktreeFormSheet.options", defaultValue: "Options"), expanded: optionsOpen
      ) { [weak self] in
        guard let self else { return }
        self.optionsOpen.toggle()
        self.tableView.reloadData()
      }
    case .setup:
      header?.show(
        String(localized: "components.newWorkspaceSetupScriptField.label", defaultValue: "Setup script"),
        trailing: setup?.source == "orca.yaml" ? "orca.yaml" : nil)
    }
    return header
  }

  override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    if sections[section].section == .ssh, ssh?.error != nil { return UITableView.automaticDimension }
    return .leastNonzeroMagnitude
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    sections[section].section == .ssh ? ssh?.error : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section].rows[indexPath.row]
    switch row {
    case .start:
      let cell = tableView.dequeueReusableCell(withIdentifier: "start", for: indexPath) as! StartFieldCell
      cell.show(start, name: name, enabled: repo != nil && !sshGated) { [weak self] in self?.clearSource() }
      return cell
    case .name, .branchName, .note:
      let cell = tableView.dequeueReusableCell(withIdentifier: "field", for: indexPath) as! LabeledFieldCell
      switch row {
      case .name:
        cell.show(
          label: String(localized: "components.smartWorkspaceAdvancedFields.name", defaultValue: "Name"),
          placeholder: String(
            localized: "components.smartWorkspaceAdvancedFields.workspaceName", defaultValue: "Workspace name"),
          text: name
        ) { [weak self] text in
          self?.name = text
          self?.nameAutoManaged = false
        }
      case .branchName:
        cell.show(
          label: String(localized: "components.smartWorkspaceAdvancedFields.branchName", defaultValue: "Branch name"),
          placeholder: String(
            localized: "components.smartWorkspaceAdvancedFields.derivedFromName", defaultValue: "Derived from name"),
          text: branchName
        ) { [weak self] text in self?.branchName = text }
      default:
        cell.show(
          label: String(localized: "components.newWorktreeFormSheet.note", defaultValue: "Note"),
          placeholder: String(localized: "components.newWorktreeFormSheet.notePlaceholder", defaultValue: "Write a note"),
          text: note
        ) { [weak self] text in self?.note = text }
      }
      return cell
    default:
      break
    }
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.valueCell()
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    content.secondaryTextProperties.color = Palette.textSecondary
    cell.accessoryType = .disclosureIndicator
    cell.accessoryView = nil
    cell.accessibilityLabel = nil
    var enabled = true
    switch row {
    case .project:
      content.text = String(localized: "components.newWorktreeProjectTargetFields.project", defaultValue: "Project")
      content.secondaryText =
        repo?.displayName
        ?? String(localized: "components.newWorktreeProjectTargetFields.selectProject", defaultValue: "Select a project")
      content.image = repo.map { Self.dot($0.badgeColor) }
    case .runOn:
      content.text = String(localized: "components.newWorktreeProjectTargetFields.runOn", defaultValue: "Run on")
      content.secondaryText =
        repo.map(runTargetLabel)
        ?? String(
          localized: "components.newWorktreeProjectTargetFields.selectRunTarget", defaultValue: "Select a run target")
      content.image = Self.hostIcon(repo)
      // A run target belongs to a project; until one is picked there is nothing to choose.
      enabled = repo != nil
    case .ssh:
      // NewWorkspaceSshConnectionField.tsx: a status dot, the project and its state, and Connect until connected.
      content = .subtitleCell()
      content.text = repo?.displayName
      content.secondaryText = Self.sshStatusLabel(ssh?.status)
      content.secondaryTextProperties.color = Palette.textSecondary
      let dotColor =
        ssh?.isConnected == true ? Palette.statusGreen : (connecting || ssh?.inProgress == true) ? Palette.statusAmber : Palette.textMuted
      content.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in
        dotColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 10, height: 10)).fill()
      }
      content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
      cell.accessoryType = .none
      if ssh?.isConnected != true {
        let busy = connecting || ssh?.inProgress == true
        var configuration = UIButton.Configuration.glass()
        configuration.title =
          busy
          ? String(localized: "components.newWorkspaceSshConnectionField.connecting", defaultValue: "Connecting...")
          : String(localized: "components.newWorkspaceSshConnectionField.connect", defaultValue: "Connect")
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.connectSSH() })
        button.isEnabled = !busy
        button.sizeToFit()
        cell.accessoryView = button
      }
      cell.selectionStyle = .none
      cell.contentConfiguration = content
      return cell
    case .setupRun, .setupSkip:
      // An "ask" project: Run setup (showing the command) or Skip, one checked.
      content = .subtitleCell()
      let isRun = row == .setupRun
      content.text =
        isRun
        ? String(localized: "components.newWorkspaceSetupScriptField.runSetup", defaultValue: "Run setup")
        : String(localized: "components.newWorkspaceSetupScriptField.skip", defaultValue: "Skip")
      content.secondaryText = isRun ? setup?.command : nil
      content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      content.secondaryTextProperties.color = Palette.textSecondary
      cell.accessoryType = setupChoice == (isRun ? "run" : "skip") ? .checkmark : .none
      cell.tintColor = Palette.textPrimary
      cell.contentConfiguration = content
      return cell
    case .setupToggle:
      content = .subtitleCell()
      content.text = String(localized: "components.newWorkspaceSetupScriptField.runSetup", defaultValue: "Run setup")
      content.secondaryText = setup?.command
      content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      content.secondaryTextProperties.color = Palette.textSecondary
      let toggle = UISwitch()
      toggle.isOn = runSetup
      toggle.accessibilityLabel = content.text
      toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.runSetup = toggle?.isOn ?? true }, for: .valueChanged)
      cell.accessoryType = .none
      cell.accessoryView = toggle
      cell.selectionStyle = .none
      cell.contentConfiguration = content
      return cell
    default:
      content.text = agent.title
      content.image = agent.image
      enabled = !sshGated
      cell.accessibilityLabel = "\(String(localized: "components.newWorktreeFormSheet.agent", defaultValue: "Agent")), \(agent.title)"
    }
    content.textProperties.color = enabled ? Palette.textPrimary : Palette.textMuted
    cell.selectionStyle = .default
    cell.contentConfiguration = content
    cell.isUserInteractionEnabled = enabled
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .project: openProjects()
    case .runOn: openRunTargets()
    case .agent: openAgents()
    case .start: if start == .name { openSource() }
    case .setupRun, .setupSkip:
      Haptics.select()
      setupChoice = sections[indexPath.section].rows[indexPath.row] == .setupRun ? "run" : "skip"
      errorText = nil
      refresh()
    default: break
    }
  }
}

extension UISheetPresentationController.Detent.Identifier {
  static let form = Self("form")
}

extension UIColor {
  /// `#rrggbb`, as a project's badge colour is stored.
  convenience init?(cssHex: String) {
    var text = cssHex.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
    self.init(hex: value)
  }
}

/// Where a new workspace starts: a name alone, or a source picked in Start from.
enum WorkspaceStart: Equatable {
  case name
  case workItem(GitHubWorkItem)
  /// A GitLab issue, or a merge request (`.pr`).
  case gitlab(GitHubWorkItem)
  case linear(TrackerIssue)
  case jira(TrackerIssue)
  case branch(BranchRef)
  /// A branch made under the typed name.
  case newBranch(String)

  var title: String {
    switch self {
    case .name: ""
    case .workItem(let item), .gitlab(let item): item.title
    case .linear(let issue), .jira(let issue): "\(issue.identifier) \(issue.title)"
    case .branch(let ref): ref.label
    case .newBranch(let name): name
    }
  }

  var icon: Lucide {
    switch self {
    case .workItem(let item): item.kind == .pr ? .gitPullRequest : .circleDot
    case .gitlab(let item): item.kind == .pr ? .gitMerge : .circleDot
    case .linear: .listTodo
    case .jira: .listChecks
    default: .gitBranch
    }
  }

  /// A title made branch-safe the way the desktop seeds names from one (slugifyForWorkspaceName).
  static func slug(_ input: String) -> String { WorkspaceSourceName.slug(input) }
}

/// A form section's label (components/list/ListGroup.tsx SectionHeader): 13 pt secondary text, with a muted note at
/// the trailing edge, or a chevron when the section folds.
final class FormSectionHeader: UITableViewHeaderFooterView {
  private let title = UILabel()
  private let trailing = UILabel()
  private let chevron = UIImageView()
  private var onToggle: (() -> Void)?

  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.textColor = Palette.textSecondary
    trailing.font = .systemFont(ofSize: 13, weight: .medium)
    trailing.textColor = Palette.textSecondary
    chevron.tintColor = Palette.textSecondary
    chevron.contentMode = .center
    let stack = UIStackView(arrangedSubviews: [title, UIView(), trailing, chevron])
    stack.alignment = .center
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
      stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
    ])
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ text: String, trailing note: String? = nil, expanded: Bool? = nil, onToggle: (() -> Void)? = nil) {
    title.text = text
    trailing.text = note
    trailing.isHidden = note == nil
    chevron.isHidden = expanded == nil
    chevron.image = (expanded == true ? Lucide.chevronUp : Lucide.chevronDown).image(size: 14)
    self.onToggle = onToggle
    accessibilityTraits = onToggle == nil ? .header : [.header, .button]
  }

  @objc private func toggle() { onToggle?() }
}

/// A bordered text box (components/composer-input/TextField.tsx): no fill, an `inputBorder` edge, 44 pt tall.
private final class BorderedBox: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = Radius.control
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (box: BorderedBox, _) in box.updateBorder() }
    updateBorder()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func updateBorder() {
    layer.borderColor = Palette.inputBorder.resolvedColor(with: traitCollection).cgColor
  }
}

/// Start from: a bordered field that opens the source picker, or the picked source with a button to clear it.
private final class StartFieldCell: UITableViewCell {
  private let box = BorderedBox()
  private let placeholder = UILabel()
  private let selection = UIStackView()
  private let icon = UIImageView()
  private let title = UILabel()
  private let clear = UIButton(type: .system)
  private var onClear: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    // The grouped list rounds and clips every cell to its section's large corners, which would cut the
    // bordered field's own corners off; the bare field keeps its corners.
    if !box.isHidden { unclip() }
  }

  func unclip() {
    for layer in [layer, contentView.layer] {
      layer.cornerRadius = 0
      layer.mask = nil
      layer.masksToBounds = false
    }
  }

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    box.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(box)
    placeholder.font = .systemFont(ofSize: 16)
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(placeholder)

    icon.tintColor = Palette.textSecondary
    icon.contentMode = .center
    title.font = .systemFont(ofSize: 17)
    title.textColor = Palette.textPrimary
    clear.setImage(Lucide.x.image(size: 17), for: .normal)
    clear.tintColor = Palette.textSecondary
    clear.accessibilityLabel = String(
      localized: "components.smartWorkspaceSourceField.clearSelectedSource", defaultValue: "Clear selected source")
    clear.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .primaryActionTriggered)
    selection.addArrangedSubview(icon)
    selection.addArrangedSubview(title)
    selection.addArrangedSubview(clear)
    selection.spacing = Spacing.md
    selection.alignment = .center
    selection.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(selection)
    NSLayoutConstraint.activate([
      box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      box.topAnchor.constraint(equalTo: contentView.topAnchor),
      box.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      box.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
      placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Spacing.md + 4),
      placeholder.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Spacing.md),
      placeholder.centerYAnchor.constraint(equalTo: box.centerYAnchor),
      selection.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      selection.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor, constant: Spacing.sm),
      selection.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 22),
      clear.widthAnchor.constraint(equalToConstant: 36),
      clear.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ start: WorkspaceStart, name: String, enabled: Bool, onClear: @escaping () -> Void) {
    self.onClear = onClear
    let picked = start != .name
    box.isHidden = picked
    selection.isHidden = !picked
    // The field has no group behind it, only its border; a picked source sits in a row like the others.
    backgroundConfiguration = picked ? .listGroupedCell() : .clear()
    selectionStyle = picked ? .none : .default
    placeholder.text =
      name.isEmpty
      ? String(
        localized: "components.smartWorkspaceSourceField.searchPlaceholder", defaultValue: "Type a name or search a source")
      : name
    placeholder.textColor = name.isEmpty ? Palette.textMuted : Palette.textPrimary
    box.alpha = enabled ? 1 : Feedback.disabledOpacity
    icon.image = start.icon.image(size: 18)
    title.text = start.title
    accessibilityLabel =
      picked ? start.title : String(localized: "components.newWorktreeFormSheet.startFrom", defaultValue: "Start from")
    accessibilityValue = picked ? nil : name
    accessibilityTraits = picked ? .staticText : .button
  }
}

/// An option's own label above its bordered field (forms/NewWorktreeFormOptions.tsx).
private final class LabeledFieldCell: UITableViewCell, UITextFieldDelegate {
  private let label = UILabel()
  private let box = BorderedBox()
  private let field = UITextField()
  private var onChange: ((String) -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundConfiguration = .clear()
    selectionStyle = .none
    label.font = .systemFont(ofSize: 13)
    label.textColor = Palette.textSecondary
    label.translatesAutoresizingMaskIntoConstraints = false
    field.font = .systemFont(ofSize: 16)
    field.textColor = Palette.textPrimary
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.returnKeyType = .done
    field.clearButtonMode = .whileEditing
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.addAction(UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged)
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(field)
    contentView.addSubview(label)
    contentView.addSubview(box)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.md),
      label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.xs),
      box.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
      box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      box.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.sm),
      box.heightAnchor.constraint(equalToConstant: 44),
      field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Spacing.md),
      field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Spacing.sm),
      field.topAnchor.constraint(equalTo: box.topAnchor),
      field.bottomAnchor.constraint(equalTo: box.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(label text: String, placeholder: String, text value: String, onChange: @escaping (String) -> Void) {
    label.text = text
    field.placeholder = placeholder
    field.text = value
    field.accessibilityLabel = text
    self.onChange = onChange
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }
}


/// A picker drawer's list (components/sheets/PickerListDrawer.tsx): a title, the choices, a check on the current one.
/// Picking one returns to the form.
final class ChoiceListViewController: UITableViewController {
  struct Choice {
    var title: String
    var subtitle: String? = nil
    var image: UIImage? = nil
    var selected: Bool
  }

  private let choices: [Choice]
  private let onPick: (Int) -> Void

  init(title: String, choices: [Choice], onPick: @escaping (Int) -> Void) {
    self.choices = choices
    self.onPick = onPick
    super.init(style: .insetGrouped)
    self.title = title
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "choice")
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let choice = choices[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "choice", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = choice.title
    content.secondaryText = choice.subtitle
    content.secondaryTextProperties.color = Palette.textSecondary
    content.image = choice.image
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    cell.contentConfiguration = content
    cell.accessoryType = choice.selected ? .checkmark : .none
    cell.tintColor = Palette.textPrimary
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    onPick(indexPath.row)
    navigationController?.popViewController(animated: true)
  }
}
