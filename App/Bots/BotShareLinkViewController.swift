import OrcaCore
import UIKit

/// New bot › From a link (bots/sharing/MobileBotSharePasteLink.tsx): paste a link someone shared, then
/// review what the bot comes with before making it.
final class BotShareLinkViewController: UITableViewController {
  private let session: HostSession
  private let agent: String
  private let onCreated: (Bot) -> Void
  private let field = UITextField()
  private var reading = false

  init(session: HostSession, agent: String, onCreated: @escaping (Bot) -> Void) {
    self.session = session
    self.agent = agent
    self.onCreated = onCreated
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.share.receive.fromLink", defaultValue: "From a link")
    navigationItem.largeTitleDisplayMode = .never
    let next = UIBarButtonItem(
      title: String(localized: "bots.share.receive.continue", defaultValue: "Continue"), style: .prominent,
      target: nil, action: nil)
    next.primaryAction = UIAction(title: next.title ?? "") { [weak self] _ in self?.review() }
    navigationItem.rightBarButtonItem = next
    field.placeholder = String(localized: "bots.share.receive.linkPlaceholder", defaultValue: "https://app.orca.dev/bots/share/…")
    field.accessibilityLabel = String(localized: "bots.share.receive.link", defaultValue: "Link")
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.keyboardType = .URL
    field.clearButtonMode = .whileEditing
    field.returnKeyType = .go
    field.addAction(UIAction { [weak self] _ in self?.update() }, for: .editingChanged)
    field.addAction(UIAction { [weak self] _ in self?.review() }, for: .editingDidEndOnExit)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    update()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  private var shareId: String? { BotShareReview.shareId(in: field.text ?? "") }

  private func update() {
    navigationItem.rightBarButtonItem?.isEnabled = shareId != nil && !reading
  }

  private func review() {
    guard let shareId, !reading else { return }
    reading = true
    update()
    let api = session.api
    Task {
      defer {
        reading = false
        update()
      }
      do {
        guard let review = try await api.botShareReview(shareId: shareId) else {
          return say(
            String(localized: "bots.share.receive.stopped", defaultValue: "This link no longer works"),
            String(localized: "bots.share.receive.stoppedDetail", defaultValue: "Ask the sharer for a new one"))
        }
        navigationController?.pushViewController(
          BotShareReviewViewController(session: session, agent: agent, review: review, onCreated: onCreated),
          animated: true)
      } catch {
        say(nil, (error as? RPCError)?.message ?? error.localizedDescription)
      }
    }
  }

  private func say(_ title: String?, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    String(localized: "bots.share.receive.pasteDescription", defaultValue: "Paste a link someone shared.")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .none
    if field.superview !== cell.contentView {
      field.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(field)
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
        field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        field.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
        field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
        field.heightAnchor.constraint(equalToConstant: 52),
      ])
    }
    return cell
  }
}

/// A shared bot before it is made (bots/sharing/MobileBotShareReview.tsx): what it is for, what it comes
/// with, which tools it may call, and how much it may run without asking.
final class BotShareReviewViewController: UITableViewController {
  private enum Permission: String, CaseIterable {
    case ask, full = "full-access", chats

    var title: String {
      switch self {
      case .ask: String(localized: "bots.share.receive.ask", defaultValue: "Ask for approval")
      case .full: String(localized: "bots.share.receive.full", defaultValue: "Full access")
      case .chats: String(localized: "bots.settings.sameAsChats", defaultValue: "Same as chats")
      }
    }

    var detail: String {
      switch self {
      case .ask: String(localized: "bots.share.receive.askDetail", defaultValue: "Picked for bots made from a link")
      case .full: String(localized: "bots.share.receive.fullDetail", defaultValue: "Runs commands without asking")
      case .chats: String(localized: "bots.share.receive.chatsDetail", defaultValue: "Starts from your chat permission setting")
      }
    }
  }

  private enum Section {
    case name, purpose, list(title: String, items: [String]), tools, permission
  }

  private let session: HostSession
  private let agent: String
  private let review: BotShareReview
  private let onCreated: (Bot) -> Void
  private let nameField = UITextField()
  private var ticked: Set<String>
  private var permission = Permission.ask
  private var sections: [Section] = []
  private var creating = false

  init(session: HostSession, agent: String, review: BotShareReview, onCreated: @escaping (Bot) -> Void) {
    self.session = session
    self.agent = agent
    self.review = review
    self.onCreated = onCreated
    ticked = Set(review.tools.map(\.id))
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = review.name.isEmpty ? String(localized: "bots.share.receive.sharedBot", defaultValue: "Shared bot") : review.name
    navigationItem.subtitle = review.publisher.map {
      String(format: String(localized: "bots.share.receive.origin", defaultValue: "A link from %@"), $0)
    } ?? String(localized: "bots.share.receive.originAnonymous", defaultValue: "From a shared link")
    navigationItem.largeTitleDisplayMode = .never
    let create = UIBarButtonItem(
      title: String(localized: "bots.new.create", defaultValue: "Create"), style: .prominent, target: nil, action: nil)
    create.primaryAction = UIAction(title: create.title ?? "") { [weak self] _ in self?.create() }
    navigationItem.rightBarButtonItem = create
    nameField.text = review.name
    nameField.placeholder = String(localized: "bots.new.namePlaceholder", defaultValue: "Name your bot")
    nameField.font = .systemFont(ofSize: 17)
    nameField.clearButtonMode = .whileEditing
    nameField.addAction(UIAction { [weak self] _ in self?.updateCreate() }, for: .editingChanged)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.keyboardDismissMode = .interactive

    if let mascot = review.mascot {
      let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 96))
      let avatar = BotAvatarView(size: 72)
      avatar.show(mascot: mascot)
      header.addSubview(avatar)
      NSLayoutConstraint.activate([
        avatar.centerXAnchor.constraint(equalTo: header.centerXAnchor),
        avatar.topAnchor.constraint(equalTo: header.topAnchor, constant: Spacing.md),
      ])
      tableView.tableHeaderView = header
    }
    sections = [.name]
    if !review.purpose.isEmpty { sections.append(.purpose) }
    if !review.skills.isEmpty {
      sections.append(.list(title: String(localized: "bots.share.skills", defaultValue: "Skills"), items: review.skills))
    }
    if !review.tools.isEmpty { sections.append(.tools) }
    let accounts = review.connectors.map { BotTemplate.connectorNames[$0] ?? $0 }
    if !accounts.isEmpty {
      sections.append(
        .list(title: String(localized: "bots.share.review.accounts", defaultValue: "Accounts to connect"), items: accounts))
    }
    if !review.schedules.isEmpty {
      sections.append(
        .list(title: String(localized: "bots.share.automations", defaultValue: "Automations"), items: review.schedules))
    }
    if !review.memory.isEmpty {
      sections.append(.list(title: String(localized: "bots.share.memory", defaultValue: "Memory"), items: review.memory))
    }
    sections.append(.permission)
    updateCreate()
  }

  private var name: String { (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

  private func updateCreate() {
    navigationItem.rightBarButtonItem?.isEnabled = !name.isEmpty && !creating
  }

  /// Made from exactly the reviewed version, or not at all: a link that moved or stopped is said.
  private func create() {
    guard !name.isEmpty, !creating else { return }
    creating = true
    updateCreate()
    var extra: [String: JSONValue] = [
      "fromShare": ["reviewId": .string(review.reviewId), "toolIds": .array(ticked.sorted().map { .string($0) })]
    ]
    if permission != .chats { extra["permissionMode"] = .string(permission.rawValue) }
    let api = session.api
    let name = name
    let agent = agent
    let mascot = review.mascot
    Task {
      do {
        guard let bot = try await api.createBot(name: name, agent: agent, mascotId: mascot, extra: extra) else {
          throw CancellationError()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await session.refresh()
        let onCreated = onCreated
        navigationController?.dismiss(animated: true) { onCreated(bot) }
      } catch {
        creating = false
        updateCreate()
        let alert = UIAlertController(
          title: String(localized: "bots.new.failed", defaultValue: "Couldn’t create the bot"),
          message: (error as? RPCError)?.message ?? error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
    }
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch sections[section] {
    case .list(_, let items): items.count
    case .tools: review.tools.count
    default: 1
    }
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch sections[section] {
    case .list(let title, _): title
    case .tools: String(localized: "bots.share.tools", defaultValue: "Tools")
    case .permission: String(localized: "bots.settings.permissions", defaultValue: "Permissions")
    default: nil
    }
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    if case .permission = sections[section] { return permission.detail }
    if case .purpose = sections[section] { return review.setupNote }
    return nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .none
    cell.accessoryView = nil
    cell.contentView.subviews.filter { $0 is UIButton }.forEach { $0.removeFromSuperview() }
    var content = UIListContentConfiguration.cell()
    switch sections[indexPath.section] {
    case .name:
      cell.contentConfiguration = nil
      if nameField.superview !== cell.contentView {
        nameField.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(nameField)
        NSLayoutConstraint.activate([
          nameField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
          nameField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
          nameField.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
          nameField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
          nameField.heightAnchor.constraint(equalToConstant: 52),
        ])
      }
      return cell
    case .purpose:
      content.text = review.purpose
      content.textProperties.numberOfLines = 0
    case .list(_, let items):
      content.text = items[indexPath.row]
    case .tools:
      let tool = review.tools[indexPath.row]
      content = UIListContentConfiguration.subtitleCell()
      content.text = tool.name
      content.secondaryText = URL(string: tool.url)?.host.map {
        String(format: String(localized: "bots.share.review.contact", defaultValue: "Let it contact %@"), $0)
      }
      content.secondaryTextProperties.color = Palette.textSecondary
      let toggle = UISwitch()
      toggle.isOn = ticked.contains(tool.id)
      toggle.addAction(
        UIAction { [weak self, weak toggle] _ in
          guard let self, let toggle else { return }
          if toggle.isOn { self.ticked.insert(tool.id) } else { self.ticked.remove(tool.id) }
        }, for: .valueChanged)
      cell.accessoryView = toggle
    case .permission:
      content = UIListContentConfiguration.valueCell()
      content.text = String(localized: "bots.settings.permissions", defaultValue: "Permissions")
      content.secondaryText = permission.title
      let picker = UIButton(type: .system)
      picker.showsMenuAsPrimaryAction = true
      picker.menu = UIMenu(
        children: Permission.allCases.map { choice in
          UIAction(title: choice.title, subtitle: choice.detail, state: choice == permission ? .on : .off) {
            [weak self] _ in
            self?.permission = choice
            self?.tableView.reloadData()
          }
        })
      picker.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(picker)
      picker.pin(to: cell.contentView)
      let chevrons = UIImageView(image: Lucide.chevronsUpDown.image(size: 14))
      chevrons.tintColor = Palette.textMuted
      cell.accessoryView = chevrons
    }
    cell.contentConfiguration = content
    return cell
  }
}
