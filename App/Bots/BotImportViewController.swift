import OrcaCore
import UIKit

/// New bot › Import from another app (bots/MobileBotImportSheet.tsx): the old bot, an arrow and the new one's
/// picture, a name, then either the bots OpenClaw, Hermes or OpenBot keep on this desktop, or, for an app Orca
/// can't see, the two steps that have the old bot export itself (MobileBotImportExportSteps.tsx). Create makes
/// the bot here; its first turn brings the old one over. Keys and logins stay behind.
final class BotImportViewController: UITableViewController {
  enum Read {
    case loading
    case ready([BotImportSource])
    case failed
  }

  private struct Pick {
    let app: String
    let bot: BotImportSource.Candidate
    var key: String { "\(app):\(bot.agent)" }
  }

  private enum Row {
    case pick(Pick), otherApp, send, add, folder, choose
  }

  private let session: HostSession
  private let onCreated: (Bot) -> Void
  private var read: Read
  private var mascotId: String?
  private var agent: NewBotViewController.Agent
  private var exportView = false
  private var pickedKey: String?
  /// Follows the picked bot, or the exported folder, until the owner types one.
  private var typedName: String?
  private var folder: (path: String, shown: String, count: Int)?
  private var copied = false
  private var seeMessage = false
  private var creating = false
  private var error: String?

  private let oldAvatar = BotAvatarView(size: 56)
  private let oldTile = UIView()
  private let oldLabel = TextLabel(size: 12, color: Palette.textSecondary, alignment: .center)
  private let newAvatar = BotAvatarView(size: 72)
  private let existingAvatar = BotAvatarView(size: 72)
  private let shuffleButton = UIButton(type: .system)
  private let newLabel = TextLabel(size: 12, color: Palette.textSecondary, alignment: .center)
  private let lead = TextLabel(size: 13, color: Palette.textMuted, alignment: .center, lines: 0)
  private let nameField = OutlinedField()
  private let note = TextLabel(size: 13, color: Palette.textMuted, lines: 0)
  private lazy var header = makeHeader()
  private let reply = OutlinedField(multiline: true, minHeight: 3 * 22 + 4 + 24)

  init(session: HostSession, read: Read, mascotId: String?, agent: NewBotViewController.Agent, onCreated: @escaping (Bot) -> Void) {
    self.session = session
    self.read = read
    self.mascotId = mascotId
    self.agent = agent
    self.onCreated = onCreated
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.import.title", defaultValue: "Import from another app")
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.backAction = UIAction { [weak self] _ in self?.back() }
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.keyboardDismissMode = .interactive
    tableView.sectionHeaderTopPadding = 0

    nameField.placeholder = String(localized: "bots.new.namePlaceholder", defaultValue: "Name your bot")
    nameField.textField.autocorrectionType = .no
    nameField.textField.returnKeyType = .done
    nameField.onChange = { [weak self] text in
      guard let self else { return }
      self.typedName = String(text.prefix(64))
      // Clearing the name over a bot imported before turns Create into Update.
      self.refresh(reload: (self.again != nil) != self.showsUpdate)
    }
    reply.placeholder = String(localized: "bots.import.replyPlaceholder", defaultValue: "Paste its reply, if it wrote one")
    reply.textView.accessibilityLabel = String(localized: "bots.import.replyLabel", defaultValue: "Its reply")
    reply.onChange = { [weak self] text in
      if text.count > 200_000 { self?.reply.text = String(text.prefix(200_000)) }
    }

    if case .loading = read {
      Task {
        let sources = try? await session.api.botImportSources()
        read = sources.map { .ready($0) } ?? .failed
        refresh(reload: true)
      }
    }
    refresh(reload: true)
  }

  // MARK: State (MobileBotImportSheet's derivations)

  private var picks: [Pick] {
    guard case .ready(let sources) = read else { return [] }
    return sources.flatMap { source in source.bots.map { Pick(app: source.app, bot: $0) } }
  }

  private var loading: Bool {
    if case .loading = read { return true }
    return false
  }

  /// With nothing found there is nothing to pick: straight to asking the old bot.
  private var nothingFound: Bool { !loading && picks.isEmpty }
  private var exporting: Bool { exportView || nothingFound }

  private var pick: Pick? {
    exporting ? nil : picks.first { $0.key == pickedKey } ?? picks.first
  }

  /// "sage-export" names the new bot "Sage" (bot-import.ts botNameFromExportFolder).
  private static func name(fromExport path: String) -> String? {
    let base = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    let id = base.replacingOccurrences(of: "[-_ ]export$", with: "", options: [.regularExpression, .caseInsensitive])
    guard !id.replacingOccurrences(of: "[-_ ]+", with: "", options: .regularExpression).isEmpty else { return nil }
    let words = id.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return id }
    return first.uppercased() + words.dropFirst()
  }

  private static func basename(_ path: String) -> String {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
  }

  /// A bot imported before starts unnamed, so a second import is a choice.
  private var name: String {
    if let typedName { return typedName }
    if exporting { return folder.flatMap { Self.name(fromExport: $0.path) }.map { String($0.prefix(64)) } ?? "" }
    if let pick, pick.bot.importedAs == nil { return String(pick.bot.name.prefix(64)) }
    return ""
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The bot an earlier import made from the pick, once the name is left empty.
  private var again: (name: String, id: String?)? {
    guard let pick, let earlier = pick.bot.importedAs, trimmed.isEmpty else { return nil }
    return (earlier, pick.bot.importedAsId)
  }

  private var existing: Bot? {
    guard let id = again?.id else { return nil }
    return session.bots.bots.first { $0.id == id }
  }

  private var showsUpdate = false

  private var importFrom: [String: JSONValue]? {
    if exporting {
      guard let folder else { return nil }
      var from: [String: JSONValue] = ["app": "export", "path": .string(folder.path), "name": .string(trimmed)]
      if !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { from["reply"] = .string(reply.text) }
      return from
    }
    guard let pick else { return nil }
    return [
      "app": .string(pick.app), "path": .string(pick.bot.absolutePath), "agent": .string(pick.bot.agent),
      "name": .string(pick.bot.name),
    ]
  }

  private var canCreate: Bool {
    guard case .ready = read else { return false }
    return !trimmed.isEmpty && importFrom != nil && !creating
  }

  // MARK: Drawing

  private func refresh(reload: Bool) {
    showsUpdate = again != nil
    navigationItem.rightBarButtonItem = showsUpdate ? nil : navigationItem.rightBarButtonItem ?? createItem()
    navigationItem.rightBarButtonItem?.isEnabled = canCreate
    if nameField.text != name, !nameField.textField.isFirstResponder { nameField.text = name }
    nameField.placeholder =
      again != nil
      ? String(localized: "bots.import.nameAnother", defaultValue: "Name a new bot")
      : String(localized: "bots.new.namePlaceholder", defaultValue: "Name your bot")
    drawHero()
    if tableView.window == nil {
      tableView.reloadData()
    } else if reload {
      // The hero and name stay put, so typing keeps its focus.
      tableView.reloadSections(IndexSet(1...3), with: .none)
      UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
    } else {
      UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
    }
  }

  private func createItem() -> UIBarButtonItem {
    let create = UIBarButtonItem(
      title: String(localized: "bots.new.create", defaultValue: "Create"), style: .prominent, target: nil, action: nil)
    create.primaryAction = UIAction(title: create.title ?? "") { [weak self] _ in self?.create() }
    return create
  }

  private func drawHero() {
    let oldName: String? =
      exporting
      ? folder.map { Self.name(fromExport: $0.path) ?? Self.basename($0.path) } : pick?.bot.name
    if let oldName {
      oldAvatar.show(initialOf: oldName)
      oldAvatar.isHidden = false
      oldTile.isHidden = true
    } else {
      oldAvatar.isHidden = true
      oldTile.isHidden = false
    }
    oldLabel.text =
      exporting
      ? folder.map { Self.basename($0.path) } ?? String(localized: "bots.import.oldBot", defaultValue: "Old bot")
      : pick.map { BotImportSource.appNames[$0.app] ?? $0.app }
        ?? String(localized: "bots.import.oldBot", defaultValue: "Old bot")
    if let existing {
      existingAvatar.show(existing)
      newLabel.text = existing.name
    } else {
      if let mascotId { newAvatar.show(mascot: mascotId) }
      newLabel.text = String(localized: "bots.import.newBot", defaultValue: "New bot")
    }
    existingAvatar.isHidden = existing == nil
    newAvatar.isHidden = existing != nil
    shuffleButton.isHidden = existing != nil
    lead.text =
      exporting
      ? String(
        localized: "bots.import.exportDescription",
        defaultValue: "Ask your old bot for a copy of itself, then give the copy to your new bot.")
      : String(localized: "bots.import.description", defaultValue: "Your new bot reads the old one and sets itself up.")
    if let again {
      note.text = String(
        format: String(localized: "bots.import.importedBefore", defaultValue: "%1$@ came from this bot"), again.name)
    } else if exporting, nothingFound, case .ready = read {
      note.text = String(
        localized: "bots.import.noneFoundNote",
        defaultValue: "No bots found in OpenClaw (~/.openclaw), Hermes (~/.hermes) or OpenBot.")
    } else {
      note.text = nil
    }
    note.isHidden = note.text == nil
  }

  /// The hero, the line under it, the name and its note (MobileBotImportHero.tsx).
  private func makeHeader() -> UIView {
    oldTile.translatesAutoresizingMaskIntoConstraints = false
    oldTile.layer.cornerRadius = 14
    let dashes = CAShapeLayer()
    dashes.path = UIBezierPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 55, height: 55), cornerRadius: 14).cgPath
    dashes.fillColor = nil
    dashes.lineDashPattern = [3, 3]
    dashes.strokeColor = Palette.borderSubtle.resolvedColor(with: traitCollection).cgColor
    oldTile.layer.addSublayer(dashes)
    let unknown = TextLabel("?", size: 22, color: Palette.textMuted, alignment: .center)
    oldTile.addSubview(unknown)
    NSLayoutConstraint.activate([
      oldTile.widthAnchor.constraint(equalToConstant: 56), oldTile.heightAnchor.constraint(equalToConstant: 56),
      unknown.centerXAnchor.constraint(equalTo: oldTile.centerXAnchor),
      unknown.centerYAnchor.constraint(equalTo: oldTile.centerYAnchor),
    ])
    let oldSide = UIStackView(arrangedSubviews: [oldAvatar, oldTile, oldLabel])
    oldSide.axis = .vertical
    oldSide.alignment = .center
    oldSide.spacing = Spacing.xs

    var shuffle = UIButton.Configuration.plain()
    shuffle.image = Lucide.shuffle.image(size: 14)
    shuffle.baseForegroundColor = Palette.textSecondary
    shuffle.background.backgroundColor = Palette.bgRaised
    shuffle.background.cornerRadius = 11
    shuffle.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
    shuffleButton.configuration = shuffle
    shuffleButton.accessibilityLabel = String(localized: "bots.new.shuffle", defaultValue: "Another picture")
    shuffleButton.translatesAutoresizingMaskIntoConstraints = false
    shuffleButton.addAction(UIAction { [weak self] _ in self?.shuffle() }, for: .primaryActionTriggered)
    let picture = UIView()
    picture.translatesAutoresizingMaskIntoConstraints = false
    for view in [newAvatar, existingAvatar, shuffleButton] as [UIView] { picture.addSubview(view) }
    NSLayoutConstraint.activate([
      picture.widthAnchor.constraint(equalToConstant: 72), picture.heightAnchor.constraint(equalToConstant: 72),
      newAvatar.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
      newAvatar.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
      existingAvatar.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
      existingAvatar.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
      shuffleButton.trailingAnchor.constraint(equalTo: picture.trailingAnchor, constant: Spacing.sm),
      shuffleButton.bottomAnchor.constraint(equalTo: picture.bottomAnchor, constant: Spacing.sm),
    ])
    let newSide = UIStackView(arrangedSubviews: [picture, newLabel])
    newSide.axis = .vertical
    newSide.alignment = .center
    newSide.spacing = Spacing.xs
    for side in [oldSide, newSide] { side.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true }
    let arrow = LucideView(.arrowRight, size: 20, color: Palette.textMuted)
    let hero = UIStackView(arrangedSubviews: [oldSide, arrow, newSide])
    hero.alignment = .center
    hero.spacing = Spacing.lg

    // The hero keeps its own width, centred over the full-width name.
    let centered = UIStackView(arrangedSubviews: [hero])
    centered.axis = .vertical
    centered.alignment = .center
    let column = UIStackView(arrangedSubviews: [centered, lead, nameField, note])
    column.axis = .vertical
    column.alignment = .fill
    column.setCustomSpacing(Spacing.sm, after: centered)
    column.setCustomSpacing(Spacing.md, after: lead)
    column.setCustomSpacing(Spacing.sm, after: nameField)
    let header = UIView()
    column.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: header.topAnchor, constant: Spacing.sm),
      column.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -Spacing.sm),
      column.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: header.layoutMarginsGuide.trailingAnchor),
    ])
    return header
  }

  private func shuffle() {
    let others = BotAvatarView.mascotIds.filter { $0 != mascotId }
    guard let next = others.randomElement() else { return }
    mascotId = next
    UISelectionFeedbackGenerator().selectionChanged()
    UIView.transition(with: newAvatar, duration: 0.2, options: .transitionCrossDissolve) {
      self.newAvatar.show(mascot: next)
    }
  }

  // MARK: Actions

  private func back() {
    if exportView, !picks.isEmpty {
      exportView = false
      typedName = nil
      refresh(reload: true)
    } else {
      navigationController?.popViewController(animated: true)
    }
  }

  private func create() {
    guard canCreate, let importFrom else { return }
    creating = true
    error = nil
    view.endEditing(true)
    refresh(reload: false)
    let api = session.api
    let name = trimmed
    let agent = agent.id
    let mascotId = mascotId
    Task {
      do {
        guard let bot = try await api.createBot(name: name, agent: agent, mascotId: mascotId, extra: ["importFrom": .object(importFrom)])
        else { throw CancellationError() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await session.refresh()
        navigationController?.dismiss(animated: true) { self.onCreated(bot) }
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        creating = false
        self.error =
          (error as? RPCError)?.message ?? String(localized: "bots.new.failed", defaultValue: "Couldn’t create the bot")
        refresh(reload: true)
      }
    }
  }

  /// The bot an earlier import made gets what's new instead of a second bot: its Home Chat opens.
  private func update() {
    guard let existing else { return }
    navigationController?.dismiss(animated: true) { self.onCreated(existing) }
  }

  private func copyPrompt() {
    UIPasteboard.general.string = BotImportExport.prompt
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    copied = true
    refresh(reload: true)
  }

  private func chooseFolder() {
    navigationController?.pushViewController(
      HostFolderPickerViewController(session: session) { [weak self] picked in
        guard let self else { return }
        self.folder = picked
        self.refresh(reload: true)
        self.navigationController?.popToViewController(self, animated: true)
      }, animated: true)
  }

  // MARK: Table

  // The hero and name, the picks or the steps, its reply, then the agent.
  private var rows: [Row] {
    if exporting {
      return [.send, .add] + (folder == nil ? [] : [.folder]) + [.choose]
    }
    return picks.map { .pick($0) } + [.otherApp]
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 4 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: 0
    case 1: rows.count
    case 2: exporting && folder != nil ? 1 : 0
    default: 1
    }
  }

  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    switch section {
    case 0: return header
    case 1 where !exporting:
      // Bring over, with how many it found on the right.
      let title = TextLabel(
        String(localized: "bots.import.bringOver", defaultValue: "Bring over"), size: 13, weight: .semibold,
        color: Palette.textSecondary)
      let count = TextLabel(
        loading
          ? String(format: String(localized: "bots.import.lookingOn", defaultValue: "Looking on %@…"), session.name)
          : String(
            format: String(localized: "bots.import.foundOn", defaultValue: "%1$lld found on %2$@"), picks.count, session.name),
        size: 13, color: Palette.textMuted)
      let row = UIStackView(arrangedSubviews: [title, UIView(), count])
      row.isLayoutMarginsRelativeArrangement = true
      row.directionalLayoutMargins = .init(top: Spacing.lg, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg)
      return row
    default: return nil
    }
  }

  override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    section == 0 || (section == 1 && !exporting) ? UITableView.automaticDimension : Spacing.md
  }

  override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    guard section == 3 else { return nil }
    var lines: [TextLabel] = []
    if case .failed = read {
      lines.append(
        TextLabel(
          String(format: String(localized: "bots.list.updateOrcaOn", defaultValue: "Update Orca on %@"), session.name),
          size: 13, color: Palette.statusRed, lines: 0))
    }
    if let error { lines.append(TextLabel(error, size: 13, color: Palette.statusRed, lines: 0)) }
    if again == nil {
      lines.append(
        TextLabel(
          String(localized: "bots.import.keysStay", defaultValue: "Keys and logins stay behind"), size: 13,
          color: Palette.textMuted, lines: 0))
    }
    let stack = UIStackView(arrangedSubviews: lines)
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    stack.isLayoutMarginsRelativeArrangement = true
    stack.directionalLayoutMargins = .init(top: Spacing.sm, leading: Spacing.lg + Spacing.xs, bottom: Spacing.lg, trailing: Spacing.lg)
    return stack
  }

  override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    section == 3 ? UITableView.automaticDimension : .leastNonzeroMagnitude
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.accessoryType = .none
    cell.accessoryView = nil
    cell.selectionStyle = .default
    cell.contentView.subviews.filter { $0.tag == 9 }.forEach { $0.removeFromSuperview() }
    cell.contentConfiguration = nil
    switch indexPath.section {
    case 2:
      cell.selectionStyle = .none
      cell.backgroundConfiguration = .clear()
      reply.tag = 9
      cell.contentView.addSubview(reply)
      reply.pin(to: cell.contentView)
      return cell
    case 3:
      cell.backgroundConfiguration = nil
      return again == nil ? agentCell(cell) : updateCell(cell)
    default:
      cell.backgroundConfiguration = nil
    }
    switch rows[indexPath.row] {
    case .pick(let pick):
      var content = UIListContentConfiguration.subtitleCell()
      content.text = pick.bot.name
      content.secondaryText = detail(pick)
      content.secondaryTextProperties.color = Palette.textSecondary
      content.image = Self.initialImage(pick.bot.name)
      content.imageProperties.cornerRadius = 7
      cell.contentConfiguration = content
      cell.accessoryType = pick.key == self.pick?.key ? .checkmark : .none
    case .otherApp:
      var content = UIListContentConfiguration.subtitleCell()
      content.text = String(localized: "bots.import.otherApp", defaultValue: "Another app…")
      content.secondaryText = String(localized: "bots.import.otherAppNote", defaultValue: "Your old bot copies its files for you")
      content.secondaryTextProperties.color = Palette.textSecondary
      content.image = Self.dashedPlus
      cell.contentConfiguration = content
      cell.accessoryType = .disclosureIndicator
    case .send:
      cell.selectionStyle = .none
      cell.contentConfiguration = StepRowConfiguration(
        number: 1, done: copied, title: String(localized: "bots.import.sendStep", defaultValue: "Send your old bot this message"),
        subtitle: copied
          ? String(
            localized: "bots.import.copiedNote", defaultValue: "Copied. Paste it to your old bot wherever you chat with it.")
          : nil,
        actions: [
          (
            copied
              ? String(localized: "bots.import.copyAgain", defaultValue: "Copy again")
              : String(localized: "bots.import.copyMessage", defaultValue: "Copy message"),
            { [weak self] in self?.copyPrompt() }
          ),
          (
            String(localized: "bots.import.seeMessage", defaultValue: "See the message"),
            { [weak self] in
              guard let self else { return }
              self.seeMessage.toggle()
              self.refresh(reload: true)
            }
          ),
        ],
        prompt: seeMessage ? BotImportExport.prompt : nil)
    case .add:
      cell.selectionStyle = .none
      cell.contentConfiguration = StepRowConfiguration(
        number: 2, done: folder != nil, title: String(localized: "bots.import.addStep", defaultValue: "Add the folder it made"),
        subtitle: String(
          format: String(
            localized: "bots.import.addStepNote", defaultValue: "It saves a folder ending in -export in Downloads on %@."),
          session.name),
        actions: [], prompt: nil)
    case .folder:
      cell.selectionStyle = .none
      var content = UIListContentConfiguration.subtitleCell()
      content.text = folder?.shown
      content.secondaryText = String(
        format: String(localized: "bots.import.folderItems", defaultValue: "%lld items"), folder?.count ?? 0)
      content.secondaryTextProperties.color = Palette.textSecondary
      content.image = Lucide.folder.image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
      cell.contentConfiguration = content
      let remove = UIButton(type: .system)
      remove.setImage(Lucide.x.image(size: 16), for: .normal)
      remove.tintColor = Palette.textMuted
      remove.accessibilityLabel = String(
        format: String(localized: "bots.import.removePath", defaultValue: "Remove %@"), Self.basename(folder?.path ?? ""))
      remove.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
      remove.addAction(
        UIAction { [weak self] _ in
          self?.folder = nil
          self?.refresh(reload: true)
        }, for: .primaryActionTriggered)
      cell.accessoryView = remove
    case .choose:
      var content = UIListContentConfiguration.cell()
      content.text =
        folder == nil
        ? String(localized: "bots.import.chooseFolderRow", defaultValue: "Choose a folder…")
        : String(localized: "bots.import.chooseAnother", defaultValue: "Choose another folder…")
      content.image = Lucide.folderPlus.image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
      cell.contentConfiguration = content
      cell.accessoryType = .disclosureIndicator
    }
    return cell
  }

  private func detail(_ pick: Pick) -> String {
    if let earlier = pick.bot.importedAs {
      return String(format: String(localized: "bots.import.importedAs", defaultValue: "imported before as %@"), earlier)
    }
    let kind =
      pick.app == "hermes"
      ? pick.bot.agent == "default"
        ? String(localized: "bots.import.defaultProfile", defaultValue: "default profile")
        : String(localized: "bots.import.profile", defaultValue: "profile")
      : String(localized: "bots.import.agent", defaultValue: "agent")
    return String(
      format: String(localized: "bots.import.rowDetail", defaultValue: "%1$@ %2$@"), BotImportSource.appNames[pick.app] ?? pick.app,
      kind)
  }

  /// Agent, as New bot shows it, with its choice menu.
  private func agentCell(_ cell: UITableViewCell) -> UITableViewCell {
    var content = UIListContentConfiguration.valueCell()
    content.text = String(localized: "bots.new.agent", defaultValue: "Agent")
    let value = NSMutableAttributedString(attachment: NSTextAttachment(image: agent.mark.image(size: 16)))
    value.append(NSAttributedString(string: " " + agent.title))
    content.secondaryAttributedText = value
    cell.contentConfiguration = content
    let picker = UIButton(type: .system)
    picker.tag = 9
    picker.showsMenuAsPrimaryAction = true
    picker.menu = UIMenu(
      children: NewBotViewController.agents.map { choice in
        UIAction(title: choice.title, image: choice.mark.image(size: 18), state: choice.id == agent.id ? .on : .off) {
          [weak self] _ in
          self?.agent = choice
          self?.tableView.reloadSections([3], with: .none)
        }
      })
    cell.contentView.addSubview(picker)
    picker.pin(to: cell.contentView)
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  /// Update <bot>, in place of Agent and Create, for a pick an earlier import made a bot from.
  private func updateCell(_ cell: UITableViewCell) -> UITableViewCell {
    var content = UIListContentConfiguration.cell()
    content.text = String(format: String(localized: "bots.import.update", defaultValue: "Update %@"), again?.name ?? "")
    content.textProperties.alignment = .center
    content.textProperties.font = .systemFont(ofSize: 17, weight: .semibold)
    content.textProperties.color = existing == nil ? Palette.textMuted : Palette.accentBlue
    cell.contentConfiguration = content
    cell.selectionStyle = existing == nil ? .none : .default
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 3 {
      if again != nil { update() }
      return
    }
    guard indexPath.section == 1 else { return }
    switch rows[indexPath.row] {
    case .pick(let pick):
      Haptics.select()
      pickedKey = pick.key
      typedName = nil
      refresh(reload: true)
    case .otherApp:
      Haptics.select()
      typedName = nil
      exportView = true
      refresh(reload: true)
    case .choose:
      Haptics.select()
      chooseFolder()
    default:
      break
    }
  }

  // MARK: Pictures

  /// A 28 pt tile with a name's initial, as MobileBotAvatar draws a text avatar.
  private static func initialImage(_ name: String) -> UIImage {
    let avatar = BotAvatarView(size: 28)
    avatar.show(initialOf: name)
    avatar.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
    avatar.layoutIfNeeded()
    return UIGraphicsImageRenderer(bounds: avatar.bounds).image { avatar.layer.render(in: $0.cgContext) }
  }

  /// Another app…'s dashed tile with a plus.
  private static var dashedPlus: UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { _ in
      let path = UIBezierPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 27, height: 27), cornerRadius: 7)
      path.setLineDash([3, 3], count: 2, phase: 0)
      path.lineWidth = 1
      Palette.borderSubtle.setStroke()
      path.stroke()
      Lucide.plus.image(size: 14).withTintColor(Palette.textMuted).draw(at: CGPoint(x: 7, y: 7))
    }
  }
}

/// One of Another app's two steps (MobileBotImportExportSteps.tsx): its number, or a tick once done, a title, a
/// line under it, and text buttons.
private struct StepRowConfiguration: UIContentConfiguration {
  let number: Int
  let done: Bool
  let title: String
  let subtitle: String?
  let actions: [(String, () -> Void)]
  let prompt: String?

  func makeContentView() -> UIView & UIContentView { StepRowView(configuration: self) }
  func updated(for state: UIConfigurationState) -> StepRowConfiguration { self }
}

private final class StepRowView: UIView, UIContentView {
  var configuration: UIContentConfiguration {
    didSet { apply() }
  }

  private let mark = UIView()
  private let number = TextLabel(size: 12, weight: .semibold, color: Palette.textSecondary, alignment: .center)
  private let tick = UIImageView(image: Lucide.check.image(size: 13, strokeWidth: 3))
  private let column = UIStackView()

  init(configuration: StepRowConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    mark.translatesAutoresizingMaskIntoConstraints = false
    mark.layer.cornerRadius = 11
    tick.tintColor = Palette.bgBase
    tick.translatesAutoresizingMaskIntoConstraints = false
    for view in [number, tick] as [UIView] { mark.addSubview(view) }
    column.axis = .vertical
    column.alignment = .leading
    column.spacing = Spacing.xs
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(mark)
    addSubview(column)
    NSLayoutConstraint.activate([
      mark.widthAnchor.constraint(equalToConstant: 22), mark.heightAnchor.constraint(equalToConstant: 22),
      mark.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      number.centerXAnchor.constraint(equalTo: mark.centerXAnchor), number.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
      tick.centerXAnchor.constraint(equalTo: mark.centerXAnchor), tick.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
      column.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: Spacing.lg),
      column.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
      column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
    ])
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let configuration = configuration as? StepRowConfiguration else { return }
    mark.backgroundColor = configuration.done ? Palette.textPrimary : Palette.bgRaised
    number.text = "\(configuration.number)"
    number.isHidden = configuration.done
    tick.isHidden = !configuration.done
    for view in column.arrangedSubviews { view.removeFromSuperview() }
    column.addArrangedSubview(TextLabel(configuration.title, size: 17, lines: 0))
    if let subtitle = configuration.subtitle {
      column.addArrangedSubview(TextLabel(subtitle, size: 15, color: Palette.textSecondary, lines: 0))
    }
    if !configuration.actions.isEmpty {
      let buttons = UIStackView()
      buttons.spacing = Spacing.xs
      for (title, action) in configuration.actions {
        var text = UIButton.Configuration.plain()
        text.attributedTitle = AttributedString(
          title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15), .foregroundColor: Palette.textSecondary]))
        text.contentInsets = .init(top: 6, leading: Spacing.sm, bottom: 6, trailing: Spacing.sm)
        buttons.addArrangedSubview(UIButton(configuration: text, primaryAction: UIAction { _ in action() }))
      }
      column.addArrangedSubview(buttons)
    }
    if let prompt = configuration.prompt {
      let text = TextLabel(prompt, size: 13, color: Palette.textSecondary, lines: 0)
      column.addArrangedSubview(text)
    }
  }
}
