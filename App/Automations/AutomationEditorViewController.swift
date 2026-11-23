import OrcaCore
import UIKit

/// New / edit automation (automations/AutomationEditor.tsx and AutomationScheduleFields.tsx) on one page:
/// name and instructions, the agent, where it runs, the schedule, and on/off. An existing automation can also
/// be run now or deleted.
final class AutomationEditorViewController: SettingsPageViewController {
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

  /// The schedule fields the cadence presets edit; `custom` keeps the typed expression.
  private struct Schedule: Equatable {
    var cadence = Cadence.weekdays
    var hour = 9
    var minute = 0
    /// 0 = Sunday … 6 = Saturday.
    var day = 1
    var custom = ""

    /// The cron the official editor writes for a preset (buildAutomationCronSchedule).
    var rrule: String {
      switch cadence {
      case .hourly: "\(minute) * * * *"
      case .daily: "\(minute) \(hour) * * *"
      case .weekdays: "\(minute) \(hour) * * 1-5"
      case .weekly: "\(minute) \(hour) * * \(day)"
      case .custom: custom.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    /// Reads a saved cron or RRULE back into a preset; anything else stays custom.
    init(parsing expression: String = "0 9 * * 1-5") {
      custom = expression
      let trimmed = expression.trimmingCharacters(in: .whitespaces)
      let fields = trimmed.split(separator: " ").map(String.init)
      if fields.count == 5, let m = Int(fields[0]), (0...59).contains(m), fields[2] == "*", fields[3] == "*" {
        minute = m
        if fields[1] == "*", fields[4] == "*" {
          cadence = .hourly
          return
        }
        guard let h = Int(fields[1]), (0...23).contains(h) else { cadence = .custom; return }
        hour = h
        switch fields[4] {
        case "*": cadence = .daily
        case "1-5": cadence = .weekdays
        case let d where Int(d).map({ (0...6).contains($0) }) == true:
          cadence = .weekly
          day = Int(d)!
        default: cadence = .custom
        }
        return
      }
      var parts: [String: String] = [:]
      for part in trimmed.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
        let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2 { parts[pair[0].uppercased()] = pair[1].uppercased() }
      }
      let days = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
      guard let freq = parts["FREQ"], let m = parts["BYMINUTE"].flatMap({ Int($0) }) else {
        cadence = .custom
        return
      }
      minute = m
      if freq == "HOURLY" {
        cadence = .hourly
        return
      }
      guard let h = parts["BYHOUR"].flatMap({ Int($0) }) else { cadence = .custom; return }
      hour = h
      if freq == "DAILY" {
        cadence = parts["BYDAY"] == "MO,TU,WE,TH,FR" ? .weekdays : parts["BYDAY"] == nil ? .daily : .custom
      } else if freq == "WEEKLY", let byDay = parts["BYDAY"] {
        if byDay == "MO,TU,WE,TH,FR" {
          cadence = .weekdays
        } else if let index = days.firstIndex(of: byDay) {
          cadence = .weekly
          day = index
        } else {
          cadence = .custom
        }
      } else {
        cadence = .custom
      }
    }
  }

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

  private var draft: AutomationDraft
  private var original: AutomationDraft
  private var schedule: Schedule
  private var originalSchedule: Schedule

  private let nameCell = TextInputCell(multiline: false)
  private let promptCell = TextInputCell(multiline: true)
  private let customCell = TextInputCell(multiline: false)
  private let timeCell = UITableViewCell(style: .default, reuseIdentifier: nil)
  private let timePicker = UIDatePicker()
  private lazy var saveButton = UIBarButtonItem(
    title: automation == nil
      ? String(localized: "automations.mobile.createAutomation", defaultValue: "Create automation")
      : String(localized: "common.save", defaultValue: "Save"),
    style: .prominent, target: self, action: #selector(save))

  init(session: HostSession, automation: Automation?, onSaved: @escaping () -> Void) {
    self.session = session
    self.automation = automation
    self.onSaved = onSaved
    let schedule = Schedule(parsing: automation?.rrule ?? "0 9 * * 1-5")
    self.schedule = schedule
    originalSchedule = schedule
    draft = AutomationDraft(
      name: automation?.name ?? "", prompt: automation?.prompt ?? "", agentId: automation?.agentId ?? "",
      rrule: schedule.rrule, timezone: TimeZone.current.identifier, enabled: automation?.enabled ?? true, setup: nil,
      workspaceMode: "new_per_run", workspaceId: nil)
    original = draft
    super.init()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title =
      automation == nil
      ? String(localized: "automations.mobile.newAutomation", defaultValue: "New automation")
      : String(localized: "automations.mobile.editAutomation", defaultValue: "Edit automation")
    tableView.keyboardDismissMode = .interactive
    navigationItem.rightBarButtonItem = saveButton
    if navigationController?.viewControllers.first === self {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        title: String(localized: "automations.mobile.cancel", defaultValue: "Cancel"), style: .plain, target: self,
        action: #selector(cancel))
    }
    navigationController?.presentationController?.delegate = self

    nameCell.configure(
      placeholder: String(localized: "automations.mobile.name", defaultValue: "Name"), text: draft.name
    ) { [weak self] text in
      self?.draft.name = text
      self?.updateState()
    }
    promptCell.configure(
      placeholder: String(localized: "automations.mobile.instructions", defaultValue: "Instructions"), text: draft.prompt
    ) { [weak self] text in
      guard let self else { return }
      self.draft.prompt = text
      self.updateState()
      UIView.performWithoutAnimation { self.tableView.performBatchUpdates(nil) }
    }
    customCell.configure(
      placeholder: String(localized: "automations.mobile.cronOrRRULE", defaultValue: "Cron or RRULE"),
      text: schedule.custom, literal: true
    ) { [weak self] text in
      self?.schedule.custom = text
      self?.updateState()
    }

    timePicker.datePickerMode = .time
    timePicker.preferredDatePickerStyle = .compact
    timePicker.addAction(UIAction { [weak self] _ in self?.timeChanged() }, for: .valueChanged)
    var content = UIListContentConfiguration.valueCell()
    content.text = String(localized: "automations.botTarget.time", defaultValue: "Time")
    timeCell.contentConfiguration = content
    timeCell.accessoryView = timePicker
    timeCell.selectionStyle = .none
    timeCell.backgroundColor = Palette.bgRaised

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
    let usable = targets.setups.filter { !$0.hostId.hasPrefix("runtime:") }
    if let detail {
      draft.timezone = detail.timezone
      draft.workspaceMode = detail.workspaceMode
      draft.workspaceId = detail.workspaceId
      if let setupId = detail.setupId {
        draft.setup = targets.setups.first { $0.id == setupId && $0.hostId == detail.hostId && $0.path == detail.path }
      } else {
        // Saved before run contexts: the project's one setup, when it has exactly one.
        let matches = targets.setups.filter { $0.repoId == detail.projectId }
        draft.setup = matches.count == 1 ? matches.first : nil
      }
    } else {
      draft.setup = usable.first
      if draft.setup?.isFolder == true { draft.workspaceMode = "existing" }
    }
    original = draft
    original.rrule = draft.rrule
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
      // The first agent is the untouched form's choice, not an edit.
      if draft.agentId.isEmpty, let first = ordered.first {
        draft.agentId = first
        if original.agentId.isEmpty { original.agentId = first }
      }
      rebuild()
    }
  }

  // MARK: Rows

  private func rebuild() {
    draft.rrule = schedule.rrule
    var sections: [Section] = [
      Section(
        header: String(localized: "automations.mobile.task", defaultValue: "Task"),
        rows: [.custom(nameCell), .custom(promptCell)])
    ]
    if let loadError {
      sections.append(
        Section(
          footer: loadError,
          rows: [
            .button(title: String(localized: "automations.mobile.retryProjectLoading", defaultValue: "Retry project loading")) {
              [weak self] in self?.load()
            }
          ]))
    } else if targets == nil {
      sections.append(
        Section(rows: [.spinner(String(localized: "automations.mobile.loadingProjects", defaultValue: "Loading projects…"))]))
    } else {
      sections.append(targetSection())
    }
    sections.append(scheduleSection())
    sections.append(
      Section(rows: [
        .toggle(
          title: String(localized: "orcaios.automation.enabled", defaultValue: "Enabled"), isOn: draft.enabled,
          enabled: !busy
        ) { [weak self] on in
          self?.draft.enabled = on
          self?.updateState()
        }
      ]))
    if automation != nil {
      sections.append(
        Section(rows: [
          .button(title: String(localized: "automations.mobile.runNow", defaultValue: "Run now"), enabled: !busy) {
            [weak self] in self?.runNow()
          },
          .button(
            title: String(localized: "automations.mobile.deleteAutomation", defaultValue: "Delete automation"),
            destructive: true, enabled: !busy
          ) { [weak self] in self?.confirmDelete() },
        ]))
    }
    self.sections = sections
    updateState()
  }

  private func targetSection() -> Section {
    guard let targets else { return Section(rows: []) }
    let setups = targets.setups.filter { !$0.hostId.hasPrefix("runtime:") }
    var setupOptions = setups.map { setup in
      Option(title: setup.label, subtitle: "\(setup.displayName) · \(setup.path)", selected: setup == draft.setup) {
        [weak self] in self?.selectSetup(setup)
      }
    }
    if draft.setup == nil, automation != nil {
      setupOptions.append(
        Option(title: String(localized: "automations.mobile.savedTarget", defaultValue: "Saved target"), selected: true) {})
    }
    let setupValue =
      draft.setup?.label
      ?? (automation != nil
        ? String(localized: "automations.mobile.savedTarget", defaultValue: "Saved target")
        : String(localized: "automations.mobile.choose", defaultValue: "Choose…"))
    var rows: [Row] = [
      .menu(
        icon: .folder, title: String(localized: "automations.mobile.project", defaultValue: "Project"), value: setupValue,
        options: setupOptions, enabled: !busy),
      .menu(
        icon: .layers, title: String(localized: "automations.mobile.workspace", defaultValue: "Workspace"),
        value: draft.workspaceMode == "existing"
          ? String(localized: "automations.mobile.useAnExistingWorkspace", defaultValue: "Use an existing workspace")
          : String(localized: "automations.mobile.newWorkspacePerRun", defaultValue: "New workspace per run"),
        options: [
          Option(
            title: String(localized: "automations.mobile.newWorkspacePerRun", defaultValue: "New workspace per run"),
            selected: draft.workspaceMode == "new_per_run", enabled: draft.setup?.isFolder != true
          ) { [weak self] in self?.selectWorkspaceMode("new_per_run") },
          Option(
            title: String(localized: "automations.mobile.useAnExistingWorkspace", defaultValue: "Use an existing workspace"),
            selected: draft.workspaceMode == "existing"
          ) { [weak self] in self?.selectWorkspaceMode("existing") },
        ], enabled: !busy),
    ]
    if draft.workspaceMode == "existing" {
      let workspaces = session.worktrees.filter { !$0.isArchived && $0.repoId == draft.setup?.repoId }
      var options = workspaces.map { workspace in
        Option(
          title: workspace.displayName.isEmpty ? workspace.path : workspace.displayName, subtitle: workspace.path,
          selected: workspace.id == draft.workspaceId
        ) { [weak self] in
          self?.draft.workspaceId = workspace.id
          self?.rebuild()
        }
      }
      let savedMissing = draft.workspaceId.map { id in !workspaces.contains { $0.id == id } } ?? false
      if savedMissing, let id = draft.workspaceId {
        options.append(
          Option(
            title: String(localized: "automations.mobile.savedWorkspace", defaultValue: "Saved workspace"), subtitle: id,
            selected: true) {})
      }
      let selected = workspaces.first { $0.id == draft.workspaceId }
      rows.append(
        .menu(
          icon: .folderGit2,
          title: String(localized: "automations.mobile.existingWorkspace", defaultValue: "Existing workspace"),
          value: selected.map { $0.displayName.isEmpty ? $0.path : $0.displayName }
            ?? (savedMissing
              ? String(localized: "automations.mobile.savedWorkspace", defaultValue: "Saved workspace")
              : String(localized: "automations.mobile.choose", defaultValue: "Choose…")),
          options: options, enabled: !busy && !options.isEmpty))
    }
    rows.append(agentRow())
    var footer: String?
    if draft.setup != nil, !agentsLoading, agents.isEmpty, automation == nil {
      footer = String(
        localized: "automations.mobile.installAndEnableAnAgentOnThisHostThenRetry",
        defaultValue: "Install and enable an agent on this host, then retry.")
    } else if setups.isEmpty {
      footer = String(
        localized: "automations.mobile.chooseAProjectSetUpOnThisHost", defaultValue: "Choose a project set up on this host.")
    }
    return Section(
      header: String(localized: "automations.mobile.projectAndHostSetup", defaultValue: "Project and host setup"),
      footer: footer, rows: rows)
  }

  private func agentRow() -> Row {
    let title =
      agentsLoading
      ? String(localized: "automations.mobile.agentDetecting", defaultValue: "Agent · detecting…")
      : String(localized: "automations.mobile.agent", defaultValue: "Agent")
    var ids = agents
    var labels: [String: String] = [:]
    if !draft.agentId.isEmpty, !ids.contains(draft.agentId) {
      ids.insert(draft.agentId, at: 0)
      labels[draft.agentId] = String(
        format: String(localized: "automations.mobile.savedAgent", defaultValue: "%1$@ (saved)"), Self.agentName(draft.agentId))
    }
    let options = ids.map { id in
      Option(title: labels[id] ?? Self.agentName(id), selected: id == draft.agentId) { [weak self] in
        self?.draft.agentId = id
        self?.rebuild()
      }
    }
    return .menu(
      icon: .bot, title: title,
      value: draft.agentId.isEmpty
        ? String(localized: "automations.mobile.chooseAnAgent", defaultValue: "Choose an agent")
        : labels[draft.agentId] ?? Self.agentName(draft.agentId),
      options: options, enabled: !busy && !agentsLoading && !options.isEmpty)
  }

  private func scheduleSection() -> Section {
    var rows: [Row] = [
      .menu(
        icon: .calendarClock, title: String(localized: "automations.mobile.cadence", defaultValue: "Cadence"),
        value: schedule.cadence.title,
        options: Cadence.allCases.map { cadence in
          Option(title: cadence.title, selected: cadence == schedule.cadence) { [weak self] in
            guard let self else { return }
            if cadence == .custom, self.schedule.cadence != .custom {
              // Start the custom field from the preset it replaces.
              self.schedule.custom = self.schedule.rrule
              self.customCell.text = self.schedule.custom
            }
            self.schedule.cadence = cadence
            self.rebuild()
          }
        }, enabled: !busy)
    ]
    switch schedule.cadence {
    case .custom:
      rows.append(.custom(customCell))
    case .hourly:
      let minutes = Array(Set(stride(from: 0, to: 60, by: 5)).union([schedule.minute])).sorted()
      rows.append(
        .menu(
          title: String(localized: "automations.botTarget.minute", defaultValue: "Minute"),
          value: String(format: ":%02d", schedule.minute),
          options: minutes.map { minute in
            Option(title: String(format: ":%02d", minute), selected: minute == schedule.minute) { [weak self] in
              self?.schedule.minute = minute
              self?.rebuild()
            }
          }, enabled: !busy))
    case .daily, .weekdays, .weekly:
      var components = DateComponents()
      components.hour = schedule.hour
      components.minute = schedule.minute
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      timePicker.timeZone = timeZone
      if let date = calendar.nextDate(after: Date(timeIntervalSince1970: 0), matching: components, matchingPolicy: .nextTime) {
        timePicker.setDate(date, animated: false)
      }
      timePicker.isEnabled = !busy
      rows.append(.custom(timeCell))
      if schedule.cadence == .weekly {
        let formatter = DateFormatter()
        let names = formatter.standaloneWeekdaySymbols ?? []
        rows.append(
          .menu(
            title: String(localized: "automations.mobile.day", defaultValue: "Day"),
            value: names.indices.contains(schedule.day) ? names[schedule.day] : "\(schedule.day)",
            options: names.enumerated().map { index, name in
              Option(title: name, selected: index == schedule.day) { [weak self] in
                self?.schedule.day = index
                self?.rebuild()
              }
            }, enabled: !busy))
      }
    }
    rows.append(.value(title: String(localized: "automations.mobile.timeZone", defaultValue: "Time zone"), value: draft.timezone))
    return Section(
      header: String(localized: "automations.mobile.schedule", defaultValue: "Schedule"),
      footer: String(
        localized: "automations.mobile.runsOnTheSelectedHostKeepThatHostAvailableAtTheScheduledTime",
        defaultValue: "Runs on the selected host. Keep that host available at the scheduled time."),
      rows: rows)
  }

  private var timeZone: TimeZone { TimeZone(identifier: draft.timezone) ?? .current }

  private func timeChanged() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.hour, .minute], from: timePicker.date)
    schedule.hour = parts.hour ?? schedule.hour
    schedule.minute = parts.minute ?? schedule.minute
    draft.rrule = schedule.rrule
    updateState()
  }

  private func selectSetup(_ setup: AutomationSetup) {
    draft.setup = setup
    draft.workspaceId = nil
    if setup.isFolder { draft.workspaceMode = "existing" }
    if automation == nil { draft.agentId = "" }
    loadAgents()
    rebuild()
  }

  private func selectWorkspaceMode(_ mode: String) {
    draft.workspaceMode = mode
    if mode == "new_per_run" { draft.workspaceId = nil }
    rebuild()
  }

  // MARK: Save, run, delete

  private var dirty: Bool {
    var current = draft
    current.rrule = schedule.rrule
    return current != original || schedule.rrule != originalSchedule.rrule
  }

  private func updateState() {
    draft.rrule = schedule.rrule
    saveButton.isEnabled = !busy && targets != nil && (automation == nil || dirty)
    isModalInPresentation = dirty || busy
    navigationController?.isModalInPresentation = dirty || busy
  }

  /// The official checks, in its words; nil when the draft can be saved.
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
    if automation == nil, draft.setup == nil {
      return String(
        localized: "automations.mobile.chooseAProjectSetUpOnThisHost", defaultValue: "Choose a project set up on this host.")
    }
    if schedule.rrule.isEmpty {
      return String(localized: "automations.mobile.enterAValidCronOrRRULESchedule", defaultValue: "Enter a valid cron or RRULE schedule.")
    }
    return nil
  }

  @objc private func save() {
    view.endEditing(true)
    draft.rrule = schedule.rrule
    if let problem = validation() {
      showAlert(title: String(localized: "orcaios.automation.saveFailed", defaultValue: "Couldn’t save the automation"), message: problem)
      return
    }
    guard let targets else { return }
    setBusy(true)
    Task {
      do {
        if let automation {
          var before = original
          before.rrule = originalSchedule.rrule
          try await session.api.updateAutomation(automation, draft: draft, original: before, targets: targets)
        } else {
          try await session.api.createAutomation(draft, targets: targets)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSaved()
        close()
      } catch {
        setBusy(false)
        showAlert(
          title: String(localized: "orcaios.automation.saveFailed", defaultValue: "Couldn’t save the automation"),
          message: Self.message(error))
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
        showAlert(
          title: String(localized: "automations.mobile.runNow", defaultValue: "Run now"),
          message: String(localized: "orcaios.automation.runStarted", defaultValue: "The run started on the desktop."))
        onSaved()
      } catch {
        setBusy(false)
        showAlert(
          title: String(localized: "orcaios.automation.runFailed", defaultValue: "Couldn’t start the run"),
          message: Self.message(error))
      }
    }
  }

  private func confirmDelete() {
    guard let automation else { return }
    let alert = UIAlertController(
      title: String(
        format: String(localized: "automations.mobile.deleteRetained", defaultValue: "Delete “%1$@” and its retained runs?"),
        automation.name),
      message: nil, preferredStyle: .alert)
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
        onSaved()
        close()
      } catch {
        setBusy(false)
        showAlert(
          title: String(localized: "orcaios.automation.deleteFailed", defaultValue: "Couldn’t delete the automation"),
          message: Self.message(error))
      }
    }
  }

  private func setBusy(_ busy: Bool) {
    self.busy = busy
    nameCell.isEnabled = !busy
    promptCell.isEnabled = !busy
    customCell.isEnabled = !busy
    navigationItem.leftBarButtonItem?.isEnabled = !busy
    rebuild()
  }

  @objc private func cancel() {
    view.endEditing(true)
    guard dirty else {
      close()
      return
    }
    confirmDiscard()
  }

  private func confirmDiscard() {
    let sheet = UIAlertController(
      title: String(localized: "automations.mobile.discardChangesTitle", defaultValue: "Discard changes?"),
      message: String(
        localized: "automations.mobile.discardChangesMessage", defaultValue: "Unsaved edits to this automation will be lost."),
      preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: String(localized: "automations.mobile.discard", defaultValue: "Discard"), style: .destructive) {
        [weak self] _ in self?.close()
      })
    sheet.addAction(
      UIAlertAction(title: String(localized: "automations.mobile.keepEditing", defaultValue: "Keep editing"), style: .cancel))
    sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
    present(sheet, animated: true)
  }

  private func close() {
    if navigationController?.viewControllers.first === self, presentingViewController != nil {
      dismiss(animated: true)
    } else {
      navigationController?.popViewController(animated: true)
    }
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

extension AutomationEditorViewController: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
    if !busy { confirmDiscard() }
  }
}

/// A text field or a growing text view filling its row.
private final class TextInputCell: UITableViewCell, UITextFieldDelegate, UITextViewDelegate {
  private let field = UITextField()
  private let textView = UITextView()
  private let placeholder = UILabel()
  private let multiline: Bool
  private var onChange: ((String) -> Void)?

  var isEnabled = true {
    didSet {
      field.isEnabled = isEnabled
      textView.isEditable = isEnabled
      field.textColor = isEnabled ? Palette.textPrimary : Palette.textMuted
      textView.textColor = isEnabled ? Palette.textPrimary : Palette.textMuted
    }
  }

  var text: String {
    get { multiline ? textView.text : field.text ?? "" }
    set {
      if multiline { textView.text = newValue } else { field.text = newValue }
      placeholder.isHidden = !newValue.isEmpty
    }
  }

  init(multiline: Bool) {
    self.multiline = multiline
    super.init(style: .default, reuseIdentifier: nil)
    selectionStyle = .none
    backgroundColor = Palette.bgRaised
    let input: UIView = multiline ? textView : field
    input.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(input)
    if multiline {
      textView.font = .preferredFont(forTextStyle: .body)
      textView.textColor = Palette.textPrimary
      textView.backgroundColor = .clear
      textView.isScrollEnabled = false
      textView.textContainerInset = .zero
      textView.textContainer.lineFragmentPadding = 0
      textView.delegate = self
      placeholder.font = textView.font
      placeholder.textColor = .placeholderText
      placeholder.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(placeholder)
      NSLayoutConstraint.activate([
        placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
        placeholder.topAnchor.constraint(equalTo: textView.topAnchor),
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
      ])
    } else {
      field.font = .preferredFont(forTextStyle: .body)
      field.textColor = Palette.textPrimary
      field.clearButtonMode = .whileEditing
      field.returnKeyType = .done
      field.delegate = self
      field.addAction(UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged)
    }
    NSLayoutConstraint.activate([
      input.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      input.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      input.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
      input.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.md),
      input.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(placeholder text: String, text value: String, literal: Bool = false, onChange: @escaping (String) -> Void) {
    if multiline {
      placeholder.text = text
      textView.accessibilityLabel = text
    } else {
      field.placeholder = text
      field.accessibilityLabel = text
    }
    if literal {
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.spellCheckingType = .no
      field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    }
    self.text = value
    self.onChange = onChange
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }

  func textViewDidChange(_ textView: UITextView) {
    placeholder.isHidden = !textView.text.isEmpty
    onChange?(textView.text)
  }
}
