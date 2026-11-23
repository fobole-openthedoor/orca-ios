import OrcaCore
import UIKit

/// One item's page (bots/items/MobileBotItemPage.tsx): its title, which item and chat, the close note, the
/// description, Status and Chat, Done means, its links, and Activity with a comment box below.
final class BotItemViewController: UIViewController {
  var onOpenChat: ((String) -> Void)?

  private enum Row {
    case header
    case note(String)
    case description(String)
    case status
    case snoozed(Double)
    case chat
    case doneMeans(String)
    case link(BotItem.Link)
    case earlier
    case comment(BotItemEvent)
    case event(BotItemEvent)
    case placeholder(String)
  }

  private let session: HostSession
  private var item: BotItem
  private var events: [BotItemEvent] = []
  private var earlierCursor: String?
  private var loaded = false
  private var sections: [(title: String?, rows: [Row])] = []
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let composer = BotItemCommentBar()
  /// The id of a comment whose reply was lost: sending the same text again reuses it, so it lands once.
  private var pendingRequest: (text: String, id: String)?

  init(session: HostSession, item: BotItem) {
    self.session = session
    self.item = item
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var bot: Bot? { session.bots.bots.first { $0.id == item.ownerBotId } }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "#\(item.number)"
    navigationItem.largeTitleDisplayMode = .never
    view.backgroundColor = Palette.bgBase
    table.backgroundColor = Palette.bgBase
    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .interactive
    table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    table.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.load() })
    table.translatesAutoresizingMaskIntoConstraints = false
    composer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(table)
    view.addSubview(composer)
    NSLayoutConstraint.activate([
      table.topAnchor.constraint(equalTo: view.topAnchor),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: composer.topAnchor),
      composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])
    composer.onSend = { [weak self] text in self?.send(text) }
    rebuildMenu()
    rebuild()
    load()
  }

  override func updateProperties() {
    super.updateProperties()
    composer.isEnabled = session.connectionState == .connected
  }

  private func rebuildMenu() {
    let more = UIBarButtonItem(image: Lucide.ellipsis.image(size: 20), style: .plain, target: nil, action: nil)
    more.menu = UIMenu(children: BotItemStatusText.statusActions(for: item, session: session, from: self) {
      [weak self] in self?.load()
    })
    navigationItem.rightBarButtonItem = more
  }

  private func load(before: String? = nil) {
    let api = session.api
    let uid = item.uid
    Task {
      do {
        guard let page = try await api.botItem(uid: uid, before: before) else { return }
        item = page.item
        if before != nil {
          let known = Set(events.map(\.id))
          events = page.events.filter { !known.contains($0.id) } + events
        } else {
          events = page.events
        }
        earlierCursor = page.earlierCursor
      } catch {
        if !loaded {
          sections = [(nil, [.header]), (nil, [.placeholder(TasksViewController.message(error))])]
          table.reloadData()
        }
      }
      loaded = true
      table.refreshControl?.endRefreshing()
      rebuildMenu()
      rebuild()
    }
  }

  private func send(_ text: String) {
    let requestId: String? =
      session.status?.capabilities.contains(HostAPI.botItemCommentRequestIdCapability) == true
      ? (pendingRequest?.text == text ? pendingRequest?.id : nil) ?? UUID().uuidString.lowercased() : nil
    if let requestId { pendingRequest = (text, requestId) }
    composer.isSending = true
    let api = session.api
    let uid = item.uid
    Task {
      do {
        try await api.commentOnBotItem(uid: uid, text: text, requestId: requestId)
        pendingRequest = nil
        composer.clear()
        load()
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let alert = UIAlertController(
          title: String(localized: "bots.items.activity.notSent", defaultValue: "Not sent."),
          message: TasksViewController.message(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
      composer.isSending = false
    }
  }

  private func rebuild() {
    let now = Date().timeIntervalSince1970 * 1000
    var top: [Row] = [.header]
    if !item.status.isOpen, let note = item.closeNote, !note.isEmpty { top.append(.note(note)) }
    if let description = item.description, !description.isEmpty { top.append(.description(description)) }
    var fields: [Row] = [.status]
    if let until = item.snoozedUntil, item.isSnoozed(now: now) { fields.append(.snoozed(until)) }
    fields.append(.chat)
    sections = [(nil, top), (nil, fields)]
    if let doneMeans = item.doneMeans, !doneMeans.isEmpty {
      sections.append((String(localized: "bots.items.field.doneMeans", defaultValue: "Done means"), [.doneMeans(doneMeans)]))
    }
    if !item.links.isEmpty {
      sections.append(
        (
          "\(String(localized: "bots.items.view.links", defaultValue: "Links")) \(item.links.count)",
          item.links.map(Row.link)
        ))
    }
    var activity: [Row] = earlierCursor == nil ? [] : [.earlier]
    activity += events.map { $0.kind == "commented" ? .comment($0) : .event($0) }
    if loaded, !events.contains(where: { $0.kind == "commented" }) {
      activity.append(.placeholder(String(localized: "bots.items.activity.noComments", defaultValue: "No comments yet.")))
    }
    sections.append((String(localized: "bots.items.view.activity", defaultValue: "Activity"), activity))
    table.reloadData()
  }

  // MARK: Words

  private var chatTitle: String {
    if item.chatKind == "home" { return String(localized: "bots.items.homeChat", defaultValue: "Home Chat") }
    return item.chatTitle ?? String(localized: "bots.items.chatFallback", defaultValue: "Chat")
  }

  private func actorName(_ event: BotItemEvent) -> String {
    switch event.actor {
    case .owner: String(localized: "agentHistory.sessionHistoryList.you", defaultValue: "You")
    case .orca: "Orca"
    case .bot(let id):
      id == item.ownerBotId
        ? item.ownerName ?? bot?.name ?? "" : id == item.madeByBotId ? item.madeByName ?? "" : bot?.name ?? ""
    }
  }

  private static func string(_ value: JSONValue?) -> String { value?.stringValue ?? "" }

  private func fieldName(_ field: String) -> String {
    switch field {
    case "title": String(localized: "bots.items.field.title", defaultValue: "title")
    case "description": String(localized: "bots.items.field.description", defaultValue: "description")
    case "doneMeans": String(localized: "bots.items.field.doneMeansLower", defaultValue: "done means")
    default: field
    }
  }

  /// One Activity line, as the official item page words it.
  private func eventLine(_ event: BotItemEvent) -> (icon: UIImage?, text: String, detail: String?) {
    let by = actorName(event)
    let data = event.data
    switch event.kind {
    case "edited":
      let fields = data["fields"]?.objectValue ?? [:]
      let words = fields.keys.sorted().map {
        String(format: String(localized: "bots.items.activity.changed", defaultValue: "changed %@"), fieldName($0))
      }
      let detail = fields.sorted { $0.key < $1.key }.compactMap { _, change -> String? in
        let to = Self.string(change["to"])
        return to.isEmpty ? nil : to
      }.joined(separator: "\n")
      return (
        Lucide.pencil.image(size: 14), "\(by) \(words.joined(separator: ", "))", detail.isEmpty ? nil : detail
      )
    case "status":
      let from = Self.string(data["from"]), to = Self.string(data["to"])
      let closed: (String) -> Bool = { $0 == "done" || $0 == "canceled" }
      let reopened = closed(from) && !closed(to)
      let status = BotItem.Status(rawValue: to)
      var text: String
      if to == "done" {
        text = String(localized: "bots.items.activity.closed", defaultValue: "marked this done")
      } else if to == "canceled" {
        text = String(localized: "bots.items.activity.canceled", defaultValue: "canceled this")
      } else if reopened {
        text = String(localized: "bots.items.activity.reopened", defaultValue: "reopened this")
      } else {
        text =
          String(localized: "bots.items.activity.moved", defaultValue: "moved this to") + " "
          + (status.map(BotItemStatusText.name) ?? to)
      }
      let note = Self.string(data["note"])
      return (status.map { BotItemStatusText.glyph($0) }, "\(by) \(text)", note.isEmpty ? nil : note)
    case "made":
      let text =
        Self.string(data["status"]) == "needs_you"
        ? String(localized: "bots.items.activity.madeNeedsYou", defaultValue: "added this item as Needs you")
        : String(localized: "bots.items.activity.made", defaultValue: "added this item")
      return (Lucide.plus.image(size: 14), "\(by) \(text)", nil)
    case "linked":
      let links = (data["links"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
      return (
        Lucide.link.image(size: 14),
        "\(by) " + String(format: String(localized: "bots.items.activity.linked", defaultValue: "linked %@"), links), nil
      )
    case "snoozed":
      let text =
        data["until"]?.doubleValue.map {
          String(
            format: String(localized: "bots.items.activity.snoozed", defaultValue: "snoozed this until %@"),
            BotItemStatusText.snoozeTime($0))
        } ?? String(localized: "bots.items.activity.snoozedBare", defaultValue: "snoozed this")
      return (Lucide.alarmClock.image(size: 14), "\(by) \(text)", nil)
    case "unsnoozed":
      return (
        Lucide.alarmClockOff.image(size: 14),
        data["early"]?.boolValue == true
          ? String(localized: "bots.items.activity.snoozeEnded", defaultValue: "Back from snooze early")
          : "\(by) " + String(localized: "bots.items.activity.unsnoozed", defaultValue: "unsnoozed this"), nil
      )
    default:
      return (nil, "\(by) \(event.kind)", nil)
    }
  }

  private func linkWords(_ link: BotItem.Link) -> (icon: Lucide, title: String, detail: String?) {
    switch link.kind {
    case "dispatch":
      let state: String? =
        switch link.state {
        case "completed": String(localized: "bots.items.activity.workerFinished", defaultValue: "Worker finished:")
        case "failed", "stopped": String(localized: "bots.items.activity.workerFailed", defaultValue: "Worker stopped:")
        default: String(localized: "bots.items.activity.workerStarted", defaultValue: "Worker started:")
        }
      return (.bot, link.title ?? link.ref, state.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":")) })
    case "pr":
      let number = link.prNumber.map(String.init) ?? link.ref
      let state: String? =
        switch link.state {
        case "merged": String(localized: "bots.items.link.merged", defaultValue: "Merged")
        case "closed": String(localized: "bots.items.link.closed", defaultValue: "Closed")
        case "draft": String(localized: "bots.items.link.draft", defaultValue: "Draft")
        case "open": String(localized: "bots.items.link.open", defaultValue: "Open")
        default: nil
        }
      return (
        link.state == "merged" ? .gitMerge : .gitPullRequest,
        link.title ?? String(format: String(localized: "bots.items.link.pr", defaultValue: "PR #%@"), number), state
      )
    case "file": return (.file, (link.ref as NSString).lastPathComponent, link.ref)
    case "automation":
      return (
        .calendarClock, link.title ?? String(localized: "bots.items.link.automation", defaultValue: "Automation"),
        link.state == "active"
          ? String(localized: "bots.items.link.automationOn", defaultValue: "Will wake the agent for this item")
          : String(localized: "bots.items.link.automationEnded", defaultValue: "Ended")
      )
    default: return (.link, link.title ?? link.ref, link.title == nil ? nil : link.ref)
    }
  }
}

extension BotItemViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    cell.selectionStyle = .none
    cell.accessoryType = .none
    cell.accessoryView = nil
    switch sections[indexPath.section].rows[indexPath.row] {
    case .header:
      var content = UIListContentConfiguration.subtitleCell()
      content.text = item.title
      content.textProperties.font = .systemFont(ofSize: Typography.titleSize, weight: .semibold)
      content.textProperties.numberOfLines = 0
      var sub = String(
        format: String(localized: "bots.items.view.subWhere", defaultValue: "Item %1$@ · %2$@"), "#\(item.number)", chatTitle)
      if item.createdAt > 0 {
        sub += " · " + Date(timeIntervalSince1970: item.createdAt / 1000).formatted(date: .abbreviated, time: .shortened)
      }
      content.secondaryText = sub
      content.secondaryTextProperties.color = Palette.textMuted
      content.secondaryTextProperties.font = .systemFont(ofSize: Typography.metaSize)
      content.textToSecondaryTextVerticalPadding = Spacing.xs
      cell.contentConfiguration = content
    case .note(let note):
      var content = UIListContentConfiguration.cell()
      let label =
        item.status == .canceled
        ? String(localized: "bots.items.view.canceledNote", defaultValue: "Canceled:")
        : String(localized: "bots.items.view.doneNote", defaultValue: "Done:")
      let text = NSMutableAttributedString(
        string: label + " ", attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold)])
      text.append(NSAttributedString(string: note, attributes: [.font: UIFont.systemFont(ofSize: 15)]))
      content.attributedText = text
      content.textProperties.numberOfLines = 0
      cell.contentConfiguration = content
    case .description(let description):
      var content = UIListContentConfiguration.cell()
      content.text = description
      content.textProperties.font = .systemFont(ofSize: 15)
      content.textProperties.numberOfLines = 0
      cell.contentConfiguration = content
    case .status:
      var content = UIListContentConfiguration.valueCell()
      content.text = String(localized: "bots.items.field.status", defaultValue: "Status")
      content.secondaryText = BotItemStatusText.name(item.status)
      content.secondaryTextProperties.color = Palette.textSecondary
      cell.contentConfiguration = content
      cell.accessoryView = UIImageView(image: BotItemStatusText.glyph(item.status))
    case .snoozed(let until):
      var content = UIListContentConfiguration.valueCell()
      content.text = String(localized: "bots.items.field.snoozed", defaultValue: "Snoozed")
      content.secondaryText = String(
        format: String(localized: "bots.items.snooze.rowUntil", defaultValue: "until %@"),
        BotItemStatusText.snoozeTime(until))
      cell.contentConfiguration = content
    case .chat:
      var content = UIListContentConfiguration.valueCell()
      content.text = String(localized: "bots.items.field.chat", defaultValue: "Chat")
      content.secondaryText = chatTitle
      cell.contentConfiguration = content
      if onOpenChat != nil {
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
      }
    case .doneMeans(let text):
      var content = UIListContentConfiguration.cell()
      content.text = text
      content.textProperties.font = .systemFont(ofSize: 15)
      content.textProperties.numberOfLines = 0
      cell.contentConfiguration = content
    case .link(let link):
      let words = linkWords(link)
      var content = UIListContentConfiguration.subtitleCell()
      content.text = words.title
      content.textProperties.numberOfLines = 2
      content.secondaryText = words.detail
      content.secondaryTextProperties.color = Palette.textSecondary
      content.image = words.icon.image(size: 16)
      content.imageProperties.tintColor = Palette.textSecondary
      cell.contentConfiguration = content
      if link.url.flatMap(URL.init(string:)) != nil {
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
      }
    case .earlier:
      var content = UIListContentConfiguration.cell()
      content.text = String(localized: "bots.items.view.showEarlier", defaultValue: "Show earlier")
      content.textProperties.color = Palette.accentBlue
      cell.contentConfiguration = content
      cell.selectionStyle = .default
    case .comment(let event):
      var content = UIListContentConfiguration.subtitleCell()
      var heading = actorName(event)
      if let age = RelativeTime.short(event.at) { heading += " · \(age)" }
      content.text = heading
      content.textProperties.font = .systemFont(ofSize: 13, weight: .semibold)
      content.textProperties.color = Palette.textSecondary
      content.secondaryText = Self.string(event.data["text"])
      content.secondaryTextProperties.font = .systemFont(ofSize: 15)
      content.secondaryTextProperties.color = Palette.textPrimary
      content.secondaryTextProperties.numberOfLines = 0
      content.textToSecondaryTextVerticalPadding = Spacing.xs
      if case .bot(let id) = event.actor, let bot = session.bots.bots.first(where: { $0.id == id }) {
        let avatar = BotAvatarView(size: 24)
        avatar.show(bot)
        content.image = avatar.snapshotImage()
        content.imageProperties.cornerRadius = 6
      } else {
        content.image = Lucide.userRound.image(size: 18)
        content.imageProperties.tintColor = Palette.textMuted
      }
      content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
      cell.contentConfiguration = content
    case .event(let event):
      let line = eventLine(event)
      var content = UIListContentConfiguration.subtitleCell()
      content.text = line.text
      content.textProperties.font = .systemFont(ofSize: 14)
      content.textProperties.color = Palette.textSecondary
      content.textProperties.numberOfLines = 0
      content.secondaryText = line.detail
      content.secondaryTextProperties.numberOfLines = 4
      content.secondaryTextProperties.color = Palette.textMuted
      content.image = line.icon
      content.imageProperties.tintColor = Palette.textMuted
      content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 16)
      cell.contentConfiguration = content
    case .placeholder(let text):
      var content = UIListContentConfiguration.cell()
      content.text = text
      content.textProperties.color = Palette.textSecondary
      content.textProperties.numberOfLines = 0
      cell.contentConfiguration = content
    }
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .chat: onOpenChat?(item.chatId)
    case .link(let link): if let url = link.url.flatMap(URL.init(string:)) { UIApplication.shared.open(url) }
    case .earlier: if let cursor = earlierCursor { load(before: cursor) }
    default: break
    }
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    let text: String
    switch sections[indexPath.section].rows[indexPath.row] {
    case .description(let value), .doneMeans(let value), .note(let value): text = value
    case .comment(let event): text = Self.string(event.data["text"])
    case .link(let link): text = link.url ?? link.ref
    case .header: text = item.title
    default: return nil
    }
    return UIContextMenuConfiguration(actionProvider: { _ in
      UIMenu(children: [
        UIAction(title: String(localized: "common.copy", defaultValue: "Copy"), image: Lucide.copy.image(size: 18)) { _ in
          UIPasteboard.general.string = text
        }
      ])
    })
  }
}

/// The comment box under an item's Activity: a growing text view and a send button.
final class BotItemCommentBar: UIView, UITextViewDelegate {
  var onSend: ((String) -> Void)?
  var isEnabled = true { didSet { update() } }
  var isSending = false { didSet { update() } }

  private let field = UITextView()
  private let placeholder = TextLabel(
    String(localized: "bots.items.comment.add", defaultValue: "Add a comment…"), size: 16, color: Palette.textMuted)
  private let send = UIButton(configuration: .prominentGlass())
  private var height: NSLayoutConstraint!

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = Palette.bgBase
    let box = UIView()
    box.backgroundColor = Palette.composerSurface
    box.layer.cornerRadius = Radius.floating
    box.layer.cornerCurve = .continuous
    box.layer.borderWidth = 1
    box.layer.borderColor = Palette.composerBorder.cgColor
    box.translatesAutoresizingMaskIntoConstraints = false
    field.font = .systemFont(ofSize: 16)
    field.backgroundColor = .clear
    field.textColor = Palette.textPrimary
    field.delegate = self
    field.isScrollEnabled = false
    field.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    field.textContainer.lineFragmentPadding = 0
    field.accessibilityLabel = String(localized: "bots.items.comment.label", defaultValue: "Comment")
    field.translatesAutoresizingMaskIntoConstraints = false
    send.configuration?.image = Lucide.arrowUp.image(size: 18, strokeWidth: 2.4)
    send.configuration?.cornerStyle = .capsule
    send.tintColor = Palette.createActionFill
    send.accessibilityLabel = String(localized: "bots.items.comment.submit", defaultValue: "Comment")
    send.translatesAutoresizingMaskIntoConstraints = false
    send.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        let text = self.field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        self.onSend?(text)
      }, for: .primaryActionTriggered)
    addSubview(box)
    box.addSubview(field)
    box.addSubview(placeholder)
    box.addSubview(send)
    height = field.heightAnchor.constraint(equalToConstant: 40)
    NSLayoutConstraint.activate([
      box.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      box.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Spacing.md),
      box.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.md),
      box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      field.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
      field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
      field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Spacing.lg),
      field.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -Spacing.sm),
      height,
      placeholder.leadingAnchor.constraint(equalTo: field.leadingAnchor),
      placeholder.centerYAnchor.constraint(equalTo: field.centerYAnchor),
      send.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
      send.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
      send.widthAnchor.constraint(equalToConstant: 34),
      send.heightAnchor.constraint(equalToConstant: 34),
    ])
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
      box.layer.borderColor = Palette.composerBorder.resolvedColor(with: self.traitCollection).cgColor
    }
    update()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func clear() {
    field.text = ""
    textViewDidChange(field)
  }

  func textViewDidChange(_ textView: UITextView) {
    let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
    height.constant = min(max(40, fitting), 140)
    textView.isScrollEnabled = fitting > 140
    update()
  }

  private func update() {
    placeholder.isHidden = !field.text.isEmpty
    field.isEditable = isEnabled && !isSending
    send.isEnabled =
      isEnabled && !isSending && !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    send.configuration?.showsActivityIndicator = isSending
  }
}
