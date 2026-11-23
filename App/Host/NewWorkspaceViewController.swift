import OrcaCore
import UIKit

/// Create worktree (new-workspace/creation/forms/NewWorktreeFormSheet.tsx): where it goes (project and the host it
/// runs on), what it starts from (a name, or an issue, pull request or branch), the agent that starts in it, and
/// folded options. The button at the bottom makes it on this desktop and opens it.
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

  private enum Section { case location, start, agent, options }
  private enum Row { case project, runOn, start, agent, name, branchName, note }

  private let session: HostSession
  private let onCreated: (String) -> Void
  private var repo: Repo?
  private var sshLabels: [String: String] = [:]
  /// Until the host says which agents it has, the form offers the first one, as the official form does.
  private var agent = NewWorkspaceViewController.agentChoice("claude")
  private var agentChoices: [Agent] = [NewWorkspaceViewController.agentChoice("claude"), .blank]
  private var agentOverridden = false
  private var agentsFor: String?

  private var start: WorkspaceStart = .name
  /// The workspace name: typed, or seeded by the source picked.
  private var name = ""
  /// The name came from the picked source and changes with it.
  private var nameAutoManaged = false
  private var branchName = ""
  private var note = ""
  private var optionsOpen = false
  private var creating = false
  private var errorText: String?

  private let createButton = UIButton(configuration: .prominentGlass())
  private let errorLabel = UILabel()

  init(session: HostSession, projects: [Repo], onCreated: @escaping (String) -> Void) {
    self.session = session
    self.onCreated = onCreated
    // The caller's pick of projects only chooses where the form opens; the picker lists every project.
    repo = projects.first ?? session.repos.first
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

  private var formTitle: String {
    isGit
      ? String(localized: "components.newWorktreeFormSheet.createWorktree", defaultValue: "Create worktree")
      : String(localized: "components.newWorktreeFormSheet.createWorkspace", defaultValue: "Create workspace")
  }

  private var sections: [(section: Section, rows: [Row])] {
    var options: [Row] = []
    if optionsOpen {
      if start != .name { options.append(.name) }
      if isGit {
        switch start {
        case .name, .branch, .newBranch: options.append(.branchName)
        case .workItem: break
        }
      }
      options.append(.note)
    }
    return [(.location, [.project, .runOn]), (.start, [.start]), (.agent, [.agent]), (.options, options)]
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

  /// The SSH targets' names, then the agents the picked project's host has.
  private func loadTargets() {
    let api = session.api
    Task {
      sshLabels = await api.sshTargetLabels()
      tableView.reloadData()
    }
    loadAgents()
  }

  private func loadAgents() {
    guard let repo, agentsFor != repo.id else { return }
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

  private func create() {
    guard let repo, !creating else { return }
    view.endEditing(true)
    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let request: WorkspaceCreateRequest
    let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    let agentId = agent.id
    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    switch start {
    case .name:
      // No name typed: a sea creature, as the desktop names one.
      let generated = typed.isEmpty
      let baseName =
        generated ? WorkspaceNames.suggested(taken: session.worktrees.map { ($0.path as NSString).lastPathComponent }) : typed
      request = WorkspaceCreateRequest(
        repoId: repo.id, name: baseName, displayName: generated ? nil : typed, nameWasGenerated: generated,
        branchName: branch, agent: agentId, note: note)
    case .workItem(let item):
      let seed = WorkspaceStart.slug(item.title)
      let fallback = "\(item.kind == .pr ? "pr" : "issue")-\(item.number)"
      let auto = nameAutoManaged || typed.isEmpty
      request = WorkspaceCreateRequest(
        repoId: item.repoId, name: typed.isEmpty ? (seed.isEmpty ? fallback : seed) : typed,
        displayName: auto ? item.title : typed, nameWasGenerated: auto, source: .workItem(item), agent: agentId,
        note: note)
    case .branch(let ref):
      request = WorkspaceCreateRequest(
        repoId: repo.id, name: typed.isEmpty ? ref.localBranchName : typed, displayName: typed.isEmpty ? nil : typed,
        nameWasGenerated: false, source: .branch(refName: ref.refName), branchName: branch, agent: agentId, note: note)
    case .newBranch(let newBranch):
      request = WorkspaceCreateRequest(
        repoId: repo.id, name: typed.isEmpty ? newBranch : typed, displayName: typed.isEmpty ? newBranch : typed,
        nameWasGenerated: false, branchName: branch.isEmpty ? newBranch : branch, agent: agentId, note: note)
    }
    creating = true
    errorText = nil
    refresh()
    let api = session.api
    Task {
      do {
        guard let id = try await api.createWorkspace(request) else { throw CancellationError() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await session.refresh()
        dismiss(animated: true) { self.onCreated(id) }
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        creating = false
        errorText = TasksViewController.message(error)
        refresh()
      }
    }
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
    if start != .name {
      start = .name
      if nameAutoManaged { name = "" }
      nameAutoManaged = false
    }
    loadAgents()
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
      session: session, repo: repo, name: name,
      onName: { [weak self] text in
        guard let self else { return }
        self.name = text
        self.nameAutoManaged = false
      },
      onPick: { [weak self] start, seededName in
        guard let self else { return }
        self.start = start
        if let seededName {
          self.name = seededName
          self.nameAutoManaged = start != .name
        }
      })
    push(picker, large: true)
  }

  private func clearSource() {
    if nameAutoManaged { name = "" }
    nameAutoManaged = false
    start = .name
    refresh()
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
        self.tableView.reloadSections([section], with: .automatic)
      }
    }
    return header
  }

  override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNonzeroMagnitude }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section].rows[indexPath.row]
    switch row {
    case .start:
      let cell = tableView.dequeueReusableCell(withIdentifier: "start", for: indexPath) as! StartFieldCell
      cell.show(start, name: name, enabled: repo != nil) { [weak self] in self?.clearSource() }
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
    default:
      content.text = agent.title
      content.image = agent.image
      cell.accessibilityLabel = "\(String(localized: "components.newWorktreeFormSheet.agent", defaultValue: "Agent")), \(agent.title)"
    }
    content.textProperties.color = enabled ? Palette.textPrimary : Palette.textMuted
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
  case branch(BranchRef)
  /// A branch made under the typed name.
  case newBranch(String)

  var title: String {
    switch self {
    case .name: ""
    case .workItem(let item): item.title
    case .branch(let ref): ref.label
    case .newBranch(let name): name
    }
  }

  var icon: Lucide {
    switch self {
    case .workItem(let item): item.kind == .pr ? .gitPullRequest : .circleDot
    default: .gitBranch
    }
  }

  /// A title made branch-safe the way the desktop seeds names from one (slugifyForWorkspaceName).
  static func slug(_ input: String) -> String {
    var text = input.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces).lowercased()
    text = text.replacingOccurrences(of: "[\\\\/\\s]+", with: "-", options: .regularExpression)
    text = text.replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
    text = text.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)
    text = text.replacingOccurrences(of: "^[.-]+|[.-]+$", with: "", options: .regularExpression)
    text = String(text.prefix(48))
    return text.replacingOccurrences(of: "[-._]+$", with: "", options: .regularExpression)
  }
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
