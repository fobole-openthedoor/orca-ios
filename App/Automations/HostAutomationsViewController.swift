import OrcaCore
import UIKit

/// A desktop's Automations page (`/h/<id>/automations`: MobileAutomationsScreen.tsx, AutomationManager.tsx).
/// Automations / Runs under the bar; below it the list, an automation's detail with its recent runs, the runs with
/// their filters, or one run's details, switched on the one page as the official does. New and Edit push the
/// three-step editor; Cancel comes back to where it left, a save to the saved automation's detail.
final class HostAutomationsViewController: UIViewController {
  private enum Page {
    case list
    case detail(id: String)
    /// A run, read under the scope it was listed in ("" for every automation's).
    case run(AutomationRun, scope: String)
  }

  private enum Tab: Int {
    case automations, runs
  }

  /// One scope's run history, newest first, a page at a time (use-automation-runs.ts).
  private struct History {
    var scope: String
    var runs: [AutomationRun] = []
    var cursor: String?
    var loading = false
    var error: String?
  }

  private let session: HostSession
  private let segments = UISegmentedControl()
  private let scroll = UIScrollView()
  private let stack = UIStackView()

  private var page = Page.list
  private var section = Tab.automations
  private var automations: [Automation] = []
  private var loaded = false
  private var error: String?
  private var busy = false
  private var wasConnected = false
  /// Where projects are set up, for the detail's Project line.
  private var targets: AutomationTargets?
  /// The Runs page's Automation ("" is all) and Outcome choices.
  private var filter = ""
  private var outcome = "all"
  private var history = History(scope: "")
  /// A run's full row, read when the list's preview was cut; `fullFailed` names the run whose read failed.
  private var fullRun: AutomationRun?
  private var fullFailed: String?
  private var openError: String?

  init(session: HostSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var connected: Bool { session.connectionState == .connected }
  private var disabled: Bool { !connected || busy }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    title = String(localized: "automations.mobile.automations", defaultValue: "Automations")
    navigationItem.largeTitleDisplayMode = .never

    // Automations / Runs, inset under the bar like Source Control's switch (AutomationTabs).
    segments.insertSegment(
      withTitle: String(localized: "automations.mobile.automations", defaultValue: "Automations"), at: 0, animated: false)
    segments.insertSegment(withTitle: String(localized: "automations.mobile.runs", defaultValue: "Runs"), at: 1, animated: false)
    segments.selectedSegmentIndex = 0
    segments.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        Haptics.select()
        self.showList(Tab(rawValue: self.segments.selectedSegmentIndex) ?? .automations)
      }, for: .valueChanged)
    let accessory = UIView()
    accessory.backgroundColor = Palette.bgBase
    segments.translatesAutoresizingMaskIntoConstraints = false
    accessory.addSubview(segments)
    let border = Hairline()
    accessory.addSubview(border)

    scroll.alwaysBounceVertical = true
    scroll.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.refresh() })
    stack.axis = .vertical
    stack.spacing = Spacing.lg
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    for part in [accessory, scroll] as [UIView] {
      part.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(part)
    }
    NSLayoutConstraint.activate([
      accessory.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      accessory.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      accessory.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      segments.topAnchor.constraint(equalTo: accessory.topAnchor, constant: Spacing.sm),
      segments.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: Spacing.md),
      segments.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -Spacing.md),
      segments.bottomAnchor.constraint(equalTo: border.topAnchor, constant: -Spacing.sm),
      border.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
      border.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
      border.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
      scroll.topAnchor.constraint(equalTo: accessory.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      // automation-styles.ts content: 16 pt padding, 24 below.
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
    ])
    render()
  }

  override func updateProperties() {
    super.updateProperties()
    navigationItem.subtitle = session.name
    // Read on every (re)connect; the page redraws only when the connection flips, not on each workspace poll.
    guard connected != wasConnected else { return }
    wasConnected = connected
    if connected { load() } else { render() }
  }

  // MARK: Loading

  private func refresh() {
    load()
  }

  private func load() {
    guard connected else {
      scroll.refreshControl?.endRefreshing()
      return
    }
    let api = session.api
    Task {
      do {
        automations = try await api.automations()
        loaded = true
        error = nil
      } catch {
        self.error = AutomationEditorViewController.message(error)
      }
      scroll.refreshControl?.endRefreshing()
      // A detail whose automation is gone falls back to the list.
      if case .detail(let id) = page, loaded, !automations.contains(where: { $0.id == id }) { page = .list }
      render()
      if targets == nil { targets = try? await api.automationTargets() }
      loadHistory()
      render()
    }
  }

  /// The run history this page shows: an automation's on its detail, the run's own scope, or the Runs filter.
  private var historyScope: String? {
    switch page {
    case .detail(let id): id
    case .run(_, let scope): scope
    case .list: section == .runs ? filter : nil
    }
  }

  private func loadHistory(more: Bool = false) {
    guard let scope = historyScope, connected else { return }
    if history.scope != scope { history = History(scope: scope) }
    guard !history.loading, !more || history.cursor != nil else { return }
    let automation = scope.isEmpty ? nil : automations.first { $0.id == scope }
    if !scope.isEmpty, automation == nil { return }
    history.loading = true
    history.error = nil
    let cursor = more ? history.cursor : nil
    let api = session.api
    Task {
      do {
        let read = try await api.automationRuns(of: automation, cursor: cursor)
        guard history.scope == scope else { return }
        let fresh = Set(read.runs.map(\.id))
        history.runs = (more ? history.runs.filter { !fresh.contains($0.id) } : []) + read.runs
        history.cursor = read.nextCursor
      } catch {
        guard history.scope == scope else { return }
        history.error = AutomationEditorViewController.message(error)
      }
      history.loading = false
      render()
    }
  }

  /// The selected run's full row, when the list cut its output to a preview (use-full-automation-run.ts).
  private func loadFullRun(_ run: AutomationRun, scope: String) {
    guard run.output?.truncated == true, fullRun?.id != run.id, connected else { return }
    fullFailed = nil
    let automation = automations.first { $0.id == scope }
    let api = session.api
    Task {
      do {
        if let read = try await api.automationRun(run, of: automation) { fullRun = read }
      } catch {
        fullFailed = run.id
      }
      render()
    }
  }

  // MARK: Navigation

  private func showList(_ next: Tab) {
    section = next
    segments.selectedSegmentIndex = next.rawValue
    page = .list
    loadHistory()
    render(top: true)
  }

  private func open(_ automation: Automation) {
    page = .detail(id: automation.id)
    loadHistory()
    render(top: true)
  }

  private func open(_ run: AutomationRun, scope: String) {
    section = .runs
    segments.selectedSegmentIndex = Tab.runs.rawValue
    page = .run(run, scope: scope)
    openError = nil
    loadHistory()
    loadFullRun(run, scope: scope)
    render(top: true)
  }

  /// New (nil) or existing. A save comes back on the saved automation's detail; Cancel on the page as it was.
  private func edit(_ automation: Automation?) {
    let editor = AutomationEditorViewController(session: session, automation: automation, showsActions: false) {
      [weak self] id in
      guard let self else { return }
      if let id {
        self.section = .automations
        self.segments.selectedSegmentIndex = Tab.automations.rawValue
        self.page = .detail(id: id)
      }
      self.load()
    }
    navigationController?.pushViewController(editor, animated: true)
  }

  // MARK: Actions

  /// One host action at a time; a failure shows in the page's error line, as catalog.perform does.
  private func perform(_ work: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    render()
    Task {
      do {
        try await work()
        error = nil
      } catch {
        self.error = AutomationEditorViewController.message(error)
      }
      busy = false
      render()
    }
  }

  private func toggle(_ automation: Automation, enabled: Bool) {
    let api = session.api
    perform { [weak self] in
      let updated = try await api.setAutomation(automation, enabled: enabled)
      guard let self, let index = self.automations.firstIndex(where: { $0.id == automation.id }) else { return }
      if let updated {
        self.automations[index] = updated
      } else {
        self.automations[index].enabled = enabled
      }
    }
  }

  private func runNow(_ automation: Automation) {
    let api = session.api
    perform { [weak self] in
      let run = try await api.runAutomationNow(automation)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      guard let self else { return }
      if let run {
        self.open(run, scope: automation.id)
      } else {
        self.loadHistory()
      }
    }
  }

  private func confirmDelete(_ automation: Automation) {
    let alert = UIAlertController(
      title: String(localized: "common.delete", defaultValue: "Delete"),
      message: String(
        format: String(localized: "automations.mobile.deleteRetained", defaultValue: "Delete “%1$@” and its retained runs?"),
        automation.name),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "common.delete", defaultValue: "Delete"), style: .destructive) { [weak self] _ in
        guard let self else { return }
        let api = self.session.api
        self.perform { [weak self] in
          try await api.deleteAutomation(automation)
          guard let self else { return }
          self.automations.removeAll { $0.id == automation.id }
          self.showList(.automations)
        }
      })
    present(alert, animated: true)
  }

  /// Opens the run's agent in its workspace, while that workspace is still on the desktop.
  private func openAgent(_ run: AutomationRun) {
    guard let workspaceId = run.workspaceId, run.terminalPaneKey != nil,
      session.worktrees.contains(where: { $0.id == workspaceId })
    else {
      openError = String(
        localized: "automations.mobile.theOriginalAgentPaneIsNoLongerAvailableToOpenSavedOutputRemainsHere",
        defaultValue: "The original agent pane is no longer available to open. Saved output remains here.")
      return render()
    }
    navigationController?.pushViewController(SessionViewController(session: session, worktreeId: workspaceId), animated: true)
  }

  // MARK: Drawing

  private func render(top: Bool = false) {
    guard isViewLoaded else { return }
    segments.isEnabled = !busy
    for view in stack.arrangedSubviews { view.removeFromSuperview() }
    if !connected {
      stack.addArrangedSubview(
        meta(
          String(
            localized:
              "automations.mobile.reconnectToThisHostToRefreshOrMakeChangesSavedInformationRemainsAvailableBelow",
            defaultValue: "Reconnect to this host to refresh or make changes. Saved information remains available below.")))
    }
    if let error {
      let refresh = button(String(localized: "automations.mobile.refresh", defaultValue: "Refresh")) { [weak self] in
        self?.load()
      }
      refresh.isEnabled = !disabled
      stack.addArrangedSubview(column([errorLabel(error), refresh]))
    }
    switch page {
    case .list where section == .automations: stack.addArrangedSubview(listView())
    case .list: stack.addArrangedSubview(runsView())
    case .detail(let id):
      if let automation = automations.first(where: { $0.id == id }) {
        stack.addArrangedSubview(detailView(automation))
        stack.addArrangedSubview(heading(String(localized: "automations.mobile.recentRuns", defaultValue: "Recent runs")))
        stack.addArrangedSubview(runList(outcome: "all", recent: true))
      }
    case .run(let run, let scope):
      let shown = fullRun?.id == run.id ? fullRun! : history.runs.first { $0.id == run.id } ?? run
      stack.addArrangedSubview(runDetailView(shown, scope: scope))
    }
    if top { scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false) }
  }

  /// AutomationList.tsx: New automation, then the empty state or a card per automation.
  private func listView() -> UIView {
    let create = AutomationButton(primary: true)
    create.label = String(localized: "automations.mobile.newAutomation", defaultValue: "New automation")
    create.onPress = { [weak self] in self?.edit(nil) }
    create.isEnabled = !disabled && loaded
    var views: [UIView] = [create]
    if !loaded, error == nil {
      views.append(meta(String(localized: "automations.mobile.loadingAutomations", defaultValue: "Loading automations…")))
    } else if loaded, automations.isEmpty {
      let empty = UIStackView(arrangedSubviews: [
        LucideView(.calendarClock, size: 28, color: Palette.textMuted),
        heading(
          String(
            localized: "automations.mobile.letYourAgentsWorkOnASchedule", defaultValue: "Let your agents work on a schedule"),
          alignment: .center),
        meta(
          String(
            localized: "automations.mobile.createAnAutomationToRunATaskOnThisHost",
            defaultValue: "Create an automation to run a task on this host."), alignment: .center),
      ])
      empty.axis = .vertical
      empty.alignment = .center
      empty.spacing = Spacing.md
      empty.isLayoutMarginsRelativeArrangement = true
      empty.directionalLayoutMargins = .init(top: Spacing.xl, leading: 0, bottom: Spacing.xl, trailing: 0)
      views.append(empty)
    } else {
      views += automations.map(automationCard)
    }
    return column(views)
  }

  private func automationCard(_ automation: Automation) -> UIView {
    let name = PressableControl()
    let title = heading(automation.name)
    let chevron = LucideView(.chevronRight, size: 16, color: Palette.textMuted)
    let nameRow = UIStackView(arrangedSubviews: [title, chevron])
    nameRow.alignment = .center
    nameRow.spacing = Spacing.md
    nameRow.isUserInteractionEnabled = false
    name.addSubview(nameRow)
    nameRow.pin(to: name)
    name.onPressedChange = { [weak name] pressed in name?.alpha = pressed ? Feedback.pressedOpacity : 1 }
    name.onPress = { [weak self] in self?.open(automation) }
    name.accessibilityLabel = automation.name
    name.accessibilityTraits = .button
    name.isAccessibilityElement = true
    let row = UIStackView(arrangedSubviews: [name, scheduleSwitch(automation)])
    row.alignment = .center
    row.spacing = Spacing.md

    let lastResult =
      automation.lastRunStatus.map {
        String(
          format: String(localized: "automations.mobile.lastResult", defaultValue: "Last: %1$@ · %2$@"),
          AutomationPresentation.status($0), AutomationPresentation.date(automation.lastRunAt))
      } ?? String(localized: "automations.mobile.latestResultNotReported", defaultValue: "Latest result not reported")
    var place = automation.runContext?.path ?? automation.projectId
    if let target = automation.sshTargetId {
      place += String(format: String(localized: "automations.mobile.sshTarget", defaultValue: " · SSH %1$@"), target)
    }
    var views: [UIView] = [
      row, meta(AutomationPresentation.schedule(automation)), meta(AutomationPresentation.nextRun(automation)),
      meta(lastResult), meta(place),
    ]
    if let issue = automation.orphanIssue { views.append(errorLabel(AutomationPresentation.orphanIssue(issue))) }
    return card(views)
  }

  private func scheduleSwitch(_ automation: Automation) -> UISwitch {
    let toggle = UISwitch()
    toggle.isOn = automation.enabled
    toggle.isEnabled = !disabled
    toggle.accessibilityLabel = String(
      format: String(localized: "automations.mobile.runOnSchedule", defaultValue: "Run %1$@ on schedule"), automation.name)
    toggle.setContentHuggingPriority(.required, for: .horizontal)
    toggle.addAction(
      UIAction { [weak self, weak toggle] _ in
        guard let self, let toggle else { return }
        self.toggle(automation, enabled: toggle.isOn)
      }, for: .valueChanged)
    return toggle
  }

  /// AutomationDetail.tsx: back to the list, the name with its switch, what it is, then its actions.
  private func detailView(_ automation: Automation) -> UIView {
    let back = button(String(localized: "automations.mobile.allAutomations", defaultValue: "All automations")) { [weak self] in
      self?.showList(.automations)
    }
    let title = TextLabel(automation.name, size: Typography.titleSize, weight: .semibold, lines: 0)
    let titleRow = UIStackView(arrangedSubviews: [title, scheduleSwitch(automation)])
    titleRow.alignment = .center
    titleRow.spacing = Spacing.md
    var views: [UIView] = [back, titleRow]
    if let issue = automation.orphanIssue { views.append(errorLabel(AutomationPresentation.orphanIssue(issue))) }

    // The project as set up where its owner runs it; Unavailable when that can't be told.
    let unavailable = String(localized: "automations.mobile.unavailable", defaultValue: "Unavailable")
    let ownerHost = automation.ownerKind == "self" ? "local" : automation.sshTargetId.map { "ssh:\($0)" }
    let setups =
      targets?.setups.filter { setup in
        guard setup.hostId == ownerHost else { return false }
        if let context = automation.runContext {
          return setup.projectId == context.projectId && setup.id == context.setupId && setup.path == context.path
        }
        return setup.repoId == automation.projectId
      } ?? []
    let setup = setups.count == 1 ? setups.first : nil
    let workspace =
      automation.workspaceMode == "existing"
      ? session.worktrees.first { $0.id == automation.workspaceId }.map { $0.displayName.isEmpty ? $0.path : $0.displayName }
        ?? unavailable
      : String(localized: "automations.mobile.newWorkspacePerRun", defaultValue: "New workspace per run")
    views.append(
      card([
        metadata(String(localized: "automations.mobile.schedule", defaultValue: "Schedule"), AutomationPresentation.schedule(automation)),
        metadata(
          String(localized: "automations.mobile.nextRun", defaultValue: "Next run"),
          automation.enabled
            ? AutomationPresentation.date(automation.nextRunAt, timezone: automation.timezone)
            : String(localized: "automations.mobile.noNextScheduledRun", defaultValue: "No next scheduled run")),
        metadata(
          String(localized: "automations.mobile.agent", defaultValue: "Agent"),
          AutomationEditorViewController.agentName(automation.agentId)),
        metadata(
          String(localized: "automations.mobile.project", defaultValue: "Project"),
          setup.map { "\($0.label) · \($0.path)" } ?? unavailable),
        metadata(String(localized: "automations.mobile.workspace", defaultValue: "Workspace"), workspace),
      ]))
    views.append(heading(String(localized: "automations.mobile.instructions", defaultValue: "Instructions")))
    views.append(TextLabel(automation.prompt, size: Typography.bodySize, lineHeight: 21, lines: 0))

    let run = AutomationButton(primary: true)
    run.label = String(localized: "automations.mobile.runNow", defaultValue: "Run now")
    run.onPress = { [weak self] in self?.runNow(automation) }
    run.isEnabled = !disabled && automation.orphanIssue == nil
    let edit = button(String(localized: "automations.mobile.edit", defaultValue: "Edit")) { [weak self] in self?.edit(automation) }
    edit.isEnabled = !disabled
    edit.setContentHuggingPriority(.required, for: .horizontal)
    let actions = UIStackView(arrangedSubviews: [run, edit])
    actions.spacing = Spacing.md
    views.append(actions)
    views.append(
      button(String(localized: "automations.mobile.viewAllRuns", defaultValue: "View all runs")) { [weak self] in
        guard let self else { return }
        self.filter = automation.id
        self.showList(.runs)
      })
    let delete = button(String(localized: "automations.mobile.deleteAutomation", defaultValue: "Delete automation")) {
      [weak self] in self?.confirmDelete(automation)
    }
    delete.destructive = true
    delete.isEnabled = !disabled
    views.append(delete)
    return column(views)
  }

  /// AutomationRunsView: which automation and outcome, then the runs that match.
  private func runsView() -> UIView {
    let automationOptions =
      [("", String(localized: "automations.mobile.allAutomations", defaultValue: "All automations"))]
      + automations.map { ($0.id, $0.name) }
    let outcomes = [
      ("all", String(localized: "automations.mobile.allOutcomes", defaultValue: "All outcomes")),
      ("active", String(localized: "automations.mobile.inProgress", defaultValue: "In progress")),
      ("completed", String(localized: "automations.mobile.completed", defaultValue: "Completed")),
      ("dispatch_failed", String(localized: "automations.mobile.couldNotStart", defaultValue: "Could not start")),
      ("skipped", String(localized: "automations.mobile.skipped", defaultValue: "Skipped")),
    ]
    return column([
      choice(String(localized: "automations.mobile.automation", defaultValue: "Automation"), automationOptions, selected: filter) {
        [weak self] id in
        self?.filter = id
        self?.loadHistory()
        self?.render()
      },
      choice(String(localized: "automations.mobile.outcome", defaultValue: "Outcome"), outcomes, selected: outcome) {
        [weak self] value in
        self?.outcome = value
        self?.render()
      },
      runList(outcome: outcome, recent: false),
    ])
  }

  /// AutomationRunList: its error and Retry, loading, nothing to show, a card per run, then Load more.
  private func runList(outcome: String, recent: Bool) -> UIView {
    var views: [UIView] = []
    if let error = history.error {
      views.append(errorLabel(error))
      let retry = button(String(localized: "automations.mobile.retryHistory", defaultValue: "Retry history")) { [weak self] in
        self?.loadHistory()
      }
      retry.isEnabled = connected && !history.loading
      views.append(retry)
    }
    let matches = history.runs.filter { AutomationPresentation.matches($0, outcome: outcome) }
    let visible = recent ? Array(matches.prefix(3)) : matches
    if history.loading, history.runs.isEmpty {
      views.append(meta(String(localized: "automations.mobile.loadingRuns", defaultValue: "Loading runs…")))
    }
    if !history.loading, visible.isEmpty {
      views.append(
        meta(
          history.cursor != nil
            ? String(
              localized: "automations.mobile.noMatchingRunsInTheLoadedHistoryLoadMoreToContinue",
              defaultValue: "No matching runs in the loaded history. Load more to continue.")
            : String(localized: "automations.mobile.noMatchingRunsYet", defaultValue: "No matching runs yet.")))
    }
    let scope = history.scope
    for run in visible {
      let trigger = AutomationPresentation.trigger(
        run, scheduled: String(localized: "automations.mobile.scheduled", defaultValue: "Scheduled"))
      let status = AutomationPresentation.status(run.status)
      let date = AutomationPresentation.date(run.scheduledFor)
      let title = heading(run.title)
      let titleRow = UIStackView(arrangedSubviews: [title, LucideView(.chevronRight, size: 16, color: Palette.textMuted)])
      titleRow.alignment = .center
      titleRow.spacing = Spacing.md
      var lines: [UIView] = [
        titleRow, TextLabel(status, size: Typography.bodySize, lineHeight: 21, lines: 0), meta("\(date) · \(trigger)"),
      ]
      if let workspace = run.workspaceDisplayName { lines.append(meta(workspace)) }
      let control = card(lines, pressable: true) as! PressableControl
      control.onPress = { [weak self] in self?.open(run, scope: scope) }
      control.accessibilityLabel = String(
        format: String(localized: "automations.mobile.runSummary", defaultValue: "%1$@, %2$@, %3$@"), run.title, status, date)
      views.append(control)
    }
    if !recent, history.cursor != nil {
      let more = button(
        history.loading
          ? String(localized: "automations.mobile.loading", defaultValue: "Loading…")
          : String(localized: "automations.mobile.loadMoreRuns", defaultValue: "Load more runs")
      ) { [weak self] in self?.loadHistory(more: true) }
      more.isEnabled = !history.loading && connected
      views.append(more)
    }
    return column(views)
  }

  /// AutomationRunDetails.tsx: back to the runs, the run's facts, its output, then Open agent.
  private func runDetailView(_ run: AutomationRun, scope: String) -> UIView {
    var views: [UIView] = [
      button(String(localized: "automations.mobile.allRuns", defaultValue: "All runs")) { [weak self] in self?.showList(.runs) }
    ]
    if let error = history.error { views.append(errorLabel(error)) }
    views.append(TextLabel(run.title, size: Typography.titleSize, weight: .semibold, lines: 0))
    views.append(TextLabel(AutomationPresentation.status(run.status), size: Typography.bodySize, lineHeight: 21, lines: 0))
    views.append(
      card([
        metadata(
          String(localized: "automations.mobile.scheduledFor", defaultValue: "Scheduled for"),
          AutomationPresentation.date(run.scheduledFor)),
        metadata(String(localized: "automations.mobile.started", defaultValue: "Started"), AutomationPresentation.date(run.startedAt)),
        metadata(
          String(localized: "automations.mobile.trigger", defaultValue: "Trigger"),
          AutomationPresentation.trigger(run, scheduled: String(localized: "automations.mobile.schedule", defaultValue: "Schedule"))),
        metadata(
          String(localized: "automations.mobile.workspace", defaultValue: "Workspace"),
          run.workspaceDisplayName ?? run.runContextPath ?? run.workspaceId
            ?? String(localized: "automations.mobile.notCreated", defaultValue: "Not created")),
        metadata(
          String(localized: "automations.mobile.projectHost", defaultValue: "Project host"),
          run.runContextHostId ?? String(localized: "automations.mobile.notRecorded", defaultValue: "Not recorded")),
        metadata(String(localized: "automations.mobile.run", defaultValue: "Run"), run.id),
      ]))
    let runError = AutomationPresentation.runError(run)
    if let runError { views.append(errorLabel(runError)) }
    views.append(heading(String(localized: "automations.mobile.output", defaultValue: "Output")))
    if fullFailed == run.id {
      views.append(
        errorLabel(String(localized: "automations.mobile.fullOutputUnavailable", defaultValue: "Couldn't load the full output.")))
      let retry = button(String(localized: "automations.mobile.retryFullOutput", defaultValue: "Retry")) { [weak self] in
        self?.loadFullRun(run, scope: scope)
      }
      retry.isEnabled = connected
      views.append(retry)
    }
    views.append(
      output(run.content(error: runError, noOutput: String(localized: "automations.mobile.noOutput", defaultValue: "No output content available."))))
    if let snapshot = run.output {
      let captured = AutomationPresentation.date(snapshot.capturedAt)
      views.append(
        meta(
          snapshot.truncated && fullRun?.id != run.id
            ? String(
              format: String(
                localized: "automations.mobile.capturedTruncated", defaultValue: "Captured %1$@ · Output truncated by host"),
              captured)
            : String(format: String(localized: "automations.mobile.capturedDate", defaultValue: "Captured %1$@"), captured)))
    }
    if let openError { views.append(errorLabel(openError)) }
    if run.terminalPaneKey == nil || run.workspaceId == nil, run.status != "pending", run.status != "dispatching" {
      views.append(
        meta(
          String(
            localized: "automations.mobile.theOriginalAgentPaneIsUnavailableSavedOutputRemainsHere",
            defaultValue: "The original agent pane is unavailable. Saved output remains here.")))
    }
    let open = button(String(localized: "automations.mobile.openAgent", defaultValue: "Open agent")) { [weak self] in
      self?.openAgent(run)
    }
    open.isEnabled = connected && run.terminalPaneKey != nil && run.workspaceId != nil
    views.append(open)
    return column(views)
  }

  // MARK: Pieces (automation-styles.ts)

  private func column(_ views: [UIView]) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    return stack
  }

  /// A bordered panel: 16 pt in, 12 between lines. Pressable for a run, which opens on a tap.
  private func card(_ views: [UIView], pressable: Bool = false) -> UIView {
    let content = column(views)
    content.spacing = Spacing.md
    let card: UIView = pressable ? PressableControl() : UIView()
    card.backgroundColor = Palette.bgPanel
    card.layer.cornerRadius = Radius.surface
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1
    card.layer.borderColor = Palette.borderSubtle.resolvedColor(with: traitCollection).cgColor
    card.addSubview(content)
    content.pin(to: card, insets: UIEdgeInsets(top: Spacing.lg, left: Spacing.lg, bottom: Spacing.lg, right: Spacing.lg))
    if let control = card as? PressableControl {
      content.isUserInteractionEnabled = false
      control.isAccessibilityElement = true
      control.accessibilityTraits = .button
      control.onPressedChange = { [weak control] pressed in control?.alpha = pressed ? Feedback.pressedOpacity : 1 }
    }
    return card
  }

  /// AutomationMetadata: a meta label over the value.
  private func metadata(_ label: String, _ value: String) -> UIView {
    column([meta(label), TextLabel(value, size: Typography.bodySize, lineHeight: 21, lines: 0)])
  }

  /// AutomationChoice: a label over a full-width button whose menu picks one.
  private func choice(
    _ label: String, _ options: [(String, String)], selected: String, onSelect: @escaping (String) -> Void
  ) -> UIView {
    let picker = AutomationButton()
    picker.label =
      options.first { $0.0 == selected }?.1 ?? String(localized: "automations.mobile.choose", defaultValue: "Choose…")
    picker.menu = UIMenu(
      title: label,
      children: options.map { option in
        UIAction(title: option.1, state: option.0 == selected ? .on : .off) { _ in
          guard option.0 != selected else { return }
          Haptics.select()
          onSelect(option.0)
        }
      })
    picker.accessibilityLabel = label
    return column([meta(label), picker])
  }

  /// The run's output in the editor surface's monospace box, selectable as the official's.
  private func output(_ text: String) -> UIView {
    let view = UITextView()
    view.isEditable = false
    view.isScrollEnabled = false
    view.backgroundColor = Palette.editorSurface
    view.layer.cornerRadius = Radius.surface
    view.layer.cornerCurve = .continuous
    view.textContainerInset = UIEdgeInsets(top: Spacing.md, left: Spacing.md, bottom: Spacing.md, right: Spacing.md)
    view.textContainer.lineFragmentPadding = 0
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 19
    paragraph.maximumLineHeight = 19
    view.attributedText = NSAttributedString(
      string: text,
      attributes: [.font: Typography.mono(Typography.metaSize), .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraph])
    return view
  }

  private func button(_ title: String, action: @escaping () -> Void) -> AutomationButton {
    let button = AutomationButton()
    button.label = title
    button.onPress = action
    return button
  }

  private func heading(_ text: String, alignment: NSTextAlignment = .natural) -> TextLabel {
    TextLabel(text, size: Typography.bodySize, weight: .semibold, alignment: alignment, lines: 0)
  }

  private func meta(_ text: String, alignment: NSTextAlignment = .natural) -> TextLabel {
    TextLabel(text, size: Typography.metaSize, color: Palette.textSecondary, lineHeight: 18, alignment: alignment, lines: 0)
  }

  private func errorLabel(_ text: String) -> TextLabel {
    let label = TextLabel(text, size: Typography.bodySize, color: Palette.statusRed, lineHeight: 21, lines: 0)
    label.accessibilityTraits = .staticText
    return label
  }
}
