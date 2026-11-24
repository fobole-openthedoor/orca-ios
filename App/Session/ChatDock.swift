import OrcaCore
import UIKit

/// What runs beside the chat (MobileNativeChatBackgroundTasks, MobileNativeChatThreadGoalStrip), as one glass
/// toolbar above the composer: a segment per kind of background task ("2 个智能体", "1 个 shell") and one
/// for the goal. Each segment opens a native menu; stopping or clearing anything takes a second tap in a
/// submenu, so a stray touch never ends work.
final class ChatDockView: UIView {
  var onStop: ((String?) -> Void)?
  /// A task was picked to look at: open the call that started it.
  var onOpen: ((BackgroundTask) -> Void)?
  var onSubagent: ((ChatSubagent) -> Void)?
  var onWorker: ((ChatWorker) -> Void)?
  var onGoal: ((ChatSessionModel.GoalChange) -> Void)?
  enum QueuedAction { case send, edit, delete }
  var onQueued: ((QueuedMessage, QueuedAction) -> Void)?

  private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  /// The segments scroll sideways when they outgrow the screen; the glass is as wide as they are otherwise.
  private let scroll = UIScrollView()
  private let row = UIStackView()
  private var tasks: [BackgroundTask] = []
  private var subagents: [ChatSubagent] = []
  private var workers: [ChatWorker] = []
  private var stopsAll = false
  private var goal: ChatOptions.Goal?
  private var queued: [QueuedMessage] = []
  /// What the row shows, segment by segment: while it stays the same the buttons stay, so an open menu
  /// isn't torn down by a running task's ticking time or tokens.
  private var drawn: [String] = []

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    glass.cornerConfiguration = .capsule()
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    row.spacing = 2
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(scroll)
    scroll.addSubview(row)
    // As wide as the segments, until the screen runs out; then the row scrolls inside.
    let hug = glass.widthAnchor.constraint(equalTo: row.widthAnchor, constant: 12)
    hug.priority = .defaultHigh
    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      glass.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.lg),
      glass.heightAnchor.constraint(equalToConstant: 40),
      hug,
      scroll.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
      scroll.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
      scroll.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
      row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
    redraw()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(
    tasks: [BackgroundTask], subagents: [ChatSubagent], workers: [ChatWorker], stopsAll: Bool,
    goal: ChatOptions.Goal?, queued: [QueuedMessage]
  ) {
    guard tasks != self.tasks || subagents != self.subagents || workers != self.workers || stopsAll != self.stopsAll
      || goal != self.goal || queued != self.queued else { return }
    self.tasks = tasks
    self.subagents = subagents
    self.workers = workers
    self.stopsAll = stopsAll
    self.goal = goal
    self.queued = queued
    redraw()
  }

  private func redraw() {
    var segments: [(key: String, make: () -> UIButton)] = []
    // Agents, shells, then everything else the host runs in the background, in the official order.
    let groups: [(kinds: Set<String>?, key: String, icon: Lucide)] = [
      (["agent"], "session.backgroundTask.countAgents", .bot),
      (["command"], "session.backgroundTask.countShell", .squareTerminal),
      (["monitor"], "session.backgroundTask.countMonitors", .activity),
      (["workflow"], "session.backgroundTask.countWorkflows", .workflow),
      (nil, "session.backgroundTask.countTasks", .listTodo),
    ]
    for group in groups {
      let hasSubagents = group.kinds == ["agent"]
      let count = members(of: group.kinds).count + (hasSubagents ? subagents.count : 0)
      guard count > 0 else { continue }
      let title = String(format: Bundle.main.localizedString(forKey: group.key, value: "%lld", table: nil), count)
      // Built as it opens, from the tasks as they are then.
      segments.append((group.key + title, { [unowned self] in
        self.segment(icon: group.icon, title: title) { [weak self] in
          guard let self else { return nil }
          return self.taskMenu(self.members(of: group.kinds), showSubagents: hasSubagents)
        }
      }))
    }
    if !workers.isEmpty {
      let title = String(localized: "orcaios.chat.workers", defaultValue: "Orca workers")
      segments.append((title, { [unowned self] in
        self.segment(icon: .workflow, title: title) { [weak self] in self?.workerMenu() }
      }))
    }
    if !queued.isEmpty {
      let title = String.localizedStringWithFormat(
        String(localized: "chat.queuedMessages.queuedCount", defaultValue: "%lld queued"), queued.count)
      segments.insert((title, { [unowned self] in
        self.segment(icon: .listEnd, title: title) { [weak self] in self?.queuedMenu() }
      }), at: 0)
    }
    if let goal {
      segments.append(("goal \(goal)", { [unowned self] in self.goalSegment(goal) }))
    }
    let keys = segments.map(\.key)
    isHidden = segments.isEmpty
    guard keys != drawn else { return }
    drawn = keys
    row.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let made = segments.map { $0.make() }
    for (index, segment) in made.enumerated() {
      if index > 0 {
        let divider = UIView()
        divider.backgroundColor = Palette.borderSubtle
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 18),
        ])
        row.addArrangedSubview(divider)
      }
      row.addArrangedSubview(segment)
    }
    isHidden = segments.isEmpty
  }

  private func members(of kinds: Set<String>?) -> [BackgroundTask] {
    let known: Set<String> = ["agent", "command", "monitor", "workflow"]
    let agentIds = Set(subagents.map(\.id))
    return tasks.filter { task in
      (kinds?.contains(task.kind) ?? !known.contains(task.kind)) && (task.kind != "agent" || !agentIds.contains(task.id))
    }
  }

  private func segment(icon: Lucide, title: String, color: UIColor = Palette.textPrimary, menu: @escaping () -> UIMenu?) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = icon.image(size: 15, strokeWidth: 2)
    configuration.imagePadding = 6
    configuration.baseForegroundColor = color
    configuration.contentInsets = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
    configuration.titleLineBreakMode = .byTruncatingTail
    configuration.attributedTitle = AttributedString(
      title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)]))
    let button = UIButton(configuration: configuration)
    button.showsMenuAsPrimaryAction = true
    // Opening upward must not flip the order: looking comes before stopping.
    button.preferredMenuElementOrder = .fixed
    button.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { done in done(menu()?.children ?? []) }
    ])
    return button
  }

  /// Each task as a submenu: look at it, or stop it. Stopping them all comes last.
  private func taskMenu(_ members: [BackgroundTask], showSubagents: Bool) -> UIMenu {
    let agentTasks = Dictionary(tasks.filter { $0.kind == "agent" }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let agents = showSubagents ? subagents.reversed().map { agent -> UIMenuElement in
      let title = Self.name(agent)
      if let task = agentTasks[agent.id], task.stoppable {
        return taskSubmenu(task, title: title, subtitle: Self.agentState(agent.state)) { [weak self] in self?.onSubagent?(agent) }
      }
      return UIAction(title: title, subtitle: Self.agentState(agent.state), image: Lucide.bot.image(size: 18)) {
        [weak self] _ in self?.onSubagent?(agent)
      }
    } : []
    var children: [UIMenuElement] = agents + members.map { task in
      taskSubmenu(task, title: task.label.isEmpty ? task.kind : task.label, subtitle: Self.facts(task)) { [weak self] in self?.onOpen?(task) }
    }
    if stopsAll && tasks.count > 1 {
      let stopAll = String(localized: "session.backgroundTask.stopAll", defaultValue: "Stop background tasks")
      children.append(
        UIMenu(
          options: .displayInline,
          children: [
            UIMenu(
              title: stopAll, image: Lucide.circleX.image(size: 18), options: .destructive,
              children: [
                UIAction(title: stopAll, attributes: .destructive) { [weak self] _ in
                  UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                  self?.onStop?(nil)
                }
              ])
          ]))
    }
    return UIMenu(children: children)
  }

  private func taskSubmenu(_ task: BackgroundTask, title: String, subtitle: String?, open: @escaping () -> Void) -> UIMenu {
    var actions: [UIMenuElement] = [
      UIAction(
        title: String(localized: "common.open", defaultValue: "Open"), image: Lucide.externalLink.image(size: 18)
      ) { _ in open() }
    ]
    if task.stoppable {
      let id = task.id
      actions.append(
        UIAction(
          title: String(localized: "session.backgroundTask.stop", defaultValue: "Stop"),
          image: Lucide.circleX.image(size: 18), attributes: .destructive
        ) { [weak self] _ in
          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          self?.onStop?(id)
        })
    }
    let submenu = UIMenu(title: title, image: Self.icon(task).image(size: 18), children: actions)
    submenu.subtitle = subtitle
    return submenu
  }

  private func workerMenu() -> UIMenu {
    UIMenu(children: workers.map { worker in
      UIAction(
        title: worker.title.isEmpty ? worker.agent ?? Self.unnamedAgent : worker.title,
        subtitle: Self.agentState(worker.displayState), image: Lucide.workflow.image(size: 18)
      ) { [weak self] _ in self?.onWorker?(worker) }
    })
  }

  static var unnamedAgent: String {
    String(localized: "session.backgroundTask.agent", defaultValue: "Agent")
  }

  static func name(_ agent: ChatSubagent) -> String {
    agent.label.isEmpty ? agent.agentType ?? unnamedAgent : agent.label
  }

  static func agentState(_ state: String) -> String {
    switch state {
    case "working": String(localized: "chat.subagentGroup.stateWorking", defaultValue: "Working")
    case "idle": String(localized: "chat.subagentGroup.stateIdle", defaultValue: "Idle")
    case "completed": String(localized: "chat.subagentGroup.stateCompleted", defaultValue: "Completed")
    case "failed": String(localized: "chat.subagentGroup.stateFailed", defaultValue: "Failed")
    case "stopped": String(localized: "chat.subagentGroup.stateStopped", defaultValue: "Stopped")
    case "blocked": String(localized: "session.backgroundTask.stateBlocked", defaultValue: "Blocked")
    case "waiting": String(localized: "session.backgroundTask.stateWaiting", defaultValue: "Waiting")
    default: String(localized: "chat.subagentGroup.stateUnverifiable", defaultValue: "Unverified")
    }
  }

  /// Each queued message as a submenu: send it now, take it back to edit, or delete it (confirmed).
  private func queuedMenu() -> UIMenu {
    UIMenu(children: queued.map { message in
      let delete = String(localized: "chat.queuedMessages.deleteMessage", defaultValue: "Delete message")
      let title = message.text.replacingOccurrences(of: "\n", with: " ")
      let submenu = UIMenu(
        title: title.isEmpty ? "…" : String(title.prefix(80)), image: Lucide.messageSquare.image(size: 18),
        children: [
          UIAction(
            title: String(localized: "chat.composer.sendSteer", defaultValue: "Steer"), image: Lucide.send.image(size: 18)
          ) { [weak self] _ in self?.onQueued?(message, .send) },
          UIAction(
            title: String(localized: "chat.queuedMessages.editMessage", defaultValue: "Edit message"),
            image: Lucide.pencil.image(size: 18)
          ) { [weak self] _ in self?.onQueued?(message, .edit) },
          UIMenu(
            title: delete, image: Lucide.trash2.image(size: 18), options: .destructive,
            children: [
              UIAction(title: delete, attributes: .destructive) { [weak self] _ in self?.onQueued?(message, .delete) }
            ]),
        ])
      submenu.subtitle =
        message.state == "returned"
        ? String(localized: "chat.queuedMessages.pausedState", defaultValue: "Paused")
        : String(localized: "chat.queuedMessages.queuedState", defaultValue: "Queued")
      return submenu
    })
  }

  private func goalSegment(_ goal: ChatOptions.Goal) -> UIButton {
    let status: String
    switch goal.status {
    case "paused": status = String(localized: "chat.goal.paused", defaultValue: "Paused goal")
    case "blocked": status = String(localized: "chat.goal.blocked", defaultValue: "Goal blocked")
    case "limited", "budget_limited": status = String(localized: "chat.goal.limited", defaultValue: "Goal limited")
    case "active": status = String(localized: "chat.goal.pursuing", defaultValue: "Pursuing goal")
    default: status = String(localized: "chat.goal.set", defaultValue: "Goal set")
    }
    var actions: [UIMenuElement] = []
    if goal.hostChanges {
      let paused = goal.status == "paused"
      actions.append(
        UIAction(
          title: paused
            ? String(localized: "chat.goal.resume", defaultValue: "Resume")
            : String(localized: "chat.goal.pause", defaultValue: "Pause"),
          image: (paused ? Lucide.play : Lucide.pause).image(size: 18)
        ) { [weak self] _ in self?.onGoal?(paused ? .resume : .pause) })
    }
    let clear = String(localized: "chat.goal.clear", defaultValue: "Clear goal")
    actions.append(
      UIMenu(
        title: clear, image: Lucide.circleX.image(size: 18), options: .destructive,
        children: [
          UIAction(title: clear, attributes: .destructive) { [weak self] _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self?.onGoal?(.clear)
          }
        ]))
    // The menu's title carries the whole objective, with the time spent on it.
    var heading = goal.objective
    if goal.timeUsedSeconds > 0 { heading += "\n" + WorkSummaryView.duration(Int(goal.timeUsedSeconds)) }
    let button = segment(
      icon: .goal, title: status, color: goal.status == "active" ? Palette.textPrimary : Palette.statusAmber,
      menu: { UIMenu(children: [UIMenu(title: heading, options: .displayInline, children: actions)]) })
    return button
  }

  private static func icon(_ task: BackgroundTask) -> Lucide {
    switch task.kind {
    case "command": .squareTerminal
    case "monitor": .activity
    case "workflow": .workflow
    default: .bot
    }
  }

  /// How long it has run and what it has spent, as the official strip writes them.
  private static func facts(_ task: BackgroundTask) -> String? {
    var facts: [String] = []
    if let started = task.startedAt, started > 0 {
      facts.append(WorkSummaryView.duration(max(1, Int(Date().timeIntervalSince1970 - started / 1000))))
    }
    if let tokens = task.totalTokens, tokens > 0 {
      facts.append(String(format: String(localized: "chat.subagentGroup.tokens", defaultValue: "%@ tokens"), compact(tokens)))
    }
    return facts.isEmpty ? nil : facts.joined(separator: " · ")
  }

  /// 293600 as "293.6k", as the official strip writes token counts.
  static func compact(_ value: Int, millionDigits: Int = 1) -> String {
    switch value {
    case ..<1000: return "\(value)"
    case ..<1_000_000: return String(format: "%.1fk", Double(value) / 1000)
    default: return String(format: "%.*fM", millionDigits, Double(value) / 1_000_000)
    }
  }
}
