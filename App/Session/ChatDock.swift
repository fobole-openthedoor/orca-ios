import OrcaCore
import UIKit

/// The strips docked above the composer (MobileNativeChatBackgroundTasks, MobileNativeChatThreadGoalStrip):
/// the agent's background work and its goal, each one line that opens in place.
final class ChatDockView: UIView {
  var onStop: ((String?) -> Void)?

  private let stack = UIStackView()
  private let tasksStrip = DockStrip()
  private let goalStrip = DockStrip()
  private var tasksOpen = false
  private var goalOpen = false
  private var tasks: [BackgroundTask] = []
  private var stopsAll = false
  private var goal: ChatOptions.Goal?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
    ])
    stack.addArrangedSubview(tasksStrip)
    stack.addArrangedSubview(goalStrip)
    tasksStrip.onToggle = { [weak self] in
      self?.tasksOpen.toggle()
      self?.redraw()
    }
    goalStrip.onToggle = { [weak self] in
      self?.goalOpen.toggle()
      self?.redraw()
    }
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
    tasksStrip.isHidden = tasks.isEmpty
    if !tasks.isEmpty {
      var lines: [UIView] = []
      if tasksOpen {
        lines = tasks.map { task in taskRow(task) }
        if stopsAll && tasks.count > 1 {
          var stop = UIButton.Configuration.plain()
          stop.title = String(localized: "session.backgroundTask.stopAll", defaultValue: "Stop background tasks")
          stop.baseForegroundColor = Palette.statusRed
          stop.contentInsets = .init(top: 6, leading: 0, bottom: 2, trailing: 0)
          let button = UIButton(configuration: stop, primaryAction: UIAction { [weak self] _ in self?.onStop?(nil) })
          button.contentHorizontalAlignment = .leading
          lines.append(button)
        }
      }
      tasksStrip.show(icon: .bot, title: Self.summary(tasks), subtitle: nil, open: tasksOpen, body: lines)
    }
    goalStrip.isHidden = goal == nil
    if let goal {
      let status: String
      switch goal.status {
      case "paused": status = String(localized: "chat.goal.paused", defaultValue: "Paused goal")
      case "blocked": status = String(localized: "chat.goal.blocked", defaultValue: "Goal blocked")
      case "limited", "budget_limited": status = String(localized: "chat.goal.limited", defaultValue: "Goal limited")
      case "active": status = String(localized: "chat.goal.pursuing", defaultValue: "Pursuing goal")
      default: status = String(localized: "chat.goal.set", defaultValue: "Goal set")
      }
      let time = goal.timeUsedSeconds > 0 ? WorkSummaryView.duration(Int(goal.timeUsedSeconds)) : nil
      var body: [UIView] = []
      if goalOpen {
        let full = TextLabel(size: 14, color: Palette.textSecondary, lines: 0)
        full.text = goal.objective
        body = [full]
      }
      goalStrip.show(icon: .goal, title: status, subtitle: goalOpen ? nil : goal.objective, trailing: time, open: goalOpen, body: body)
    }
    isHidden = tasks.isEmpty && goal == nil
  }

  /// "3 个智能体 · 1 个 shell": counts by kind, as the official strip says them.
  private static func summary(_ tasks: [BackgroundTask]) -> String {
    var counts: [(String, Int)] = []
    for kind in ["agent", "command", "monitor", "workflow", "unknown"] {
      let count = tasks.filter { ($0.kind == kind) || (kind == "unknown" && !["agent", "command", "monitor", "workflow"].contains($0.kind)) }.count
      if count > 0 { counts.append((kind, count)) }
    }
    return counts.map { kind, count in
      let key: String
      switch kind {
      case "agent": key = "session.backgroundTask.countAgents"
      case "command": key = "session.backgroundTask.countShell"
      case "monitor": key = "session.backgroundTask.countMonitors"
      case "workflow": key = "session.backgroundTask.countWorkflows"
      default: key = "session.backgroundTask.countTasks"
      }
      return String(format: Bundle.main.localizedString(forKey: key, value: "%lld", table: nil), count)
    }.joined(separator: " · ")
  }

  private func taskRow(_ task: BackgroundTask) -> UIView {
    let icon = LucideView(task.kind == "command" ? .squareTerminal : task.kind == "monitor" ? .activity : .bot, size: 14, strokeWidth: 2, color: Palette.textMuted)
    let label = TextLabel(task.label.isEmpty ? task.kind : task.label, size: 14, color: Palette.textPrimary, lines: 1)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    var facts: [String] = []
    if let started = task.startedAt, started > 0 {
      facts.append(WorkSummaryView.duration(max(1, Int(Date().timeIntervalSince1970 - started / 1000))))
    }
    if let tokens = task.totalTokens, tokens > 0 {
      facts.append(String(format: String(localized: "chat.subagentGroup.tokens", defaultValue: "%@ tokens"), Self.compact(tokens)))
    }
    let meta = TextLabel(facts.joined(separator: " · "), size: 13, color: Palette.textMuted, tabular: true)
    let row = UIStackView(arrangedSubviews: [icon, label, meta])
    row.spacing = Spacing.sm
    row.alignment = .center
    if task.stoppable {
      var stop = UIButton.Configuration.plain()
      stop.title = String(localized: "session.backgroundTask.stop", defaultValue: "Stop")
      stop.baseForegroundColor = Palette.statusRed
      stop.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 0)
      let id = task.id
      row.addArrangedSubview(UIButton(configuration: stop, primaryAction: UIAction { [weak self] _ in self?.onStop?(id) }))
    }
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
    return row
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

/// One docked strip: a glass capsule with an icon, a title, an optional muted line and a chevron; its
/// body opens below the title.
private final class DockStrip: UIView {
  var onToggle: (() -> Void)?
  private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let icon = LucideView(.bot, size: 15, strokeWidth: 2, color: Palette.textSecondary)
  private let title = TextLabel(size: 14, weight: .semibold, color: Palette.textPrimary, lines: 1)
  private let subtitle = TextLabel(size: 14, color: Palette.textSecondary, lines: 1)
  private let trailing = TextLabel(size: 13, color: Palette.textMuted, tabular: true)
  private let chevron = LucideView(.chevronDown, size: 14, strokeWidth: 2, color: Palette.textMuted)
  private let body = UIStackView()

  init() {
    super.init(frame: .zero)
    glass.cornerConfiguration = .uniformCorners(radius: .fixed(Radius.surface))
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    glass.pin(to: self)
    subtitle.lineBreakMode = .byTruncatingTail
    subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
    let head = UIStackView(arrangedSubviews: [icon, title, subtitle, UIView(), trailing, chevron])
    head.spacing = Spacing.sm
    head.alignment = .center
    head.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
    body.axis = .vertical
    body.spacing = 2
    let column = UIStackView(arrangedSubviews: [head, body])
    column.axis = .vertical
    column.spacing = Spacing.xs
    column.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
      column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
      column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
      column.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
    ])
    let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
    head.addGestureRecognizer(tap)
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func toggle() {
    UISelectionFeedbackGenerator().selectionChanged()
    onToggle?()
  }

  func show(icon glyph: Lucide, title text: String, subtitle line: String?, trailing extra: String? = nil, open: Bool, body views: [UIView]) {
    icon.icon = glyph
    title.text = text
    subtitle.text = line
    subtitle.isHidden = (line ?? "").isEmpty
    trailing.text = extra
    trailing.isHidden = (extra ?? "").isEmpty
    chevron.transform = open ? CGAffineTransform(rotationAngle: .pi) : .identity
    body.arrangedSubviews.forEach { $0.removeFromSuperview() }
    views.forEach { body.addArrangedSubview($0) }
    body.isHidden = views.isEmpty
  }
}
