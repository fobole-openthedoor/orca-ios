import OrcaCore
import UIKit

/// The worktree status dot (agents/presentation/AgentSpinner.tsx): an 8 pt dot in a 12 pt box, a spinning ring while working.
final class AgentStatusDot: UIView {
  private let dot = UIView()
  private let ring = CAShapeLayer()

  static func color(for status: String) -> UIColor {
    switch status {
    case "working", "monitoring": AgentColor.working
    case "active", "done": AgentColor.done
    case "permission", "failed", "blocked", "waiting": AgentColor.attention
    case "interrupted": Palette.textMuted
    case "unconfirmed", "unverifiable": Palette.statusAmber
    default: AgentColor.idle
    }
  }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.layer.cornerRadius = 4
    addSubview(dot)
    ring.fillColor = nil
    ring.lineWidth = 2
    ring.lineCap = .round
    layer.addSublayer(ring)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 12),
      heightAnchor.constraint(equalToConstant: 12),
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),
      dot.centerXAnchor.constraint(equalTo: centerXAnchor),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func set(status: String) {
    let working = status == "working"
    dot.isHidden = working
    dot.backgroundColor = Self.color(for: status)
    ring.isHidden = !working
    ring.strokeColor = AgentColor.working.cgColor
    if working, !UIAccessibility.isReduceMotionEnabled {
      if ring.animation(forKey: "spin") == nil {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.toValue = CGFloat.pi * 2
        spin.duration = 0.8
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
      }
    } else {
      ring.removeAnimation(forKey: "spin")
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // An 8 pt ring with a quarter gap, as the official spinner's transparent top border.
    ring.frame = bounds
    let rect = bounds.insetBy(dx: 3, dy: 3)
    ring.path = UIBezierPath(
      arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: -.pi / 4,
      endAngle: .pi * 5 / 4, clockwise: true
    ).cgPath
  }
}

struct WorkspaceRowConfiguration: UIContentConfiguration {
  let worktree: Worktree
  /// The project heading above the row, when the list groups by project: a main checkout named the same
  /// reads as its branch (or "Project folder") instead of repeating the heading.
  var projectName: String? = nil

  func makeContentView() -> UIView & UIContentView { WorkspaceRowView(configuration: self) }
  func updated(for state: UIConfigurationState) -> WorkspaceRowConfiguration { self }
}

enum WorkspaceAgentRole: Hashable {
  case worker, subagent

  var title: String {
    switch self {
    case .worker: String(localized: "orcaios.agents.worker", defaultValue: "Orca worker")
    case .subagent: String(localized: "orcaios.agents.subagent", defaultValue: "Subagent")
    }
  }
}

/// A workspace row (worktree/row-presentation/WorktreeListRow.tsx): status column, the name with its glyphs,
/// the live terminal count, and one line per agent underneath.
final class WorkspaceRowView: UIView, UIContentView {
  /// accent 2 + lg 16 + indicator 20 + sm 8 (worktree-list-row-layout.ts).
  static let textInset: CGFloat = 2 + Spacing.lg + 20 + Spacing.sm

  private let indicator = AgentStatusDot()
  private let name = TextLabel(size: 14, weight: .semibold)
  private let glyphs = UIStackView()
  private let terminalCount = TextLabel(size: Typography.metaSize, color: Palette.textMuted, tabular: true)
  private let agents = UIStackView()

  var configuration: UIContentConfiguration { didSet { apply() } }

  init(configuration: WorkspaceRowConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    glyphs.axis = .horizontal
    glyphs.spacing = Spacing.sm
    glyphs.alignment = .center
    agents.axis = .vertical
    agents.spacing = 0
    let nameRow = UIStackView(arrangedSubviews: [name, glyphs, UIView(), terminalCount])
    nameRow.axis = .horizontal
    nameRow.spacing = Spacing.sm
    nameRow.alignment = .center
    let main = UIStackView(arrangedSubviews: [nameRow, agents])
    main.axis = .vertical
    main.translatesAutoresizingMaskIntoConstraints = false
    addSubview(indicator)
    addSubview(main)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    terminalCount.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      // The 20 pt indicator column, its 12 pt dot centred, 6 pt from the top padding.
      indicator.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 2 + Spacing.lg + 10),
      indicator.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md + 6 - 2),
      main.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
      main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      main.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
      main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
    ])
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let worktree = (configuration as? WorkspaceRowConfiguration)?.worktree else { return }
    indicator.set(status: worktree.displayStatus)
    let title = worktree.displayName.isEmpty ? worktree.repo : worktree.displayName
    let projectName = (configuration as? WorkspaceRowConfiguration)?.projectName
    if worktree.isMainWorktree, let projectName, title == projectName {
      let branch = worktree.branch.replacingOccurrences(of: "refs/heads/", with: "")
      name.text = branch.isEmpty ? String(localized: "orcaios.host.projectFolder", defaultValue: "Project folder") : branch
    } else {
      name.text = title
    }
    name.font = .systemFont(ofSize: 14, weight: worktree.unread ? .bold : .semibold)

    glyphs.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if !worktree.comment.isEmpty { glyphs.addArrangedSubview(LucideView(.stickyNote, size: 13, strokeWidth: 2, color: Palette.textMuted)) }
    if worktree.liveTerminalCount > 0 || !worktree.agents.isEmpty {
      glyphs.addArrangedSubview(LucideView(.squareTerminal, size: 13, strokeWidth: 2, color: Palette.textMuted))
    }
    terminalCount.text = worktree.liveTerminalCount > 0 && worktree.agents.isEmpty ? "\(worktree.liveTerminalCount)" : nil
    terminalCount.isHidden = terminalCount.text == nil

    agents.arrangedSubviews.forEach { $0.removeFromSuperview() }
    var labels: [String] = []
    func addChild(_ branch: AgentBranch<Worktree.Agent.Child>, depth: Int) {
      let child = branch.entry
      let label = child.label ?? WorkspaceAgentRole.subagent.title
      agents.addArrangedSubview(AgentLineView(
        title: label, role: .subagent, detail: child.detail, state: child.state, agentType: child.agentType,
        updatedAt: child.updatedAt, depth: depth))
      labels.append(child.label.map { "\(WorkspaceAgentRole.subagent.title), \($0)" } ?? label)
      for child in branch.children { addChild(child, depth: depth + 1) }
    }
    func addAgent(_ branch: AgentBranch<Worktree.Agent>, depth: Int) {
      let agent = branch.entry
      let role: WorkspaceAgentRole? = agent.parentPaneKey != nil ? .worker : nil
      agents.addArrangedSubview(AgentLineView(
        title: agent.title, role: role, detail: agent.lastAssistantMessage, state: agent.mainState ?? agent.state,
        agentType: agent.agentType, updatedAt: agent.updatedAt, depth: depth))
      labels.append([role?.title, agent.title].compactMap { $0 }.joined(separator: ", "))
      for child in agent.childLineage { addChild(child, depth: depth + 1) }
      for worker in branch.children { addAgent(worker, depth: depth + 1) }
    }
    for root in Worktree.Agent.lineage(worktree.agents) { addAgent(root, depth: 0) }
    // An empty stack has no height of its own; hidden, the row's height comes from the name alone.
    agents.isHidden = labels.isEmpty
    glyphs.isHidden = glyphs.arrangedSubviews.isEmpty
    isAccessibilityElement = true
    accessibilityLabel = ([name.text ?? ""] + labels).joined(separator: ", ")
  }
}

/// One agent under its workspace (worktree/agent-lineage/presentation/WorktreeAgentRow.tsx): dot, mark,
/// "title · last message", and how long ago.
private final class AgentLineView: UIView {
  init(title: String, role: WorkspaceAgentRole?, detail: String?, state: String, agentType: String?, updatedAt: Double?, depth: Int) {
    super.init(frame: .zero)
    let dot = UIView()
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.backgroundColor = AgentStatusDot.color(for: state)
    dot.layer.cornerRadius = 3
    let mark = FilledIconView(size: 14)
    mark.icon = AgentMark.icon(for: agentType)
    let roleName = role?.title
    let summary = [roleName == title ? nil : roleName, title, detail].compactMap { $0 }.filter { !$0.isEmpty }
      .map(MarkdownPreview.plain).joined(separator: " · ")
    let text = TextLabel(summary, size: 12, color: Palette.textSecondary)
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let time = TextLabel(RelativeTime.short(updatedAt), size: 11, color: Palette.textMuted)
    time.setContentCompressionResistancePriority(.required, for: .horizontal)
    var contents: [UIView] = []
    if depth > 0 { contents.append(LucideView(.cornerDownRight, size: 11, strokeWidth: 2, color: Palette.textMuted)) }
    contents.append(dot)
    if mark.icon != nil { contents.append(mark) }
    contents += [text, time]
    let row = UIStackView(arrangedSubviews: contents)
    row.axis = .horizontal
    row.spacing = Spacing.xs + 2
    row.alignment = .center
    row.setCustomSpacing(Spacing.md, after: text)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(min(depth, 3)) * 12),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum RelativeTime {
  /// "just now", "5m", "3h", "2d", from an epoch-milliseconds timestamp.
  static func short(_ milliseconds: Double?) -> String? {
    // Zero is a host's "never", not 1970.
    guard let milliseconds, milliseconds > 0 else { return nil }
    let seconds = max(0, Date().timeIntervalSince1970 - milliseconds / 1000)
    if seconds < 60 { return String(localized: "worktree.agentRowDisplay.justNow", defaultValue: "just now") }
    // Whole units, rounded down, as the official rows count them: "2 小时" until the third hour is up.
    let minutes = Int(seconds / 60)
    let (key, value): (String.LocalizationValue, Int) =
      minutes < 60
      ? ("orcaios.time.minutes", minutes)
      : minutes < 60 * 24
        ? ("orcaios.time.hours", minutes / 60)
        : minutes < 60 * 24 * 7 ? ("orcaios.time.days", minutes / (60 * 24)) : ("orcaios.time.weeks", minutes / (60 * 24 * 7))
    return String.localizedStringWithFormat(String(localized: key), value)
  }
}

/// Section headings on the workspace list: "Bots 0 +" and a collapsible project heading.
final class WorkspaceSectionHeader: UICollectionReusableView {
  private let chevron = LucideView(.chevronDown, size: 14, strokeWidth: 2, color: Palette.textSecondary)
  private let folder = LucideView(.folder, size: 15, strokeWidth: 1.8, color: Palette.textSecondary)
  private let pin = LucideView(.pin, size: 15, strokeWidth: 1.8, color: Palette.textSecondary)
  private let title = TextLabel(size: 14, weight: .medium, color: Palette.textSecondary)
  private let count = TextLabel(size: 14, color: Palette.textSecondary, tabular: true)
  private let add = UIButton(configuration: .plain())
  private var onTap: (() -> Void)?
  private var onAdd: (() -> Void)?
  private var leading: NSLayoutConstraint!

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Palette.bgBase
    add.configuration?.image = Lucide.plus.image(size: 18, strokeWidth: 2)
    add.configuration?.baseForegroundColor = Palette.textSecondary
    add.translatesAutoresizingMaskIntoConstraints = false
    add.accessibilityLabel = String(localized: "bots.new.title", defaultValue: "New bot")
    add.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .primaryActionTriggered)
    let row = UIStackView(arrangedSubviews: [chevron, folder, pin, title, count])
    row.axis = .horizontal
    row.spacing = Spacing.sm
    row.alignment = .center
    row.setCustomSpacing(Spacing.md, after: chevron)
    row.setCustomSpacing(6, after: title)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    addSubview(add)
    leading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2 + Spacing.lg + 3)
    NSLayoutConstraint.activate([
      leading,
      row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.sm),
      add.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func tapped() { onTap?() }

  func configureBots(count botCount: Int, onAdd: @escaping () -> Void) {
    self.onAdd = onAdd
    chevron.isHidden = true
    folder.isHidden = true
    pin.isHidden = true
    // The Bots heading's text starts where workspace names do.
    title.text = String(localized: "bots.section.title", defaultValue: "Bots")
    count.text = "\(botCount)"
    add.isHidden = false
    leading.constant = WorkspaceRowView.textInset
    onTap = nil
    accessibilityTraits = .header
  }

  /// A lane that isn't a project (workspace-list-sections.ts): Pinned, All, a status or a PR state.
  func configureLane(
    title text: String, count rowCount: Int, pinned: Bool, collapsed: Bool, onTap: @escaping () -> Void
  ) {
    configureProject(name: text, count: rowCount, collapsed: collapsed, onTap: onTap)
    folder.isHidden = true
    pin.isHidden = !pinned
  }

  func configureProject(name: String, count rowCount: Int, collapsed: Bool, onTap: @escaping () -> Void) {
    chevron.isHidden = false
    folder.isHidden = false
    pin.isHidden = true
    chevron.transform = collapsed ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity
    title.text = name
    count.text = "\(rowCount)"
    add.isHidden = true
    leading.constant = 2 + Spacing.lg + 3
    self.onTap = onTap
    accessibilityTraits = [.header, .button]
  }
}
