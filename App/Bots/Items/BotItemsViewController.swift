import OrcaCore
import UIKit

/// A bot's Items (bots/items/MobileBotItemsTab.tsx): what it has taken on, grouped as the desktop groups them
/// (Needs you, In progress, Waiting, Planned, Snoozed, Stale, Closed). Needs you, In progress and Waiting start
/// open and the rest folded; a group shows five rows, then Show N more.
final class BotItemsViewController: UITableViewController {
  /// Called with an item's chat id when its Chat row is tapped, so the caller can open that chat.
  var onOpenChat: ((String) -> Void)?

  enum Group: String, CaseIterable {
    case needsYou = "needs_you", working, waiting, planned, snoozed, stale, closed

    var title: String {
      switch self {
      case .needsYou: BotItemStatusText.name(.needsYou)
      case .working: BotItemStatusText.name(.working)
      case .waiting: BotItemStatusText.name(.waiting)
      case .planned: BotItemStatusText.name(.planned)
      case .snoozed: String(localized: "bots.items.group.snoozed", defaultValue: "Snoozed")
      case .stale: String(localized: "bots.items.group.stale", defaultValue: "Stale")
      case .closed: String(localized: "bots.items.group.closed", defaultValue: "Closed")
      }
    }

    var foldedByDefault: Bool { self == .planned || self == .snoozed || self == .stale || self == .closed }
  }

  private enum Row {
    case item(BotItem)
    case more(Int)
    case loadClosed
  }

  /// Rows a group shows before Show N more.
  private static let groupRows = 5
  /// The bot's stale setting isn't on the bot list this app reads, so the desktop's default applies.
  private static let staleDays: Double = 5

  private let session: HostSession
  private let botId: String
  private var listing: BotItemsListing?
  private var closedPages: [BotItem] = []
  private var closedCursor: String?
  private var loadError: String?
  private var needsYouOnly = false
  private var folded: Set<Group> = Set(Group.allCases.filter(\.foldedByDefault))
  private var expanded: Set<Group> = []
  /// The seen mark as the page opened: rows changed since keep their dot while it stays open.
  private var seenEventId: String?
  private var sections: [(group: Group, count: Int, rows: [Row])] = []
  private var filterItem: UIBarButtonItem!

  init(session: HostSession, botId: String) {
    self.session = session
    self.botId = botId
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var bot: Bot? { session.bots.bots.first { $0.id == botId } }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.items.tab", defaultValue: "Items")
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.register(BotItemGroupHeader.self, forHeaderFooterViewReuseIdentifier: "group")
    tableView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.load() })
    filterItem = UIBarButtonItem(image: Lucide.listFilter.image(size: 20), style: .plain, target: nil, action: nil)
    filterItem.accessibilityLabel = String(localized: "bots.items.filter.label", defaultValue: "Filter items")
    navigationItem.rightBarButtonItem = filterItem
    rebuildFilterMenu()
    load()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if listing != nil { load() }
  }

  override func updateProperties() {
    super.updateProperties()
    navigationItem.subtitle = bot?.name ?? session.name
  }

  private func load() {
    let api = session.api
    let botId = botId
    Task {
      do {
        let listing = try await api.botItems(botId: botId)
        if seenEventId == nil { seenEventId = listing.seenEventId }
        self.listing = listing
        closedPages = []
        closedCursor = listing.nextClosedCursor
        loadError = nil
        await api.markBotItemsOpened(botId: botId)
      } catch {
        loadError = TasksViewController.message(error)
      }
      refreshControl?.endRefreshing()
      rebuild()
    }
  }

  private func loadMoreClosed() {
    guard let cursor = closedCursor else { return }
    closedCursor = nil
    let api = session.api
    let botId = botId
    Task {
      do {
        let page = try await api.botItems(botId: botId, closedCursor: cursor)
        closedPages += page.items.filter { !$0.status.isOpen }
        closedCursor = page.nextClosedCursor
      } catch {
        closedCursor = cursor
        let alert = UIAlertController(
          title: String(localized: "bots.items.readFailedClosedPage", defaultValue: "Couldn’t read more closed items."),
          message: TasksViewController.message(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
      rebuild()
    }
  }

  private func unseen(_ item: BotItem) -> Bool {
    Self.eventNumber(item.othersLastEventId) > Self.eventNumber(seenEventId ?? listing?.seenEventId ?? "")
  }

  static func eventNumber(_ id: String) -> Int {
    Int(id.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "e"))) ?? 0
  }

  static func group(of item: BotItem, now: Double) -> Group {
    if !item.status.isOpen { return .closed }
    if item.isSnoozed(now: now) { return .snoozed }
    if item.isStale(days: staleDays, now: now) { return .stale }
    return Group(rawValue: item.status.rawValue) ?? .planned
  }

  private func rebuild() {
    let now = Date().timeIntervalSince1970 * 1000
    var all = listing?.items ?? []
    let known = Set(all.map(\.uid))
    all += closedPages.filter { !known.contains($0.uid) }
    if needsYouOnly { all = all.filter { $0.status == .needsYou } }
    var groups: [Group: [BotItem]] = [:]
    for item in all { groups[Self.group(of: item, now: now), default: []].append(item) }
    sections = Group.allCases.compactMap { group in
      var rows = groups[group] ?? []
      let canLoadMore = group == .closed && closedCursor != nil && !needsYouOnly
      guard !rows.isEmpty || canLoadMore else { return nil }
      if group == .snoozed {
        rows.sort { ($0.snoozedUntil ?? 0, -$0.number) < ($1.snoozedUntil ?? 0, -$1.number) }
      } else {
        rows.sort {
          let a = (unseen($0) ? 1 : 0, $0.activityAt(now: now), $0.number)
          let b = (unseen($1) ? 1 : 0, $1.activityAt(now: now), $1.number)
          return a > b
        }
      }
      let total =
        group == .closed && !needsYouOnly
        ? max(rows.count, (listing?.counts[.done] ?? 0) + (listing?.counts[.canceled] ?? 0)) : rows.count
      if folded.contains(group) { return (group, total, []) }
      var shown: [Row] = []
      if expanded.contains(group) || rows.count <= Self.groupRows {
        shown = rows.map(Row.item)
      } else {
        shown = rows.prefix(Self.groupRows).map(Row.item) + [.more(rows.count - Self.groupRows)]
      }
      if canLoadMore, expanded.contains(group) || rows.count <= Self.groupRows { shown.append(.loadClosed) }
      return (group, total, shown)
    }
    tableView.reloadData()
    showState()
  }

  private func showState() {
    var config: UIContentUnavailableConfiguration?
    if listing == nil {
      if session.connectionState != .connected {
        config = .empty()
        config?.image = Lucide.wifiOff.image(size: 34, strokeWidth: 1.6)
        config?.text = String(
          format: String(localized: "common.offline.waitingFor", defaultValue: "Waiting for %@"), session.name)
      } else if let loadError {
        config = .empty()
        config?.image = Lucide.circleAlert.image(size: 34, strokeWidth: 1.6)
        config?.text = String(localized: "bots.items.readFailedTitle", defaultValue: "Couldn’t load items")
        config?.secondaryText = loadError
        var retry = UIButton.Configuration.glass()
        retry.title = String(localized: "common.retry", defaultValue: "Retry")
        config?.button = retry
        config?.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
      } else {
        config = .loading()
        config?.text = String(localized: "bots.items.loading", defaultValue: "Loading items…")
      }
    } else if sections.isEmpty {
      config = .empty()
      config?.image = Lucide.inbox.image(size: 34, strokeWidth: 1.6)
      if needsYouOnly {
        config?.text = String(localized: "bots.items.empty.needsYou", defaultValue: "Nothing needs you.")
        var clear = UIButton.Configuration.glass()
        clear.title = String(localized: "bots.items.filter.clear", defaultValue: "Clear filter")
        config?.button = clear
        config?.buttonProperties.primaryAction = UIAction { [weak self] _ in
          self?.needsYouOnly = false
          self?.rebuildFilterMenu()
          self?.rebuild()
        }
      } else {
        config?.text = String(localized: "bots.items.empty.title", defaultValue: "No items yet")
        config?.secondaryText = String(
          format: String(
            localized: "bots.items.empty.body",
            defaultValue:
              "When %@ takes on something for you, it shows up here with what it is doing and what it needs from you."),
          bot?.name ?? "")
      }
    }
    config?.imageProperties.tintColor = Palette.textMuted
    contentUnavailableConfiguration = config
  }

  private func rebuildFilterMenu() {
    filterItem.menu = UIMenu(children: [
      UIAction(
        title: String(localized: "bots.items.filter.needsYou", defaultValue: "Needs you only"),
        image: Lucide.hand.image(size: 18), state: needsYouOnly ? .on : .off
      ) { [weak self] _ in
        guard let self else { return }
        self.needsYouOnly.toggle()
        self.rebuildFilterMenu()
        self.rebuild()
      }
    ])
    filterItem.isSelected = needsYouOnly
  }

  private func open(_ item: BotItem) {
    let page = BotItemViewController(session: session, item: item)
    page.onOpenChat = onOpenChat
    navigationController?.pushViewController(page, animated: true)
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "group") as? BotItemGroupHeader
    let entry = sections[section]
    let unseenCount = (listing?.items ?? []).filter {
      Self.group(of: $0, now: Date().timeIntervalSince1970 * 1000) == entry.group && unseen($0)
    }.count
    header?.configure(
      title: entry.group.title, count: entry.count, unseen: unseenCount, folded: folded.contains(entry.group)
    ) { [weak self] in
      guard let self else { return }
      if self.folded.contains(entry.group) {
        self.folded.remove(entry.group)
      } else {
        self.folded.insert(entry.group)
      }
      self.rebuild()
    }
    return header
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    cell.accessoryView = nil
    cell.accessoryType = .none
    let group = sections[indexPath.section].group
    switch sections[indexPath.section].rows[indexPath.row] {
    case .item(let item):
      let now = Date().timeIntervalSince1970 * 1000
      var content = UIListContentConfiguration.subtitleCell()
      content.attributedText = {
        let text = NSMutableAttributedString(
          string: "#\(item.number) ",
          attributes: [.foregroundColor: Palette.textMuted, .font: UIFont.systemFont(ofSize: 16)])
        text.append(
          NSAttributedString(
            string: item.title,
            attributes: [
              .foregroundColor: group == .stale || group == .snoozed ? Palette.textSecondary : Palette.textPrimary,
              .font: UIFont.systemFont(ofSize: 16, weight: unseen(item) ? .semibold : .regular),
            ]))
        return text
      }()
      content.textProperties.numberOfLines = 2
      // Only Needs you and Waiting have a second line: the bot's question, or what it waits on.
      let line =
        group == .needsYou ? item.question : group == .waiting || (group == .stale && item.status == .waiting)
        ? item.waitText : nil
      content.secondaryText = line?.split(separator: "\n").first.map(String.init)
      content.secondaryTextProperties.color = Palette.textSecondary
      content.secondaryTextProperties.font = .systemFont(ofSize: 13)
      content.secondaryTextProperties.numberOfLines = 1
      content.image = BotItemStatusText.glyph(item.status, faded: group == .stale || group == .snoozed)
      content.imageProperties.reservedLayoutSize = CGSize(width: 16, height: 16)
      cell.contentConfiguration = content
      let age = TextLabel(
        group == .snoozed
          ? item.snoozedUntil.map(BotItemStatusText.snoozeTime).map {
            String(format: String(localized: "bots.items.snooze.rowUntil", defaultValue: "until %@"), $0)
          }
          : RelativeTime.short(item.activityAt(now: now)),
        size: 12, color: Palette.textMuted)
      age.sizeToFit()
      cell.accessoryView = age
      cell.accessibilityLabel = "#\(item.number) \(item.title), \(BotItemStatusText.name(item.status))"
    case .more(let count):
      var content = UIListContentConfiguration.cell()
      content.text = String(localized: "bots.items.group.showMore", defaultValue: "Show \(count) more")
      content.textProperties.color = Palette.accentBlue
      cell.contentConfiguration = content
    case .loadClosed:
      var content = UIListContentConfiguration.cell()
      content.text = String(localized: "bots.items.view.showMore", defaultValue: "Show more")
      content.textProperties.color = Palette.accentBlue
      cell.contentConfiguration = content
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let group = sections[indexPath.section].group
    switch sections[indexPath.section].rows[indexPath.row] {
    case .item(let item): open(item)
    case .more:
      expanded.insert(group)
      rebuild()
    case .loadClosed: loadMoreClosed()
    }
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard case .item(let item) = sections[indexPath.section].rows[indexPath.row] else { return nil }
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      guard let self else { return nil }
      return UIMenu(children: BotItemStatusText.statusActions(for: item, session: self.session, from: self) {
        [weak self] in self?.load()
      })
    })
  }
}

/// A group's heading: its name and count, a new-count, and a chevron that folds it.
final class BotItemGroupHeader: UITableViewHeaderFooterView {
  private let button = UIButton(configuration: .plain())
  private var onTap: (() -> Void)?

  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.contentHorizontalAlignment = .leading
    button.configuration?.contentInsets = .zero
    button.configuration?.imagePlacement = .trailing
    button.configuration?.imagePadding = 6
    button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
    contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
      button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
      button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.xs),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(title: String, count: Int, unseen: Int, folded: Bool, onTap: @escaping () -> Void) {
    self.onTap = onTap
    var text = AttributedString(
      title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: Palette.textPrimary]))
    text += AttributedString(
      "  \(count)", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15), .foregroundColor: Palette.textMuted]))
    if unseen > 0 {
      text += AttributedString(
        "  " + String(localized: "bots.items.group.new", defaultValue: "\(unseen) new"),
        attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Palette.accentBlue]))
    }
    button.configuration?.attributedTitle = text
    button.configuration?.image = (folded ? Lucide.chevronRight : Lucide.chevronDown).image(size: 14, strokeWidth: 2.2)
    button.tintColor = Palette.textMuted
    button.accessibilityTraits = .header
  }
}

/// Item statuses in words and glyphs, as the official status icon draws them.
enum BotItemStatusText {
  static func name(_ status: BotItem.Status) -> String {
    switch status {
    case .planned: String(localized: "bots.items.status.planned", defaultValue: "Planned")
    case .working: String(localized: "bots.items.status.working", defaultValue: "In progress")
    case .waiting: String(localized: "bots.items.status.waiting", defaultValue: "Waiting")
    case .needsYou: String(localized: "bots.items.status.needsYou", defaultValue: "Needs you")
    case .done: String(localized: "bots.items.status.done", defaultValue: "Done")
    case .canceled: String(localized: "bots.items.status.canceled", defaultValue: "Canceled")
    }
  }

  /// "2:56 PM", "Tomorrow 2:56 PM" or "Nov 14, 2:56 PM".
  static func snoozeTime(_ milliseconds: Double) -> String {
    let date = Date(timeIntervalSince1970: milliseconds / 1000)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    let relative = DateFormatter()
    relative.dateStyle = .short
    relative.timeStyle = .short
    relative.doesRelativeDateFormatting = true
    if calendar.isDateInTomorrow(date) || calendar.isDateInYesterday(date) { return relative.string(from: date) }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
  }

  /// The status glyph: a filled dot for Needs you, an amber ring for In progress, a half-filled circle for
  /// Waiting, a dashed circle for Planned, a green check for Done and a slashed circle for Canceled.
  static func glyph(_ status: BotItem.Status, faded: Bool = false, size: CGFloat = 12) -> UIImage {
    switch status {
    case .done:
      return Lucide.circleCheck.image(size: size + 2).withTintColor(Palette.statusGreen, renderingMode: .alwaysOriginal)
    case .canceled:
      return Lucide.circleSlash.image(size: size + 2).withTintColor(Palette.textMuted, renderingMode: .alwaysOriginal)
    default: break
    }
    let traits = UITraitCollection.current
    let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
      let cg = context.cgContext
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      switch status {
      case .needsYou:
        cg.setFillColor((faded ? Palette.textMuted : Palette.agentQuestion).resolvedColor(with: traits).cgColor)
        cg.fillEllipse(in: rect)
      case .working:
        cg.setStrokeColor(Palette.statusAmber.resolvedColor(with: traits).cgColor)
        cg.setLineWidth(2)
        cg.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
      case .waiting:
        let color = Palette.textMuted.resolvedColor(with: traits).cgColor
        cg.setStrokeColor(color)
        cg.setLineWidth(1.5)
        cg.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
        cg.setFillColor(color)
        cg.addArc(
          center: CGPoint(x: size / 2, y: size / 2), radius: size / 2 - 2.5, startAngle: 0, endAngle: .pi,
          clockwise: false)
        cg.fillPath()
      default:
        cg.setStrokeColor(Palette.textMuted.resolvedColor(with: traits).cgColor)
        cg.setLineWidth(1.5)
        cg.setLineDash(phase: 0, lengths: [2, 2])
        cg.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
      }
    }
    return image.withRenderingMode(.alwaysOriginal)
  }

  /// Change status (Planned, In progress, Needs you, Done) and Cancel, which asks for the reason the bot sees.
  @MainActor
  static func statusActions(
    for item: BotItem, session: HostSession, from presenter: UIViewController, onChange: @escaping () -> Void
  ) -> [UIMenuElement] {
    let move: (BotItem.Status, String?) -> Void = { [weak presenter] status, reason in
      Task {
        do {
          try await session.api.setBotItems([item.uid], status: status, reason: reason)
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          onChange()
        } catch {
          UINotificationFeedbackGenerator().notificationOccurred(.error)
          let reason = TasksViewController.message(error)
          let alert = UIAlertController(
            title: status == .done
              ? String(format: String(localized: "bots.items.toast.doneFailed", defaultValue: "Couldn’t mark it done: %@"), reason)
              : String(
                format: String(localized: "bots.items.toast.moveFailed", defaultValue: "Couldn’t move %1$lld items: %2$@"), 1,
                reason),
            message: nil, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
          presenter?.present(alert, animated: true)
        }
      }
    }
    let statuses: [BotItem.Status] = [.planned, .working, .needsYou, .done]
    let change = UIMenu(
      title: String(localized: "bots.items.menu.changeStatus", defaultValue: "Change status"),
      image: Lucide.circleDashed.image(size: 18),
      children: statuses.map { status in
        UIAction(title: name(status), image: glyph(status), state: item.status == status ? .on : .off) { _ in
          guard item.status != status else { return }
          move(status, nil)
        }
      })
    var elements: [UIMenuElement] = [change]
    if item.status.isOpen {
      elements.append(
        UIAction(
          title: String(localized: "bots.items.menu.cancelShort", defaultValue: "Cancel"),
          image: Lucide.circleSlash.image(size: 18), attributes: .destructive
        ) { [weak presenter] _ in
          let alert = UIAlertController(
            title: String(format: String(localized: "bots.items.cancel.titleOne", defaultValue: "Cancel %@?"), item.title),
            message: String(localized: "bots.items.cancel.why", defaultValue: "The bot sees the reason. Nothing is deleted."),
            preferredStyle: .alert)
          let confirm = UIAlertAction(
            title: String(localized: "bots.items.cancel.confirmOne", defaultValue: "Cancel item"), style: .destructive
          ) { [weak alert] _ in
            let reason = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            move(.canceled, reason)
          }
          // The host refuses a cancel without a reason, so Cancel item waits for one.
          confirm.isEnabled = false
          alert.addTextField { field in
            field.placeholder = String(localized: "bots.items.cancel.placeholder", defaultValue: "Reason")
            field.autocapitalizationType = .sentences
            field.addAction(
              UIAction { [weak field] _ in
                confirm.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }, for: .editingChanged)
          }
          alert.addAction(
            UIAlertAction(title: String(localized: "bots.items.cancel.keep", defaultValue: "Keep"), style: .cancel))
          alert.addAction(confirm)
          presenter?.present(alert, animated: true)
        })
    }
    return elements
  }
}
