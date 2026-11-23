import OrcaCore
import UIKit

/// The session's tab strip (session/tabs/MobileSessionTabBar.tsx): the open tab, the tab count, and +.
final class SessionTabStrip: UIView {
  /// The open tabs, to switch to or close; built when the count is tapped.
  var tabsMenu: (() -> UIMenu)?
  /// What a new tab can be; built when + is tapped.
  var newTabMenu: (() -> UIMenu)?

  private let tabCell = UIView()
  private let underline = UIView()
  private let dot = UIView()
  /// A working agent spins here instead of a coloured dot, which nobody read as "working".
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let agentMark = FilledIconView(size: 14)
  private let kindIcon = LucideView(.squareTerminal, size: 14, strokeWidth: 2.1, color: Palette.textSecondary)
  private let title = TextLabel(size: 14, weight: .semibold)
  private let countBox = UIView()
  private let count = TextLabel(size: 11, weight: .bold, alignment: .center, tabular: true)
  private let countButton = PressableControl()
  private let addButton = PressableControl()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Palette.bgBase
    let topLine = Hairline()
    topLine.heightAnchor.constraint(equalToConstant: 1).isActive = true

    tabCell.translatesAutoresizingMaskIntoConstraints = false
    tabCell.backgroundColor = Palette.bgRaised
    underline.translatesAutoresizingMaskIntoConstraints = false
    underline.backgroundColor = Palette.textSecondary
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.layer.cornerRadius = 3
    spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
    spinner.hidesWhenStopped = true
    spinner.color = Palette.textSecondary
    let content = UIStackView(arrangedSubviews: [dot, spinner, agentMark, kindIcon, title])
    content.axis = .horizontal
    content.spacing = 6
    content.alignment = .center
    content.translatesAutoresizingMaskIntoConstraints = false
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    tabCell.addSubview(content)
    tabCell.addSubview(underline)

    countBox.translatesAutoresizingMaskIntoConstraints = false
    countBox.isUserInteractionEnabled = false
    countBox.layer.cornerRadius = 6
    countBox.layer.borderWidth = 1.8
    countBox.addSubview(count)
    countButton.addSubview(countBox)
    attachMenu(to: countButton) { [weak self] in self?.tabsMenu?() }
    countButton.onPressedChange = { [weak countButton] pressed in
      countButton?.backgroundColor = pressed ? Palette.translucentFill : .clear
    }
    let plus = LucideView(.plus, size: 18, strokeWidth: 2.2)
    addButton.addSubview(plus)
    attachMenu(to: addButton) { [weak self] in self?.newTabMenu?() }
    addButton.onPressedChange = { [weak addButton] pressed in
      addButton?.backgroundColor = pressed ? Palette.translucentFill : .clear
    }
    addButton.accessibilityLabel = String(localized: "session.tabStrip.newTab", defaultValue: "New tab")

    let divider1 = Self.verticalLine()
    let divider2 = Self.verticalLine()
    for view in [topLine, tabCell, divider1, countButton, divider2, addButton] as [UIView] { addSubview(view) }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 44),
      topLine.topAnchor.constraint(equalTo: topAnchor),
      topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
      topLine.trailingAnchor.constraint(equalTo: trailingAnchor),

      tabCell.leadingAnchor.constraint(equalTo: leadingAnchor),
      tabCell.topAnchor.constraint(equalTo: topLine.bottomAnchor),
      tabCell.bottomAnchor.constraint(equalTo: bottomAnchor),
      tabCell.trailingAnchor.constraint(equalTo: divider1.leadingAnchor),
      content.leadingAnchor.constraint(equalTo: tabCell.leadingAnchor, constant: Spacing.lg),
      content.trailingAnchor.constraint(lessThanOrEqualTo: tabCell.trailingAnchor, constant: -Spacing.sm),
      content.centerYAnchor.constraint(equalTo: tabCell.centerYAnchor, constant: -1),
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),
      underline.leadingAnchor.constraint(equalTo: tabCell.leadingAnchor),
      underline.trailingAnchor.constraint(equalTo: tabCell.trailingAnchor),
      underline.bottomAnchor.constraint(equalTo: tabCell.bottomAnchor),
      underline.heightAnchor.constraint(equalToConstant: 2),

      divider1.topAnchor.constraint(equalTo: topLine.bottomAnchor),
      divider1.bottomAnchor.constraint(equalTo: bottomAnchor),
      countButton.leadingAnchor.constraint(equalTo: divider1.trailingAnchor),
      countButton.topAnchor.constraint(equalTo: topLine.bottomAnchor),
      countButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      countButton.widthAnchor.constraint(equalToConstant: 46),
      countBox.centerXAnchor.constraint(equalTo: countButton.centerXAnchor),
      countBox.centerYAnchor.constraint(equalTo: countButton.centerYAnchor),
      countBox.heightAnchor.constraint(equalToConstant: 19),
      countBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 19),
      count.leadingAnchor.constraint(equalTo: countBox.leadingAnchor, constant: 3),
      count.trailingAnchor.constraint(equalTo: countBox.trailingAnchor, constant: -3),
      count.centerYAnchor.constraint(equalTo: countBox.centerYAnchor),
      divider2.leadingAnchor.constraint(equalTo: countButton.trailingAnchor),
      divider2.topAnchor.constraint(equalTo: topLine.bottomAnchor),
      divider2.bottomAnchor.constraint(equalTo: bottomAnchor),
      addButton.leadingAnchor.constraint(equalTo: divider2.trailingAnchor),
      addButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      addButton.topAnchor.constraint(equalTo: topLine.bottomAnchor),
      addButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 46),
      plus.centerXAnchor.constraint(equalTo: addButton.centerXAnchor),
      plus.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
    ])
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// A clear system button over the pressable area, so a tap opens a native menu built at that moment.
  private func attachMenu(to control: UIView, menu: @escaping () -> UIMenu?) {
    let button = UIButton(type: .custom)
    button.showsMenuAsPrimaryAction = true
    button.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { completion in completion(menu()?.children ?? []) }
    ])
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = control.accessibilityLabel
    control.addSubview(button)
    button.pin(to: control)
  }

  private static func verticalLine() -> UIView {
    let line = UIView()
    line.translatesAutoresizingMaskIntoConstraints = false
    line.backgroundColor = Palette.borderSubtle
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    return line
  }

  func show(tab: SessionTab?, tabCount: Int, agentState: String?, botHome: Bool = false) {
    // A bot's home chat reads as the desktop names it.
    title.text = botHome && tab?.title == "Home"
      ? String(localized: "bots.tabs.homeTitle", defaultValue: "Home") : tab?.title ?? ""
    count.text = "\(tabCount)"
    countButton.accessibilityLabel = "\(tabCount)"
    var agent: String?
    switch tab?.kind {
    case .agentSession(_, let id): agent = id
    case .terminal: agent = tab?.launchAgent
    default: agent = nil
    }
    let mark = AgentMark.icon(for: agent)
    agentMark.icon = mark
    agentMark.isHidden = mark == nil
    kindIcon.isHidden = mark != nil
    switch tab?.kind {
    case .browser: kindIcon.icon = .globe
    case .file, .markdown: kindIcon.icon = .fileText
    default: kindIcon.icon = .squareTerminal
    }
    // Working spins; waiting on you is the attention dot; idle or done shows nothing.
    let state = agentState ?? "idle"
    let working = state == "working" || state == "monitoring"
    if working { spinner.startAnimating() } else { spinner.stopAnimating() }
    // The agent's mark gives way to the spinner, so the tab doesn't grow while it works.
    if working { agentMark.isHidden = true; kindIcon.isHidden = true }
    let attention = ["permission", "waiting", "blocked", "failed"].contains(state)
    dot.isHidden = !attention
    dot.backgroundColor = AgentStatusDot.color(for: state)
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    updateColors()
  }

  private func updateColors() {
    countBox.layer.borderColor = Palette.textPrimary.resolvedColor(with: traitCollection).cgColor
  }
}
