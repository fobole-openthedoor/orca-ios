import OrcaCore
import UIKit

/// A bot's picture (bots/MobileBotAvatar.tsx): the mascot on its tile colour, with the light rim on a dark
/// colour; otherwise its initial on the raised fill. Corners are a quarter of the size.
final class BotAvatarView: UIView {
  private let rim = UIImageView()
  private let mascot = UIImageView()
  private let letter = TextLabel(size: 14, weight: .semibold, alignment: .center)
  private let size: CGFloat

  static let defaultColor = UIColor(hex: 0xb3dbf4)

  init(size: CGFloat) {
    self.size = size
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerRadius = size / 4
    clipsToBounds = true
    for view in [rim, mascot] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.contentMode = .scaleAspectFill
      addSubview(view)
      view.pin(to: self)
    }
    letter.font = .systemFont(ofSize: (size * 0.6).rounded(), weight: .semibold)
    addSubview(letter)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
      letter.centerXAnchor.constraint(equalTo: centerXAnchor), letter.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The mascots bundled with the app, by id.
  static let mascotIds: [String] = {
    let names = Bundle.main.urls(forResourcesWithExtension: "webp", subdirectory: nil)?.map {
      $0.deletingPathExtension().lastPathComponent
    } ?? []
    return names.filter { !$0.hasSuffix("-rim") }.sorted()
  }()

  /// A mascot on its default tile, before a bot has it.
  func show(mascot id: String) {
    guard let picture = Self.image(id) else { return }
    backgroundColor = Self.defaultColor
    mascot.image = picture
    rim.image = nil
    letter.isHidden = true
  }

  func show(_ bot: Bot) {
    if let id = bot.mascotId, let picture = Self.image("\(id)") {
      let color = bot.avatarColor.flatMap(Self.color) ?? Self.defaultColor
      backgroundColor = color
      mascot.image = picture
      rim.image = Self.isDark(color) ? Self.image("\(id)-rim") : nil
      letter.isHidden = true
    } else {
      backgroundColor = Palette.bgRaised
      mascot.image = nil
      rim.image = nil
      letter.isHidden = false
      // An emoji avatar draws itself; anything else falls back to the name's first letter.
      let text = bot.avatar.flatMap { $0.count <= 2 ? $0 : nil } ?? bot.name.first.map { String($0).uppercased() } ?? "?"
      letter.text = text
    }
  }

  private static var cache: [String: UIImage] = [:]

  private static func image(_ name: String) -> UIImage? {
    if let cached = cache[name] { return cached }
    guard let url = Bundle.main.url(forResource: name, withExtension: "webp"), let image = UIImage(contentsOfFile: url.path)
    else { return nil }
    cache[name] = image
    return image
  }

  private static func color(_ hex: String) -> UIColor? {
    guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return UIColor(hex: value)
  }

  /// shared/bots/bot-avatar-color.ts isDarkBotAvatarColor: relative luminance under 0.18.
  private static func isDark(_ color: UIColor) -> Bool {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: nil)
    func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b) < 0.18
  }
}

/// A bot on Home and in the Bots tab (home/MobileHomeBots.tsx): avatar, name, then its desktop's chip, its
/// latest words and how long ago.
struct BotRowConfiguration: UIContentConfiguration {
  let bot: Bot
  let hostName: String?
  let latest: String?
  let updatedAt: Double?
  let needsYou: Int
  /// Grouped rows sit 16 pt in from the group's edge; plain rows from the screen's.
  var inset: CGFloat = Spacing.lg
  /// Whether its chats show under it; nil draws no chevron.
  var unfolded: Bool? = nil
  var onToggle: (() -> Void)? = nil

  func makeContentView() -> UIView & UIContentView { BotRowView(configuration: self) }
  func updated(for state: UIConfigurationState) -> BotRowConfiguration { self }

  /// The desktop's word for a bot's state (host-bot-row-facts.ts botStatusLine).
  static func statusWord(_ bot: Bot, home: Worktree?) -> String {
    if bot.paused { return String(localized: "bots.row.paused", defaultValue: "Paused") }
    switch home?.displayStatus {
    case "working": return String(localized: "sidebar.cardSlot.working", defaultValue: "Working")
    case "permission": return String(localized: "workspace.activity.permission", defaultValue: "Needs permission")
    default: return String(localized: "bots.row.idle", defaultValue: "Idle")
    }
  }

  @MainActor static func make(bot: Bot, session: HostSession, showHost: Bool) -> BotRowConfiguration {
    // The bot's home workspace carries its latest line, as the desktop's sidebar shows it.
    let home = session.worktree(id: bot.homeWorktreeId)
    let agent = home?.agents.max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }
    // With nothing said yet, the row reads the bot's state, as the desktop's does.
    let latest = [agent?.lastAssistantMessage, home?.preview].compactMap { $0 }.first { !$0.isEmpty }
      ?? statusWord(bot, home: home)
    return BotRowConfiguration(
      bot: bot, hostName: showHost ? session.name : nil,
      latest: latest.replacingOccurrences(of: "\n", with: " "), updatedAt: agent?.updatedAt ?? home?.lastActivityAt,
      needsYou: session.bots.needsYou[bot.id] ?? 0)
  }
}

private final class BotRowView: UIView, UIContentView {
  private let avatar = BotAvatarView(size: 32)
  // bots/MobileBotHomeRow.tsx: a 15 pt medium name over the host pill (10 pt), a 13 pt preview and an 11 pt age.
  private let name = TextLabel(size: 15, weight: .medium)
  private let chip = UIView()
  private let chipLabel = TextLabel(size: 10, color: Palette.textMuted)
  private let latest = TextLabel(size: 13, color: Palette.textMuted)
  private let time = TextLabel(size: 11, color: Palette.textMuted, tabular: true)
  private let count = UIView()
  private let countLabel = TextLabel(size: 12, weight: .bold, color: .black, alignment: .center, tabular: true)
  private var leading: NSLayoutConstraint!
  private let line = UIStackView()
  private let fold = UIButton(type: .system)

  var configuration: UIContentConfiguration { didSet { apply() } }

  init(configuration: BotRowConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    chip.backgroundColor = Palette.bgRaised
    chip.layer.cornerRadius = 7
    let monitor = LucideView(.monitor, size: 10, strokeWidth: 2, color: Palette.textMuted)
    let chipRow = UIStackView(arrangedSubviews: [monitor, chipLabel])
    chipRow.spacing = 3
    chipRow.alignment = .center
    chipRow.translatesAutoresizingMaskIntoConstraints = false
    chip.addSubview(chipRow)
    count.backgroundColor = Palette.statusAmber
    count.layer.cornerRadius = 10
    count.addSubview(countLabel)
    line.addArrangedSubview(chip)
    line.addArrangedSubview(latest)
    line.spacing = Spacing.sm
    line.alignment = .center
    latest.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    chip.setContentCompressionResistancePriority(.required, for: .horizontal)
    let text = UIStackView(arrangedSubviews: [name, line])
    text.axis = .vertical
    text.spacing = 3
    text.alignment = .leading
    text.translatesAutoresizingMaskIntoConstraints = false
    let trailing = UIStackView(arrangedSubviews: [count, time])
    trailing.spacing = 6
    trailing.alignment = .center
    trailing.translatesAutoresizingMaskIntoConstraints = false
    time.setContentCompressionResistancePriority(.required, for: .horizontal)
    fold.tintColor = Palette.textMuted
    fold.translatesAutoresizingMaskIntoConstraints = false
    fold.addAction(
      UIAction { [weak self] _ in
        UISelectionFeedbackGenerator().selectionChanged()
        (self?.configuration as? BotRowConfiguration)?.onToggle?()
      }, for: .primaryActionTriggered)
    for view in [avatar, text, trailing, fold] as [UIView] { addSubview(view) }
    leading = avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg)
    NSLayoutConstraint.activate([
      leading,
      // At least 64 pt, the picture and the text centred in it.
      heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
      avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
      text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Spacing.md),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Spacing.sm),
      text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Spacing.sm),
      text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Spacing.sm),
      trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      trailing.lastBaselineAnchor.constraint(equalTo: latest.lastBaselineAnchor),
      chipRow.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
      chipRow.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
      chipRow.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
      chipRow.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1),
      // A 44 pt target around the 14 pt chevron, its glyph at the row's trailing edge, level with the name.
      fold.widthAnchor.constraint(equalToConstant: 44),
      fold.heightAnchor.constraint(equalToConstant: 44),
      fold.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg - 7),
      fold.centerYAnchor.constraint(equalTo: name.centerYAnchor),
      count.heightAnchor.constraint(equalToConstant: 20),
      count.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
      countLabel.leadingAnchor.constraint(equalTo: count.leadingAnchor, constant: 6),
      countLabel.trailingAnchor.constraint(equalTo: count.trailingAnchor, constant: -6),
      countLabel.centerYAnchor.constraint(equalTo: count.centerYAnchor),
    ])
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let configuration = configuration as? BotRowConfiguration else { return }
    leading.constant = configuration.inset
    avatar.show(configuration.bot)
    name.text = configuration.bot.name
    // A paused bot reads as the desktop's dimmed row.
    name.textColor = configuration.bot.paused ? Palette.textMuted : Palette.textSecondary
    chip.isHidden = configuration.hostName == nil
    chipLabel.text = configuration.hostName
    latest.text = configuration.latest
    latest.isHidden = (configuration.latest ?? "").isEmpty
    // An empty stack has no height; with neither piece, the row is the name alone.
    line.isHidden = chip.isHidden && latest.isHidden
    time.text = RelativeTime.short(configuration.updatedAt)
    count.isHidden = configuration.needsYou == 0
    fold.isHidden = configuration.unfolded == nil
    fold.setImage((configuration.unfolded == true ? Lucide.chevronDown : Lucide.chevronRight).image(size: 14), for: .normal)
    fold.accessibilityLabel = String(
      format: configuration.unfolded == true
        ? String(localized: "bots.workspaces.hide", defaultValue: "Hide %@’s workspaces")
        : String(localized: "bots.workspaces.show", defaultValue: "Show %@’s workspaces"), configuration.bot.name)
    countLabel.text = "\(configuration.needsYou)"
    isAccessibilityElement = true
    accessibilityLabel = [configuration.bot.name, configuration.hostName, configuration.latest].compactMap { $0 }
      .joined(separator: ", ")
  }
}

/// A bot's Home Chat under its row (MobileBotChatRows.tsx): house, title, when it last spoke.
struct BotHomeChatRowConfiguration: UIContentConfiguration {
  let updatedAt: Double?

  func makeContentView() -> UIView & UIContentView { BotHomeChatRowView(configuration: self) }
  func updated(for state: UIConfigurationState) -> BotHomeChatRowConfiguration { self }
}

private final class BotHomeChatRowView: UIView, UIContentView {
  private let title = TextLabel(
    String(localized: "bots.chats.home", defaultValue: "Home Chat"), size: 15)
  private let time = TextLabel(size: 13, color: Palette.textMuted, tabular: true)

  var configuration: UIContentConfiguration { didSet { apply() } }

  init(configuration: BotHomeChatRowConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    let house = LucideView(.house, size: 16, strokeWidth: 2, color: Palette.textSecondary)
    for view in [house, title, time] as [UIView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    time.setContentCompressionResistancePriority(.required, for: .horizontal)
    let height = heightAnchor.constraint(equalToConstant: 44)
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([
      height,
      title.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 11),
      title.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -11),
      house.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
      house.centerYAnchor.constraint(equalTo: centerYAnchor),
      title.leadingAnchor.constraint(equalTo: house.trailingAnchor, constant: Spacing.sm),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -Spacing.sm),
      // The chevron column stays reserved, so times line up whether or not a chat folds.
      time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg - 20 - Spacing.sm),
      time.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let configuration = configuration as? BotHomeChatRowConfiguration else { return }
    time.text = RelativeTime.short(configuration.updatedAt)
    isAccessibilityElement = true
    accessibilityLabel = [title.text, time.text].compactMap { $0 }.joined(separator: ", ")
  }
}
