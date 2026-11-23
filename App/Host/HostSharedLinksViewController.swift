import OrcaCore
import UIKit

/// Host ⋯ › Shared links (host-screen/host-shared-links-sheet.tsx, bots/sharing/MobileSharedLinks.tsx): every
/// bot link the desktop's Orca account published, each with Copy link, Update link and Stop sharing.
final class HostSharedLinksViewController: SettingsPageViewController {
  private let session: HostSession
  private var shares: [BotOwnedShare]?
  private var error: String?
  private var busy = false

  static func sheet(session: HostSession) -> UIViewController {
    let navigation = UINavigationController(rootViewController: HostSharedLinksViewController(session: session))
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  init(session: HostSession) {
    self.session = session
    super.init()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.sharedLinks.title", defaultValue: "Shared links")
    navigationItem.subtitle = session.name
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    load()
  }

  override func updateProperties() {
    super.updateProperties()
    // Offline, the links stay listed but their actions wait for the desktop.
    _ = session.connectionState
    rebuild()
  }

  private var online: Bool { session.connectionState == .connected }

  private func load() {
    error = nil
    rebuild()
    let api = session.api
    Task {
      do {
        shares = try await api.botShares()
      } catch {
        self.error = Self.message(for: error)
      }
      rebuild()
    }
  }

  private func rebuild() {
    if let error {
      sections = [Section(footerView: Self.noteView(error, color: Palette.statusRed), rows: [])]
    } else if let shares {
      if shares.isEmpty {
        sections = [
          Section(
            footerView: Self.noteView(
              String(localized: "bots.share.noLinks", defaultValue: "No bot links. Share a bot from its settings."),
              color: Palette.textSecondary), rows: [])
        ]
      } else {
        // Canonical links first; older builds' links stay listed, so nothing is stopped silently.
        let ordered = shares.filter(\.canonical) + shares.filter { !$0.canonical }
        sections = [
          Section(
            header: String(localized: "settings.sharedLinks.bots", defaultValue: "Bots"),
            footer: String(localized: "settings.sharedLinks.description", defaultValue: "Links you’ve published."),
            rows: ordered.map { .custom(cell(for: $0)) })
        ]
      }
    } else {
      sections = [Section(rows: [.spinner(String(localized: "bots.share.loadingLinks", defaultValue: "Loading shared links…"))])]
    }
  }

  private func bot(for share: BotOwnedShare) -> Bot? {
    session.bots.bots.first { BotOwnedShare.packageName(botId: $0.id) == share.name }
  }

  private func cell(for share: BotOwnedShare) -> UITableViewCell {
    let cell = SharedLinkCell(style: .default, reuseIdentifier: nil)
    let bot = bot(for: share)
    let name = bot?.name ?? share.displayName ?? share.name
    var actions: [UIMenuElement] = [
      UIAction(title: String(localized: "bots.share.copyLink", defaultValue: "Copy link"), image: Lucide.copy.image(size: 18)) { _ in
        UIPasteboard.general.string = share.url
        Toast.shared.show(String(localized: "bots.share.linkCopied", defaultValue: "Link copied"))
      }
    ]
    // Update link rebuilds from the bot, so it needs the bot here; stopping needs only the link.
    if let bot {
      actions.append(
        UIAction(title: String(localized: "bots.share.updateLink", defaultValue: "Update link"), image: Lucide.refreshCw.image(size: 18)) {
          [weak self] _ in self?.update(share, bot: bot)
        })
    }
    actions.append(
      UIAction(
        title: String(localized: "bots.share.stopSharing", defaultValue: "Stop sharing"), image: Lucide.link2Off.image(size: 18),
        attributes: .destructive
      ) { [weak self] _ in self?.confirmStop(share, name: name, botId: bot?.id) })
    cell.show(
      share: share, bot: bot, name: name, enabled: online && !busy,
      menu: UIMenu(children: actions),
      menuLabel: String(format: String(localized: "bots.share.moreActions", defaultValue: "More actions for %1$@"), name))
    return cell
  }

  private func update(_ share: BotOwnedShare, bot: Bot) {
    busy = true
    rebuild()
    let api = session.api
    Task {
      defer {
        busy = false
        load()
      }
      do {
        try await api.updateBotShare(share, botId: bot.id)
        Toast.shared.show(String(localized: "bots.share.updatedJustNow", defaultValue: "Updated just now"))
      } catch {
        Toast.shared.show(Self.message(for: error), kind: .error)
      }
    }
  }

  private func confirmStop(_ share: BotOwnedShare, name: String, botId: String?) {
    let alert = UIAlertController(
      title: String(format: String(localized: "bots.share.stopTitle", defaultValue: "Stop sharing %1$@?"), name),
      message: String(localized: "bots.share.stopDescription", defaultValue: "The link stops working."), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "bots.share.stopSharing", defaultValue: "Stop sharing"), style: .destructive) {
        [weak self] _ in self?.stop(share, name: name, botId: botId)
      })
    present(alert, animated: true)
  }

  private func stop(_ share: BotOwnedShare, name: String, botId: String?) {
    busy = true
    rebuild()
    let api = session.api
    Task {
      defer { busy = false }
      do {
        try await api.stopBotShare(share.id, botId: botId)
        Toast.shared.show(String(format: String(localized: "bots.share.stopped", defaultValue: "Stopped sharing %1$@"), name))
        load()
      } catch {
        Toast.shared.show(Self.message(for: error), kind: .error)
        rebuild()
      }
    }
  }

  /// The desktop's share words for a failure (bot-share-copy.ts botShareErrorMessage).
  static func message(for error: Error) -> String {
    switch BotShareError.code(of: error) {
    case .blocked?:
      return String(
        localized: "bots.share.error.blocked", defaultValue: "A secret was found in what would be shared. Remove it, then try again.")
    case .noteSecret?:
      return String(
        localized: "bots.share.error.noteSecret",
        defaultValue: "The setup note looks like it holds a secret. Remove it, then try again.")
    case .expired?:
      return String(localized: "bots.share.error.expired", defaultValue: "This share preview expired. Open Share bot again.")
    case .prepareAgain?:
      return String(
        localized: "bots.share.error.prepareAgain",
        defaultValue: "This bot was shared from another window meanwhile. Open Share bot again.")
    case .stopped?:
      return String(localized: "bots.share.error.stopped", defaultValue: "This link was stopped. Publish to make a new link.")
    case .moved?:
      return String(
        localized: "bots.share.error.moved", defaultValue: "This link was updated somewhere else. Open Share bot again to see it.")
    case .unavailable?:
      return String(localized: "bots.share.error.unavailable", defaultValue: "Orca Cloud doesn’t accept bot shares yet.")
    case .avatarRefused?:
      return String(
        localized: "bots.share.error.avatarRefused",
        defaultValue: "Orca Cloud refused the bot’s picture. Pick another picture, then try again.")
    case .tooLarge?:
      return String(
        localized: "bots.share.error.tooLarge",
        defaultValue: "This bot is too large to share. Leave out some memory or skills, then try again.")
    case .signIn?:
      return String(localized: "bots.share.signIn", defaultValue: "Sign in to Orca to share.")
    case .reconnect?:
      return String(localized: "bots.share.reconnect", defaultValue: "Sign in to Orca again to share.")
    case nil:
      // Unlike the desktop, the phone has no log to read: the desktop's own reason is shown.
      if let error = error as? RPCError, !error.message.isEmpty { return error.message }
      return String(localized: "bots.errors.generic", defaultValue: "Something went wrong. Try again.")
    }
  }
}

/// One link (SharedLinkRow): the bot's picture, its name over the link in mono, the date, and a ⋯ menu.
private final class SharedLinkCell: UITableViewCell {
  private let avatar = BotAvatarView(size: 28)
  private let nameLabel = TextLabel(size: 17)
  private let urlLabel = TextLabel(size: 13, color: Palette.textSecondary)
  private let dateLabel = TextLabel(size: 15, color: Palette.textSecondary)
  private let more = UIButton(type: .system)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = Palette.bgRaised
    selectionStyle = .none
    urlLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    urlLabel.lineBreakMode = .byTruncatingMiddle
    dateLabel.setContentHuggingPriority(.required, for: .horizontal)
    dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    more.setImage(Lucide.ellipsis.image(size: 18, strokeWidth: 2), for: .normal)
    more.tintColor = Palette.textSecondary
    more.showsMenuAsPrimaryAction = true
    more.setContentHuggingPriority(.required, for: .horizontal)
    let text = UIStackView(arrangedSubviews: [nameLabel, urlLabel])
    text.axis = .vertical
    text.spacing = 2
    let row = UIStackView(arrangedSubviews: [avatar, text, dateLabel, more])
    row.alignment = .center
    row.spacing = Spacing.md
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      more.widthAnchor.constraint(equalToConstant: 32),
      more.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(share: BotOwnedShare, bot: Bot?, name: String, enabled: Bool, menu: UIMenu, menuLabel: String) {
    avatar.isHidden = bot == nil
    if let bot { avatar.show(bot) }
    nameLabel.text = name
    urlLabel.text = share.urlText
    dateLabel.text = share.createdAt.map { $0.formatted(.dateTime.month(.abbreviated).day()) }
    more.menu = menu
    more.accessibilityLabel = menuLabel
    more.isEnabled = enabled
    contentView.alpha = enabled ? 1 : Feedback.disabledOpacity
  }
}
