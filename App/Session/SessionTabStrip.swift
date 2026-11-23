import OrcaCore
import UIKit

/// The session's tabs as iGhostVT's strip draws them: every open tab as a chip in one glass capsule, sharing
/// its width as Safari's do and scrolling once they would get too narrow, the shown one on a soft capsule;
/// a glass + beside it for a new tab. A working agent's chip spins; one waiting on you carries the
/// attention dot. Long-pressing a chip offers to close it.
final class SessionTabStrip: UIView {
  /// What a new tab can be; built when + is tapped.
  var newTabMenu: (() -> UIMenu)?
  var onSelect: ((SessionTab) -> Void)?
  var onClose: ((SessionTab) -> Void)?

  private let capsule = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let scroll = UIScrollView()
  private let chips = UIStackView()
  private let addButton = UIButton(configuration: .glass())
  private var tabs: [SessionTab] = []
  private var shownId: String?
  private var agentState: String?
  private var botHome = false
  private var widths: [NSLayoutConstraint] = []

  /// The narrowest a chip gets before the strip scrolls instead.
  private static let minimumChip: CGFloat = 112
  static let height: CGFloat = 52

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Palette.bgBase

    capsule.cornerConfiguration = .capsule()
    capsule.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    chips.spacing = 2
    chips.alignment = .center
    chips.translatesAutoresizingMaskIntoConstraints = false
    capsule.contentView.addSubview(scroll)
    scroll.addSubview(chips)

    addButton.configuration?.image = Lucide.plus.image(size: 18, strokeWidth: 2.2)
    addButton.configuration?.baseForegroundColor = Palette.textPrimary
    addButton.configuration?.cornerStyle = .capsule
    addButton.showsMenuAsPrimaryAction = true
    addButton.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.newTabMenu?().children ?? []) }
    ])
    addButton.accessibilityLabel = String(localized: "session.tabStrip.newTab", defaultValue: "New tab")
    addButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(capsule)
    addSubview(addButton)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
      capsule.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -Spacing.sm),
      capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
      capsule.heightAnchor.constraint(equalToConstant: 40),
      addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
      addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 40),
      addButton.heightAnchor.constraint(equalToConstant: 40),
      scroll.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 4),
      scroll.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -4),
      scroll.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
      chips.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      chips.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      chips.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      chips.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      chips.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(tabs: [SessionTab], shownId: String?, agentState: String?, botHome: Bool = false) {
    guard tabs != self.tabs || shownId != self.shownId || agentState != self.agentState || botHome != self.botHome
    else { return }
    let same = tabs.map(\.id) == self.tabs.map(\.id)
    self.tabs = tabs
    self.shownId = shownId
    self.agentState = agentState
    self.botHome = botHome
    if same, chips.arrangedSubviews.count == tabs.count {
      for (chip, tab) in zip(chips.arrangedSubviews.compactMap { $0 as? TabChip }, tabs) { configure(chip, tab) }
    } else {
      chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
      widths = []
      for tab in tabs {
        let chip = TabChip()
        chip.addAction(UIAction { [weak self, weak chip] _ in
          guard let self, let chip, let tab = self.tabs.first(where: { $0.id == chip.tabId }) else { return }
          UISelectionFeedbackGenerator().selectionChanged()
          self.onSelect?(tab)
        }, for: .touchUpInside)
        chip.addInteraction(UIContextMenuInteraction(delegate: self))
        chips.addArrangedSubview(chip)
        let width = chip.widthAnchor.constraint(equalToConstant: Self.minimumChip)
        width.isActive = true
        widths.append(width)
        configure(chip, tab)
      }
      setNeedsLayout()
    }
    revealShown()
  }

  private func configure(_ chip: TabChip, _ tab: SessionTab) {
    let shown = tab.id == shownId
    var agent: String?
    switch tab.kind {
    case .agentSession(_, let id): agent = id
    case .terminal: agent = tab.launchAgent
    default: agent = nil
    }
    let icon: Lucide =
      switch tab.kind {
      case .browser: .globe
      case .file, .markdown: .fileText
      default: .squareTerminal
      }
    let title =
      botHome && tab.title == "Home"
      ? String(localized: "bots.tabs.homeTitle", defaultValue: "Home")
      : tab.title.isEmpty ? String(localized: "session.header.terminalTitle", defaultValue: "Terminal") : tab.title
    // The workspace's agent state belongs to the tab on screen; the others stay quiet.
    chip.show(
      id: tab.id, title: title, mark: AgentMark.icon(for: agent), icon: icon, shown: shown,
      filled: shown && tabs.count > 1, state: shown ? agentState : nil)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Equal shares of the capsule, as Safari's tabs; past the minimum the strip scrolls.
    let available = scroll.bounds.width - CGFloat(max(tabs.count - 1, 0)) * chips.spacing
    let share = tabs.isEmpty ? 0 : max(Self.minimumChip, floor(available / CGFloat(tabs.count)))
    for width in widths where abs(width.constant - share) > 0.5 { width.constant = share }
  }

  private func revealShown() {
    guard let index = tabs.firstIndex(where: { $0.id == shownId }), index < chips.arrangedSubviews.count else { return }
    layoutIfNeeded()
    let frame = chips.arrangedSubviews[index].frame
    scroll.scrollRectToVisible(frame.insetBy(dx: -8, dy: 0), animated: window != nil)
  }
}

extension SessionTabStrip: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint)
    -> UIContextMenuConfiguration?
  {
    guard let chip = interaction.view as? TabChip, let tab = tabs.first(where: { $0.id == chip.tabId }) else { return nil }
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      UIMenu(children: [
        UIAction(
          title: String(localized: "session.bulkTabClose.confirm", defaultValue: "Close tab"),
          image: Lucide.x.image(size: 18), attributes: .destructive
        ) { _ in self?.onClose?(tab) }
      ])
    })
  }
}

/// One tab: its agent's mark or its kind's icon (a spinner while its agent works), and its title. The shown
/// tab reads in the primary colour on a soft capsule; the rest are bare, secondary text.
private final class TabChip: UIControl {
  private(set) var tabId: String?
  private let fill = UIView()
  private let mark = FilledIconView(size: 14)
  private let icon = LucideView(.squareTerminal, size: 14, strokeWidth: 2.1, color: Palette.textSecondary)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let dot = UIView()
  private let title = TextLabel(size: 14, lines: 1)

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    fill.isUserInteractionEnabled = false
    fill.layer.cornerRadius = 16
    fill.layer.cornerCurve = .continuous
    fill.translatesAutoresizingMaskIntoConstraints = false
    addSubview(fill)
    spinner.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
    spinner.hidesWhenStopped = true
    spinner.color = Palette.textSecondary
    dot.layer.cornerRadius = 3
    dot.translatesAutoresizingMaskIntoConstraints = false
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [dot, spinner, mark, icon, title])
    row.spacing = 6
    row.alignment = .center
    row.isUserInteractionEnabled = false
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 32),
      fill.leadingAnchor.constraint(equalTo: leadingAnchor),
      fill.trailingAnchor.constraint(equalTo: trailingAnchor),
      fill.topAnchor.constraint(equalTo: topAnchor),
      fill.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      row.centerXAnchor.constraint(equalTo: centerXAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),
    ])
    isAccessibilityElement = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(id: String, title text: String, mark agentMark: FilledIcon?, icon kind: Lucide, shown: Bool, filled: Bool, state: String?) {
    tabId = id
    title.text = text
    title.font = .systemFont(ofSize: 14, weight: shown ? .semibold : .regular)
    title.textColor = shown ? Palette.textPrimary : Palette.textSecondary
    fill.backgroundColor = filled ? Palette.textPrimary.withAlphaComponent(0.12) : .clear
    let working = state == "working" || state == "monitoring"
    if working { spinner.startAnimating() } else { spinner.stopAnimating() }
    mark.icon = agentMark
    mark.isHidden = agentMark == nil || working
    icon.icon = kind
    icon.isHidden = agentMark != nil || working
    let attention = ["permission", "waiting", "blocked", "failed"].contains(state ?? "")
    dot.isHidden = !attention
    dot.backgroundColor = AgentStatusDot.color(for: state ?? "idle")
    accessibilityLabel = text
    accessibilityTraits = shown ? [.button, .selected] : .button
  }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.6 : 1 }
  }
}
