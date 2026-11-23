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
  var onGoal: ((ChatSessionModel.GoalChange) -> Void)?

  private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let row = UIStackView()
  private var tasks: [BackgroundTask] = []
  private var stopsAll = false
  private var goal: ChatOptions.Goal?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    glass.cornerConfiguration = .capsule()
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    row.spacing = 2
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(row)
    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      glass.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.lg),
      glass.heightAnchor.constraint(equalToConstant: 40),
      row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
      row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
      row.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
    ])
    redraw()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(tasks: [BackgroundTask], stopsAll: Bool, goal: ChatOptions.Goal?) {
    guard tasks != self.tasks || stopsAll != self.stopsAll || goal != self.goal else { return }
    self.tasks = tasks
    self.stopsAll = stopsAll
    self.goal = goal
    redraw()
  }

  private func redraw() {
    row.arrangedSubviews.forEach { $0.removeFromSuperview() }
    var segments: [UIView] = []
    // Agents, shells, then everything else the host runs in the background, in the official order.
    let groups: [(kinds: Set<String>?, key: String, icon: Lucide)] = [
      (["agent"], "session.backgroundTask.countAgents", .bot),
      (["command"], "session.backgroundTask.countShell", .squareTerminal),
      (["monitor"], "session.backgroundTask.countMonitors", .activity),
      (["workflow"], "session.backgroundTask.countWorkflows", .workflow),
      (nil, "session.backgroundTask.countTasks", .listTodo),
    ]
    let known: Set<String> = ["agent", "command", "monitor", "workflow"]
    for group in groups {
      let members = tasks.filter { group.kinds?.contains($0.kind) ?? !known.contains($0.kind) }
      guard !members.isEmpty else { continue }
      let title = String(format: Bundle.main.localizedString(forKey: group.key, value: "%lld", table: nil), members.count)
      segments.append(segment(icon: group.icon, title: title, menu: taskMenu(members)))
    }
    if let goal { segments.append(goalSegment(goal)) }
    for (index, segment) in segments.enumerated() {
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

  private func segment(icon: Lucide, title: String, color: UIColor = Palette.textPrimary, menu: UIMenu) -> UIButton {
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
    button.menu = menu
    return button
  }

  /// Each task as a submenu: look at it, or stop it. Stopping them all comes last.
  private func taskMenu(_ members: [BackgroundTask]) -> UIMenu {
    var children: [UIMenuElement] = members.map { task in
      var actions: [UIMenuElement] = [
        UIAction(
          title: String(localized: "common.open", defaultValue: "Open"), image: Lucide.externalLink.image(size: 18)
        ) { [weak self] _ in self?.onOpen?(task) }
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
      let submenu = UIMenu(
        title: task.label.isEmpty ? task.kind : task.label, image: Self.icon(task).image(size: 18), children: actions)
      submenu.subtitle = Self.facts(task)
      return submenu
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
      menu: UIMenu(title: heading, children: actions))
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
  static func compact(_ value: Int) -> String {
    switch value {
    case ..<1000: return "\(value)"
    case ..<1_000_000: return String(format: "%.1fk", Double(value) / 1000)
    default: return String(format: "%.1fM", Double(value) / 1_000_000)
    }
  }
}
