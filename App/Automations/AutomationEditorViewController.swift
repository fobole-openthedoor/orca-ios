import OrcaCore
import UIKit

/// New / edit automation (automations/AutomationEditor.tsx), on the Automations page under the host's name: three
/// steps, Task (name, instructions, where it runs, the agent and advanced options), Schedule
/// (AutomationScheduleFields.tsx) and Review (AutomationDraftReview.tsx), then Create automation / Save changes.
final class AutomationEditorViewController: UIViewController {
  private enum Cadence: String, CaseIterable {
    case hourly, daily, weekdays, weekly, custom

    var title: String {
      switch self {
      case .hourly: String(localized: "automations.mobile.hourly", defaultValue: "Hourly")
      case .daily: String(localized: "automations.mobile.daily", defaultValue: "Daily")
      case .weekdays: String(localized: "automations.mobile.weekdays", defaultValue: "Weekdays")
      case .weekly: String(localized: "automations.mobile.weekly", defaultValue: "Weekly")
      case .custom: String(localized: "automations.mobile.customCronOrRRULE", defaultValue: "Custom cron or RRULE")
      }
    }
  }

  /// A cron or RRULE read back into the preset it is (describeAutomationSchedule); anything else is custom.
  private struct Schedule {
    var cadence = Cadence.custom
    var hour = 9
    var minute = 0
    /// 0 = Sunday … 6 = Saturday.
    var day = 1

    init(parsing expression: String) {
      let trimmed = expression.trimmingCharacters(in: .whitespaces)
      let fields = trimmed.split(separator: " ").map(String.init)
      if fields.count == 5, let m = Int(fields[0]), (0...59).contains(m), fields[2] == "*", fields[3] == "*" {
        minute = m
        if fields[1] == "*", fields[4] == "*" {
          cadence = .hourly
          return
        }
        guard let h = Int(fields[1]), (0...23).contains(h) else { return }
        hour = h
        switch fields[4] {
        case "*": cadence = .daily
        case "1-5": cadence = .weekdays
        case let d where Int(d).map({ (0...6).contains($0) }) == true:
          cadence = .weekly
          day = Int(d)!
        default: break
        }
        return
      }
      var parts: [String: String] = [:]
      for part in trimmed.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
        let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2 { parts[pair[0].uppercased()] = pair[1].uppercased() }
      }
      let days = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
      guard let freq = parts["FREQ"], let m = parts["BYMINUTE"].flatMap({ Int($0) }) else { return }
      minute = m
      if freq == "HOURLY" {
        cadence = .hourly
        return
      }
      guard let h = parts["BYHOUR"].flatMap({ Int($0) }) else { return }
      hour = h
      if freq == "DAILY" {
        cadence = parts["BYDAY"] == "MO,TU,WE,TH,FR" ? .weekdays : parts["BYDAY"] == nil ? .daily : .custom
      } else if freq == "WEEKLY", let byDay = parts["BYDAY"] {
        if byDay == "MO,TU,WE,TH,FR" {
          cadence = .weekdays
        } else if let index = days.firstIndex(of: byDay) {
          cadence = .weekly
          day = index
        }
      }
    }

    /// The schedule's words (automation-schedule-label.ts formatAutomationSchedule).
    static func label(_ expression: String) -> String {
      let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return String(localized: "auto.components.automations.automation.schedule.label.086a5a9fe2", defaultValue: "Invalid schedule")
      }
      let schedule = Schedule(parsing: trimmed)
      let formatter = DateFormatter()
      formatter.setLocalizedDateFormatFromTemplate("jmm")
      var components = DateComponents(year: 2024, month: 1, day: 1, hour: schedule.hour, minute: schedule.minute)
      components.calendar = Calendar(identifier: .gregorian)
      let time = components.date.map(formatter.string) ?? ""
      switch schedule.cadence {
      case .custom: return trimmed
      case .hourly:
        return String(
          format: String(localized: "auto.components.automations.automation.schedule.label.a95afb7483", defaultValue: "Hourly at :%1$@"),
          String(format: "%02d", schedule.minute))
      case .daily:
        return String(
          format: String(localized: "auto.components.automations.automation.schedule.label.280ccd2701", defaultValue: "Daily at %1$@"),
          time)
      case .weekdays:
        return String(
          format: String(localized: "auto.components.automations.automation.schedule.label.3f1422adc1", defaultValue: "Weekdays at %1$@"),
          time)
      case .weekly:
        return String(
          format: String(localized: "auto.components.automations.automation.schedule.label.cc71e252ba", defaultValue: "%1$@s at %2$@"),
          AutomationEditorViewController.weekdays[schedule.day], time)
      }
    }
  }

  /// Sunday first, as the official Day picker lists them.
  private static let weekdays = DateFormatter().standaloneWeekdaySymbols ?? []
  private static let maxPrecheckTimeout = 600

  /// The agent ids the official picker orders by (TUI_AGENT_AUTO_PICK_ORDER), with their names.
  private static let agentOrder = [
    "claude", "claude-agent-teams", "openclaude", "codex", "grok", "copilot", "opencode2", "opencode", "mimo-code", "ante",
    "trae", "muse", "dsh", "qoder", "qoder-cn", "zcode", "pi", "omp", "prime-agent", "gemini", "antigravity", "aider",
    "goose", "amp", "kilo", "kiro", "crush", "aug", "autohand", "cline", "codebuff", "freebuff", "command-code",
    "continue", "cursor", "droid", "kimi", "mistral-vibe", "qwen-code", "rovo", "hermes", "devin", "openclaw",
    "codebuddy", "jcode",
  ]
  private static let agentNames: [String: String] = [
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

  private let session: HostSession
  private let automation: Automation?
  private let onSaved: () -> Void

  private var targets: AutomationTargets?
  private var loadError: String?
  private var agents: [String] = []
  private var agentsLoading = false
  private var agentsFor: String?
  private var busy = false
  private var step = 1
  private var advanced = false
  private var error: String?

  private var draft: AutomationDraft
  private var original: AutomationDraft
  /// The saved automation's schedule fields, which a step-2 check leaves alone when untouched.
  private var saved: (rrule: String, timezone: String, grace: String, precheck: String, timeout: String)?
  // The schedule step's own state; `draft.rrule` is what it builds.
  private var cadence: Cadence
  private var time: String
  private var day: Int

  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let body = UIStackView()
  private let stepLabel = TextLabel(size: Typography.metaSize, color: Palette.textSecondary, lineHeight: 18)
  private let errorLabel = TextLabel(size: Typography.bodySize, color: Palette.statusRed, lineHeight: 21, lines: 0)
  private let cancelButton = AutomationButton()
  private let navigation = UIStackView()
  // Text fields live across rebuilds so focus and typing survive a step's redraw.
  private lazy var nameField = field(text: draft.name, onChange: change { $0.name = $1 })
  private lazy var promptField = field(text: draft.prompt, multiline: true, onChange: change { $0.prompt = $1 })
  // These two redraw the step as they are typed in (the timeout appears, the time's error shows).
  private lazy var precheckField = field(text: draft.precheckCommand, literal: true) { [weak self] text in
    guard let self else { return }
    let shown = !self.draft.precheckCommand.isEmpty
    self.draft.precheckCommand = text
    // The timeout shows once there is a command.
    if shown != !text.isEmpty { self.rebuild() }
  }
  private lazy var timeField = field(text: time, literal: true) { [weak self] text in
    guard let self else { return }
    let wasValid = self.validTime
    self.time = text
    self.updateSchedule()
    if wasValid != self.validTime { self.rebuild() }
  }

  init(session: HostSession, automation: Automation?, onSaved: @escaping () -> Void) {
    self.session = session
    self.automation = automation
    self.onSaved = onSaved
    let rrule = automation?.rrule ?? "0 9 * * 1-5"
    draft = AutomationDraft(
      name: automation?.name ?? "", prompt: automation?.prompt ?? "", agentId: automation?.agentId ?? "",
      rrule: rrule, timezone: TimeZone.current.identifier, setup: nil, workspaceMode: "new_per_run", workspaceId: nil)
    original = draft
    let schedule = Schedule(parsing: rrule)
    cadence = schedule.cadence
    time = String(format: "%02d:%02d", schedule.hour, schedule.minute)
    day = schedule.day
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    title = String(localized: "automations.mobile.automations", defaultValue: "Automations")
    navigationItem.subtitle = session.name
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.backAction = UIAction { [weak self] _ in self?.cancel() }
    if automation != nil {
      // The official page's detail actions, for the automation being edited.
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        image: Lucide.ellipsis.image(size: 20), menu: UIMenu(children: [
          UIAction(title: String(localized: "automations.mobile.runNow", defaultValue: "Run now"), image: Lucide.play.image(size: 18)) {
            [weak self] _ in self?.runNow()
          },
          UIAction(
            title: String(localized: "automations.mobile.deleteAutomation", defaultValue: "Delete automation"),
            image: Lucide.trash2.image(size: 18), attributes: .destructive
          ) { [weak self] _ in self?.confirmDelete() },
        ]))
    }

    scroll.keyboardDismissMode = .interactive
    scroll.alwaysBounceVertical = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
    ])

    // New automation / Edit automation, with Cancel beside it (AutomationEditorHeader).
    let heading = TextLabel(
      automation == nil
        ? String(localized: "automations.mobile.newAutomation", defaultValue: "New automation")
        : String(localized: "automations.mobile.editAutomation", defaultValue: "Edit automation"),
      size: Typography.titleSize, weight: .semibold)
    cancelButton.label = String(localized: "automations.mobile.cancel", defaultValue: "Cancel")
    cancelButton.onPress = { [weak self] in self?.cancel() }
    let header = UIStackView(arrangedSubviews: [heading, cancelButton])
    header.alignment = .center
    header.spacing = Spacing.md
    heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
    body.axis = .vertical
    body.spacing = Spacing.sm
    navigation.spacing = Spacing.md
    for view in [header, stepLabel, errorLabel, body, navigation] as [UIView] { stack.addArrangedSubview(view) }

    rebuild()
    load()
  }

  // MARK: Loading

  private func load() {
    loadError = nil
    rebuild()
    Task {
      do {
        async let targetsReply = session.api.automationTargets()
        var detail: AutomationDetail?
        if let automation { detail = try await session.api.automationDetail(automation) }
        let targets = try await targetsReply
        self.targets = targets
        applyInitialTarget(targets, detail: detail)
      } catch {
        loadError = Self.message(error)
      }
      rebuild()
      loadAgents()
    }
  }

  private func applyInitialTarget(_ targets: AutomationTargets, detail: AutomationDetail?) {
    if let detail {
      draft.apply(detail)
      if let setupId = detail.setupId {
        draft.setup = targets.setups.first { $0.id == setupId && $0.hostId == detail.hostId && $0.path == detail.path }
      } else {
        // Saved before run contexts: the project's one setup, when it has exactly one.
        let matches = targets.setups.filter { $0.repoId == detail.projectId }
        draft.setup = matches.count == 1 ? matches.first : nil
      }
      saved = (draft.rrule, draft.timezone, draft.grace, draft.precheckCommand, draft.precheckTimeout)
    } else {
      draft.setup = targets.setups.first { !$0.hostId.hasPrefix("runtime:") }
      if draft.setup?.isFolder == true { draft.workspaceMode = "existing" }
    }
    original = draft
  }

  private func loadAgents() {
    guard let setup = draft.setup, setup.hostId == "local" else {
      agents = []
      agentsLoading = false
      agentsFor = nil
      rebuild()
      return
    }
    guard agentsFor != setup.repoId else { return }
    agentsFor = setup.repoId
    agentsLoading = true
    rebuild()
    let repoId = setup.repoId
    Task {
      async let detectedReply = session.api.automationAgents(repoId: repoId)
      let policy = await session.api.agentLaunchPolicy()
      let detected = Set((try? await detectedReply) ?? [])
      guard agentsFor == repoId else { return }
      var ordered = Self.agentOrder.filter { detected.contains($0) && !(policy?.disabled.contains($0) ?? false) }
      if let preferred = policy?.defaultAgent, let index = ordered.firstIndex(of: preferred) {
        ordered.insert(ordered.remove(at: index), at: 0)
      }
      agents = ordered
      agentsLoading = false
      // The default agent is part of the untouched form, not an edit to ask about.
      if draft.agentId.isEmpty, let first = ordered.first {
        draft.agentId = first
        if original.agentId.isEmpty { original.agentId = first }
      }
      rebuild()
    }
  }

  // MARK: Drawing

  /// Redraws the step: its fields, the error and the Back / Continue row.
  private func rebuild() {
    guard isViewLoaded else { return }
    let section =
      step == 1
      ? String(localized: "automations.mobile.task", defaultValue: "Task")
      : step == 2
        ? String(localized: "automations.mobile.schedule", defaultValue: "Schedule")
        : String(localized: "automations.mobile.review", defaultValue: "Review")
    stepLabel.text = String(
      format: String(localized: "automations.mobile.editorStep", defaultValue: "%1$@ of 3 · %2$@"), "\(step)", section)
    errorLabel.text = error ?? loadError
    errorLabel.isHidden = errorLabel.text == nil
    cancelButton.isEnabled = !busy

    // Taking a field out of the page drops its focus; one that comes back gets it again.
    let focused = [nameField, promptField, precheckField, timeField].first {
      $0.textField.isFirstResponder || $0.textView.isFirstResponder
    }
    for view in body.arrangedSubviews { view.removeFromSuperview() }
    defer {
      if let focused, focused.window != nil { focused.focus() }
    }
    var views: [UIView] = []
    if loadError != nil, targets == nil {
      views.append(
        button(String(localized: "automations.mobile.retryProjectLoading", defaultValue: "Retry project loading")) {
          [weak self] in self?.load()
        })
    } else if targets == nil {
      views.append(meta(String(localized: "automations.mobile.loadingProjects", defaultValue: "Loading projects…")))
    }
    switch step {
    case 1: views += taskFields()
    case 2: views += scheduleFields()
    default: views.append(review())
    }
    for view in views { body.addArrangedSubview(view) }

    for view in navigation.arrangedSubviews { view.removeFromSuperview() }
    if step > 1 {
      let back = button(String(localized: "automations.mobile.back", defaultValue: "Back")) { [weak self] in
        guard let self else { return }
        self.step -= 1
        self.error = nil
        self.rebuild()
      }
      back.isEnabled = !busy
      navigation.addArrangedSubview(back)
    }
    let next = AutomationButton(primary: true)
    next.label =
      step < 3
      ? String(localized: "automations.mobile.continue", defaultValue: "Continue")
      : automation != nil
        ? String(localized: "automations.mobile.saveChanges", defaultValue: "Save changes")
        : String(localized: "automations.mobile.createAutomation", defaultValue: "Create automation")
    next.onPress = { [weak self] in self?.next() }
    next.isEnabled = !disabled && !agentsLoading
    navigation.addArrangedSubview(next)
    next.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  private var disabled: Bool { busy || targets == nil }

  private func taskFields() -> [UIView] {
    for field in [nameField, promptField, precheckField, timeField] { field.isEnabled = !disabled }
    var views: [UIView] = [
      labeled(String(localized: "automations.mobile.name", defaultValue: "Name"), nameField),
      labeled(String(localized: "automations.mobile.instructions", defaultValue: "Instructions"), promptField),
    ]
    let setups = targets?.setups.filter { !$0.hostId.hasPrefix("runtime:") } ?? []
    var setupOptions = setups.map { setup in
      Choice(title: setup.label, subtitle: "\(setup.displayName) · \(setup.path)", selected: setup == draft.setup) {
        [weak self] in self?.selectSetup(setup)
      }
    }
    if draft.setup == nil, automation != nil {
      setupOptions.append(
        Choice(
          title: String(localized: "automations.mobile.savedTarget", defaultValue: "Saved target"), subtitle: nil,
          selected: true) {})
    }
    views.append(
      choice(
        String(localized: "automations.mobile.projectAndHostSetup", defaultValue: "Project and host setup"),
        setupOptions, enabled: !disabled))
    views.append(
      choice(
        String(localized: "automations.mobile.workspace", defaultValue: "Workspace"),
        [
          Choice(
            title: String(localized: "automations.mobile.newWorkspacePerRun", defaultValue: "New workspace per run"),
            selected: draft.workspaceMode == "new_per_run", enabled: draft.setup?.isFolder != true
          ) { [weak self] in self?.selectWorkspaceMode("new_per_run") },
          Choice(
            title: String(localized: "automations.mobile.useAnExistingWorkspace", defaultValue: "Use an existing workspace"),
            selected: draft.workspaceMode == "existing"
          ) { [weak self] in self?.selectWorkspaceMode("existing") },
        ], enabled: !disabled))
    if draft.workspaceMode == "existing" {
      let workspaces = session.worktrees.filter { !$0.isArchived && $0.repoId == draft.setup?.repoId }
      var options = workspaces.map { workspace in
        Choice(
          title: workspace.displayName.isEmpty ? workspace.path : workspace.displayName, subtitle: workspace.path,
          selected: workspace.id == draft.workspaceId
        ) { [weak self] in
          self?.draft.workspaceId = workspace.id
          self?.edited()
        }
      }
      if let id = draft.workspaceId, automation != nil, !workspaces.contains(where: { $0.id == id }) {
        options.append(
          Choice(
            title: String(localized: "automations.mobile.savedWorkspace", defaultValue: "Saved workspace"), subtitle: id,
            selected: true) {})
      }
      views.append(
        choice(
          String(localized: "automations.mobile.existingWorkspace", defaultValue: "Existing workspace"), options,
          enabled: !disabled))
    }
    views.append(agentChoice())
    if draft.setup != nil, !agentsLoading, agents.isEmpty, automation == nil {
      views.append(
        meta(
          String(
            localized: "automations.mobile.installAndEnableAnAgentOnThisHostThenRetry",
            defaultValue: "Install and enable an agent on this host, then retry.")))
    }
    views.append(
      button(
        advanced
          ? String(localized: "automations.mobile.hideAdvancedOptions", defaultValue: "Hide advanced options")
          : String(localized: "automations.mobile.advancedOptions", defaultValue: "Advanced options")
      ) { [weak self] in
        guard let self else { return }
        self.advanced.toggle()
        self.rebuild()
      })
    if advanced { views += advancedFields() }
    return views
  }

  private func agentChoice() -> UIView {
    var ids = agents
    var labels: [String: String] = [:]
    if !draft.agentId.isEmpty, !ids.contains(draft.agentId) {
      ids.insert(draft.agentId, at: 0)
      labels[draft.agentId] = String(
        format: String(localized: "automations.mobile.savedAgent", defaultValue: "%1$@ (saved)"), Self.agentName(draft.agentId))
    }
    return choice(
      agentsLoading
        ? String(localized: "automations.mobile.agentDetecting", defaultValue: "Agent · detecting…")
        : String(localized: "automations.mobile.agent", defaultValue: "Agent"),
      ids.map { id in
        Choice(title: labels[id] ?? Self.agentName(id), selected: id == draft.agentId) { [weak self] in
          self?.draft.agentId = id
          self?.edited()
        }
      }, enabled: !disabled && !agentsLoading)
  }

  /// AutomationAdvancedFields.tsx.
  private func advancedFields() -> [UIView] {
    var views: [UIView] = []
    if draft.workspaceMode == "new_per_run" {
      views.append(
        labeled(
          String(localized: "automations.mobile.baseBranchOptional", defaultValue: "Base branch (optional)"),
          field(text: draft.baseBranch, literal: true, onChange: change { $0.baseBranch = $1 })))
    }
    let decisions = [
      ("inherit", String(localized: "automations.mobile.useProjectSettings", defaultValue: "Use project settings")),
      ("run", String(localized: "automations.mobile.runSetupScript", defaultValue: "Run setup script")),
      ("skip", String(localized: "automations.mobile.skipSetupScript", defaultValue: "Skip setup script")),
    ]
    views.append(
      choice(
        String(localized: "automations.mobile.workspaceSetupScript", defaultValue: "Workspace setup script"),
        decisions.map { value, title in
          Choice(title: title, selected: draft.setupDecision == value) { [weak self] in
            self?.draft.setupDecision = value
            self?.edited()
          }
        }, enabled: !disabled))
    if draft.workspaceMode == "existing" {
      let title = String(localized: "automations.mobile.reuseAgentSession", defaultValue: "Reuse agent session")
      let toggle = UISwitch()
      toggle.isOn = draft.reuseSession
      toggle.isEnabled = !disabled
      toggle.accessibilityLabel = title
      toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.draft.reuseSession = toggle?.isOn ?? false }, for: .valueChanged)
      let label = TextLabel(title, size: Typography.bodySize, lineHeight: 21)
      label.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let row = UIStackView(arrangedSubviews: [label, toggle])
      row.alignment = .center
      row.spacing = Spacing.md
      views.append(row)
    }
    let extraArgs = field(text: draft.extraAgentArgs, literal: true, onChange: change { $0.extraAgentArgs = $1 })
    // An older host strips the arguments and would run without them.
    extraArgs.isEnabled = !disabled && (session.status?.supports("automations.extra-agent-args.v1") ?? false)
    views.append(
      labeled(String(localized: "automations.mobile.extraAgentArguments", defaultValue: "Extra agent arguments"), extraArgs))
    views.append(
      labeled(
        String(localized: "automations.mobile.precheckCommandOptional", defaultValue: "Precheck command (optional)"),
        precheckField))
    if !draft.precheckCommand.isEmpty {
      views.append(
        labeled(
          String(localized: "automations.mobile.precheckTimeoutSeconds", defaultValue: "Precheck timeout (seconds)"),
          field(text: draft.precheckTimeout, numeric: true, onChange: change { $0.precheckTimeout = $1 })))
    }
    views.append(
      labeled(
        String(localized: "automations.mobile.missedRunGraceMinutes", defaultValue: "Missed-run grace (minutes)"),
        field(text: draft.grace, numeric: true, onChange: change { $0.grace = $1 })))
    return views
  }

  /// AutomationScheduleFields.tsx.
  private func scheduleFields() -> [UIView] {
    var views: [UIView] = [
      choice(
        String(localized: "automations.mobile.cadence", defaultValue: "Cadence"),
        Cadence.allCases.map { cadence in
          Choice(title: cadence.title, selected: cadence == self.cadence) { [weak self] in
            guard let self else { return }
            self.cadence = cadence
            self.updateSchedule()
            self.rebuild()
          }
        }, enabled: !disabled)
    ]
    if cadence == .custom {
      views.append(
        labeled(
          String(localized: "automations.mobile.cronOrRRULE", defaultValue: "Cron or RRULE"),
          field(text: draft.rrule, literal: true, onChange: change { $0.rrule = $1 })))
    } else {
      views.append(
        labeled(
          cadence == .hourly
            ? String(localized: "automations.mobile.minuteFromHHMM", defaultValue: "Minute (from HH:MM)")
            : String(localized: "automations.mobile.timeHHMM24Hour", defaultValue: "Time (HH:MM, 24 hour)"),
          timeField))
      if !validTime {
        views.append(
          TextLabel(
            String(localized: "automations.mobile.useATimeSuchAs0900", defaultValue: "Use a time such as 09:00."),
            size: Typography.bodySize, color: Palette.statusRed, lineHeight: 21, lines: 0))
      }
      if cadence == .weekly {
        views.append(
          choice(
            String(localized: "automations.mobile.day", defaultValue: "Day"),
            Self.weekdays.enumerated().map { index, name in
              Choice(title: name, selected: index == day) { [weak self] in
                self?.day = index
                self?.updateSchedule()
                self?.rebuild()
              }
            }, enabled: !disabled))
      }
    }
    views.append(
      labeled(
        String(localized: "automations.mobile.timeZone", defaultValue: "Time zone"),
        field(text: draft.timezone, literal: true, onChange: change { $0.timezone = $1 })))
    let summary = meta("\(Schedule.label(draft.rrule)) · \(draft.timezone)")
    summary.tag = 1
    views.append(summary)
    views.append(
      meta(
        String(
          localized: "automations.mobile.runsOnTheSelectedHostKeepThatHostAvailableAtTheScheduledTime",
          defaultValue: "Runs on the selected host. Keep that host available at the scheduled time.")))
    return views
  }

  private var validTime: Bool { time.range(of: "^(?:[01]\\d|2[0-3]):[0-5]\\d$", options: .regularExpression) != nil }

  /// The preset's cron (buildAutomationCronSchedule); a time that doesn't read empties it.
  private func updateSchedule() {
    guard cadence != .custom else { return }
    guard validTime else {
      draft.rrule = ""
      return refreshSummary()
    }
    let parts = time.split(separator: ":").compactMap { Int($0) }
    let (hour, minute) = (parts[0], parts[1])
    switch cadence {
    case .hourly: draft.rrule = "\(minute) * * * *"
    case .daily: draft.rrule = "\(minute) \(hour) * * *"
    case .weekdays: draft.rrule = "\(minute) \(hour) * * 1-5"
    case .weekly: draft.rrule = "\(minute) \(hour) * * \(day)"
    case .custom: break
    }
    refreshSummary()
  }

  private func refreshSummary() {
    (body.viewWithTag(1) as? TextLabel)?.text = "\(Schedule.label(draft.rrule)) · \(draft.timezone)"
  }

  /// AutomationDraftReview.tsx: the draft as it will be saved.
  private func review() -> UIView {
    let card = UIStackView()
    card.axis = .vertical
    card.spacing = Spacing.md
    card.isLayoutMarginsRelativeArrangement = true
    card.directionalLayoutMargins = .init(top: Spacing.lg, leading: Spacing.lg, bottom: Spacing.lg, trailing: Spacing.lg)
    card.backgroundColor = Palette.bgPanel
    card.layer.cornerRadius = 16
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1
    card.layer.borderColor = Palette.borderSubtle.resolvedColor(with: traitCollection).cgColor
    card.addArrangedSubview(TextLabel(draft.name, size: Typography.titleSize, weight: .semibold, lines: 0))
    let workspace: String
    if draft.workspaceMode == "existing" {
      let match = session.worktrees.first { $0.id == draft.workspaceId }
      workspace = match.map { $0.displayName.isEmpty ? $0.path : $0.displayName } ?? draft.workspaceId ?? ""
    } else {
      workspace = String(localized: "automations.mobile.newWorkspacePerRun", defaultValue: "New workspace per run")
    }
    let rows = [
      (String(localized: "automations.mobile.instructions", defaultValue: "Instructions"), draft.prompt),
      (
        String(localized: "automations.mobile.agent", defaultValue: "Agent"),
        draft.agentId.isEmpty
          ? String(localized: "automations.mobile.chooseAnAgent", defaultValue: "Choose an agent") : Self.agentName(draft.agentId)
      ),
      (
        String(localized: "automations.mobile.project", defaultValue: "Project"),
        draft.setup.map { "\($0.label) · \($0.path)" }
          ?? String(localized: "automations.mobile.savedTarget", defaultValue: "Saved target")
      ),
      (String(localized: "automations.mobile.workspace", defaultValue: "Workspace"), workspace),
      (
        String(localized: "automations.mobile.schedule", defaultValue: "Schedule"),
        "\(Schedule.label(draft.rrule)) · \(draft.timezone)"
      ),
    ]
    for (label, value) in rows {
      let pair = UIStackView(arrangedSubviews: [
        meta(label), TextLabel(value, size: Typography.bodySize, lineHeight: 21, lines: 0),
      ])
      pair.axis = .vertical
      pair.spacing = Spacing.sm
      card.addArrangedSubview(pair)
    }
    return card
  }

  // MARK: Controls

  private struct Choice {
    var title: String
    var subtitle: String? = nil
    var selected: Bool
    var enabled = true
    var action: () -> Void
  }

  /// A label over a full-width button whose menu picks one (AutomationChoice).
  private func choice(_ label: String, _ options: [Choice], enabled: Bool) -> UIView {
    let button = AutomationButton()
    button.label = options.first(where: \.selected)?.title
      ?? String(localized: "automations.mobile.choose", defaultValue: "Choose…")
    button.menu = UIMenu(
      title: label,
      children: options.map { option in
        let action = UIAction(title: option.title, subtitle: option.subtitle, state: option.selected ? .on : .off) { _ in
          option.action()
        }
        if !option.enabled { action.attributes = .disabled }
        return action
      })
    button.isEnabled = enabled && !options.isEmpty
    return labeled(label, button)
  }

  private func labeled(_ label: String, _ control: UIView) -> UIView {
    let stack = UIStackView(arrangedSubviews: [meta(label), control])
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    control.accessibilityLabel = control.accessibilityLabel ?? label
    return stack
  }

  private func meta(_ text: String) -> TextLabel {
    TextLabel(text, size: Typography.metaSize, color: Palette.textSecondary, lineHeight: 18, lines: 0)
  }

  private func button(_ title: String, action: @escaping () -> Void) -> AutomationButton {
    let button = AutomationButton()
    button.label = title
    button.onPress = action
    return button
  }

  /// A text field (AutomationField); literal and numeric ones are typed as written, without corrections.
  private func field(
    text: String, multiline: Bool = false, literal: Bool = false, numeric: Bool = false,
    onChange: @escaping (String) -> Void
  ) -> OutlinedField {
    let field = OutlinedField(multiline: multiline, fontSize: Typography.bodySize, minHeight: multiline ? 120 : 44)
    field.text = text
    field.onChange = onChange
    field.isEnabled = !disabled
    if literal || numeric { field.typeAsWritten() }
    if numeric { field.textField.keyboardType = .numberPad }
    return field
  }

  /// A typed edit, without redrawing the step under the keyboard.
  private func change(_ apply: @escaping (inout AutomationDraft, String) -> Void) -> (String) -> Void {
    { [weak self] text in
      guard let self else { return }
      apply(&self.draft, text)
      if self.error != nil {
        self.error = nil
        self.errorLabel.isHidden = self.loadError == nil
        self.errorLabel.text = self.loadError
      }
      if self.step == 2 { self.refreshSummary() }
    }
  }

  private func edited() {
    error = nil
    rebuild()
  }

  private func selectSetup(_ setup: AutomationSetup) {
    draft.setup = setup
    draft.workspaceId = nil
    if setup.isFolder { draft.workspaceMode = "existing" }
    draft.reuseSession = false
    draft.agentId = ""
    edited()
    loadAgents()
  }

  private func selectWorkspaceMode(_ mode: String) {
    draft.workspaceMode = mode
    draft.reuseSession = false
    if mode == "new_per_run" { draft.workspaceId = nil }
    edited()
  }

  // MARK: Steps, save, run, delete

  /// The official checks for the steps so far, in its words (validateAutomationDraft); nil when it can go on.
  private func validation() -> String? {
    if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.agentId.isEmpty
    {
      return String(
        localized: "automations.mobile.addANameInstructionsAndAnAgent", defaultValue: "Add a name, instructions and an agent.")
    }
    if draft.workspaceMode == "existing", draft.workspaceId == nil {
      return String(localized: "automations.mobile.chooseAnExistingWorkspace", defaultValue: "Choose an existing workspace.")
    }
    guard step >= 2 else { return nil }
    if draft.rrule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.rrule != saved?.rrule {
      return String(localized: "automations.mobile.enterAValidCronOrRRULESchedule", defaultValue: "Enter a valid cron or RRULE schedule.")
    }
    if draft.timezone != saved?.timezone, TimeZone(identifier: draft.timezone) == nil {
      return String(
        localized: "automations.mobile.enterAValidTimeZoneSuchAsAmericaLosAngeles",
        defaultValue: "Enter a valid time zone, such as America/Los_Angeles.")
    }
    if draft.grace != saved?.grace, (Int(draft.grace.trimmingCharacters(in: .whitespaces)) ?? -1) < 0 {
      return String(
        localized: "automations.mobile.missedRunGraceMustBeZeroOrAPositiveNumberOfMinutes",
        defaultValue: "Missed-run grace must be zero or a positive number of minutes.")
    }
    if draft.precheckCommand != (saved?.precheck ?? "") || draft.precheckTimeout != (saved?.timeout ?? "60"),
      !draft.precheckCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !(1...Self.maxPrecheckTimeout).contains(Int(draft.precheckTimeout) ?? 0)
    {
      return String(
        format: String(
          localized: "automations.mobile.precheckTimeoutRange",
          defaultValue: "Precheck timeout must be between 1 and %1$@ seconds."),
        "\(Self.maxPrecheckTimeout)")
    }
    return nil
  }

  private func next() {
    view.endEditing(true)
    if let problem = validation() {
      error = problem
      return rebuild()
    }
    if targets == nil || (automation == nil && draft.setup == nil) {
      error = String(
        localized: "automations.mobile.chooseAProjectSetUpOnThisHost", defaultValue: "Choose a project set up on this host.")
      return rebuild()
    }
    error = nil
    if step < 3 {
      step += 1
      rebuild()
      scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
    } else {
      save()
    }
  }

  private func save() {
    guard let targets else { return }
    setBusy(true)
    Task {
      do {
        if let automation {
          try await session.api.updateAutomation(automation, draft: draft, original: original, targets: targets)
        } else {
          try await session.api.createAutomation(draft, targets: targets)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        original = draft
        onSaved()
        navigationController?.popViewController(animated: true)
      } catch {
        setBusy(false)
        self.error = Self.message(error)
        rebuild()
      }
    }
  }

  private func runNow() {
    guard let automation else { return }
    setBusy(true)
    Task {
      do {
        try await session.api.runAutomationNow(automation)
        setBusy(false)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSaved()
      } catch {
        setBusy(false)
        self.error = Self.message(error)
        rebuild()
      }
    }
  }

  private func confirmDelete() {
    guard let automation else { return }
    let alert = UIAlertController(
      title: String(localized: "common.delete", defaultValue: "Delete"),
      message: String(
        format: String(localized: "automations.mobile.deleteRetained", defaultValue: "Delete “%1$@” and its retained runs?"),
        automation.name),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "common.delete", defaultValue: "Delete"), style: .destructive) { [weak self] _ in
        self?.delete(automation)
      })
    present(alert, animated: true)
  }

  private func delete(_ automation: Automation) {
    setBusy(true)
    Task {
      do {
        try await session.api.deleteAutomation(automation)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        original = draft
        onSaved()
        navigationController?.popViewController(animated: true)
      } catch {
        setBusy(false)
        self.error = Self.message(error)
        rebuild()
      }
    }
  }

  private func setBusy(_ busy: Bool) {
    self.busy = busy
    navigationItem.rightBarButtonItem?.isEnabled = !busy
    rebuild()
  }

  /// Cancel and Back leave, once the owner agrees to drop unsaved edits (useAutomationLeaveGuard).
  private func cancel() {
    view.endEditing(true)
    guard !busy else { return }
    guard draft != original else {
      navigationController?.popViewController(animated: true)
      return
    }
    let alert = UIAlertController(
      title: String(localized: "automations.mobile.discardChangesTitle", defaultValue: "Discard changes?"),
      message: String(
        localized: "automations.mobile.discardChangesMessage", defaultValue: "Unsaved edits to this automation will be lost."),
      preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: String(localized: "automations.mobile.keepEditing", defaultValue: "Keep editing"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "automations.mobile.discard", defaultValue: "Discard"), style: .destructive) {
        [weak self] _ in self?.navigationController?.popViewController(animated: true)
      })
    present(alert, animated: true)
  }

  private static func agentName(_ id: String) -> String { agentNames[id] ?? id }

  private static func message(_ error: Error) -> String {
    if let error = error as? RPCError { return error.message }
    if error as? AutomationEditError == .unknownDestination {
      return String(
        localized: "orcaios.automation.sshHostUnknown",
        defaultValue: "This project’s SSH host isn’t available on the desktop. Pick another project.")
    }
    if error is ConnectionError {
      return String(
        localized: "automations.mobile.hostUnreachable",
        defaultValue: "Could not reach this host. Reconnect, then refresh to check its current state.")
    }
    return String(
      localized: "automations.mobile.actionFailed", defaultValue: "Could not complete this action on the host. Refresh and try again.")
  }
}

/// The automation page's button (AutomationControls.tsx AutomationButton): bgRaised, 12 pt corners, 44 pt tall,
/// a centred 14 pt semibold label; the primary one is textPrimary with bgBase text. With a menu it picks.
private final class AutomationButton: UIButton {
  var label = "" { didSet { configuration?.attributedTitle = AttributedString(label, attributes: titleAttributes) } }
  var onPress: (() -> Void)?
  private let primary: Bool

  private var titleAttributes: AttributeContainer {
    AttributeContainer([
      .font: UIFont.systemFont(ofSize: Typography.bodySize, weight: .semibold),
      .foregroundColor: primary ? Palette.bgBase : Palette.textPrimary,
    ])
  }

  override var menu: UIMenu? {
    didSet { showsMenuAsPrimaryAction = menu != nil }
  }

  override var isEnabled: Bool {
    didSet { alpha = isEnabled ? 1 : 0.45 }
  }

  init(primary: Bool = false) {
    self.primary = primary
    super.init(frame: .zero)
    var configuration = UIButton.Configuration.plain()
    configuration.background.backgroundColor = primary ? Palette.textPrimary : Palette.bgRaised
    configuration.background.cornerRadius = 12
    configuration.contentInsets = .init(top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg)
    configuration.titleLineBreakMode = .byTruncatingTail
    self.configuration = configuration
    configurationUpdateHandler = { button in
      button.alpha = !button.isEnabled ? 0.45 : button.isHighlighted ? Feedback.pressedOpacity : 1
    }
    heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .primaryActionTriggered)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
