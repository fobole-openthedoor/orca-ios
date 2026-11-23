import OrcaCore
import UIKit

/// New bot (bots/MobileNewBotSheet.tsx): a mascot to shuffle, a name, and the agent it runs. Create makes it
/// on this desktop and opens its Home Chat, where the bot speaks first.
final class NewBotViewController: UITableViewController {
  struct Agent {
    let id: String
    let title: String
    let mark: FilledIcon
  }

  static let agents = [
    Agent(id: "claude", title: "Claude Code", mark: AgentMark.claude),
    Agent(id: "codex", title: "Codex", mark: AgentMark.codex),
  ]

  private let session: HostSession
  private let onCreated: (Bot) -> Void
  private var mascotId = BotAvatarView.mascotIds.randomElement()
  private var agent = agents[0]
  /// The template this bot starts from: its purpose seeds the bot's SOUL.md.
  private var template: BotTemplate?
  private var mascotHeader: UIView?
  /// What other apps keep on this desktop; Import from another app shows once the desktop answered.
  private var importRead = BotImportViewController.Read.loading
  private let avatar = BotAvatarView(size: 72)
  private let nameField = UITextField()
  private var creating = false

  init(session: HostSession, onCreated: @escaping (Bot) -> Void) {
    self.session = session
    self.onCreated = onCreated
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func sheet(session: HostSession, onCreated: @escaping (Bot) -> Void) -> UIViewController {
    let navigation = UINavigationController(rootViewController: NewBotViewController(session: session, onCreated: onCreated))
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.new.title", defaultValue: "New bot")
    navigationItem.subtitle = String(
      format: String(localized: "bots.new.runsOnHost", defaultValue: "Runs on %@."), session.name)
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    let create = UIBarButtonItem(
      title: String(localized: "bots.new.create", defaultValue: "Create"), style: .prominent, target: nil, action: nil)
    create.primaryAction = UIAction(title: String(localized: "bots.new.create", defaultValue: "Create")) {
      [weak self] _ in self?.create()
    }
    navigationItem.rightBarButtonItem = create
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    mascotHeader = makeHeader()
    tableView.keyboardDismissMode = .interactive
    // Only a desktop that lists other apps' bots takes `importFrom`; an older one drops it.
    Task {
      let sources = try? await session.api.botImportSources()
      importRead = sources.map { .ready($0) } ?? .failed
      tableView.reloadSections([0], with: .none)
    }

    nameField.placeholder = String(localized: "bots.new.namePlaceholder", defaultValue: "Name your bot")
    nameField.font = .systemFont(ofSize: 17)
    nameField.returnKeyType = .done
    nameField.autocorrectionType = .no
    nameField.clearButtonMode = .whileEditing
    nameField.addAction(UIAction { [weak self] _ in self?.updateCreate() }, for: .editingChanged)
    nameField.addAction(UIAction { [weak self] _ in self?.create() }, for: .editingDidEndOnExit)
    updateCreate()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    nameField.becomeFirstResponder()
  }

  private var name: String { (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

  private func updateCreate() {
    navigationItem.rightBarButtonItem?.isEnabled = !name.isEmpty && !creating
  }

  /// The mascot, with a small button to draw another.
  private func makeHeader() -> UIView {
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 104))
    if let mascotId { avatar.show(mascot: mascotId) }
    header.addSubview(avatar)
    var shuffleConfiguration = UIButton.Configuration.glass()
    shuffleConfiguration.cornerStyle = .capsule
    shuffleConfiguration.image = Lucide.shuffle.image(size: 14, strokeWidth: 2)
    shuffleConfiguration.baseForegroundColor = Palette.textPrimary
    shuffleConfiguration.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
    let shuffle = UIButton(configuration: shuffleConfiguration)
    shuffle.accessibilityLabel = String(localized: "bots.new.shuffle", defaultValue: "Another picture")
    shuffle.translatesAutoresizingMaskIntoConstraints = false
    shuffle.addAction(UIAction { [weak self] _ in self?.shuffle() }, for: .primaryActionTriggered)
    header.addSubview(shuffle)
    NSLayoutConstraint.activate([
      avatar.centerXAnchor.constraint(equalTo: header.centerXAnchor),
      avatar.topAnchor.constraint(equalTo: header.topAnchor, constant: Spacing.md),
      shuffle.centerXAnchor.constraint(equalTo: avatar.trailingAnchor, constant: -4),
      shuffle.centerYAnchor.constraint(equalTo: avatar.bottomAnchor, constant: -4),
    ])
    return header
  }

  private func shuffle() {
    let others = BotAvatarView.mascotIds.filter { $0 != mascotId }
    guard let next = others.randomElement() else { return }
    mascotId = next
    UISelectionFeedbackGenerator().selectionChanged()
    UIView.transition(with: avatar, duration: 0.2, options: .transitionCrossDissolve) {
      self.avatar.show(mascot: next)
    }
  }

  private func create() {
    guard !name.isEmpty, !creating else { return }
    creating = true
    updateCreate()
    nameField.resignFirstResponder()
    let api = session.api
    let name = name
    let agent = agent.id
    let mascotId = mascotId
    let templateFields = templateFields
    Task {
      do {
        guard let bot = try await api.createBot(name: name, agent: agent, mascotId: mascotId, extra: templateFields)
        else {
          throw CancellationError()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await session.refresh()
        dismiss(animated: true) { self.onCreated(bot) }
      } catch {
        creating = false
        updateCreate()
        let alert = UIAlertController(
          title: String(localized: "bots.new.failed", defaultValue: "Couldn’t create the bot"),
          message: (error as? LocalizedError)?.errorDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
    }
  }

  /// What a template adds to the create (bot-proposal.ts proposalCreateParams). A host without template
  /// packages takes the seed alone, and a newer template's id only from a host that knows it.
  private var templateFields: [String: JSONValue] {
    guard let template else { return [:] }
    let packages = session.status?.supports("bots.templates.v2") ?? false
    var seed: [String: JSONValue] = [
      "purpose": .string(template.line), "watches": .string(template.watches), "does": .string(template.does),
      "reports": .string(template.reports),
    ]
    if packages || template.isLegacy { seed["templateId"] = .string(template.id) }
    var fields: [String: JSONValue] = ["seed": .object(seed), "templateNameShown": .string(template.shownName)]
    if packages {
      fields["fromTemplate"] = ["id": .string(template.id), "skills": .array(template.skills.map { .string($0) })]
    }
    return fields
  }

  private func use(_ picked: BotTemplate?) {
    template = picked
    if let picked {
      nameField.text = picked.shownName
      mascotId = picked.mascot
      avatar.show(mascot: picked.mascot)
      navigationItem.subtitle = String(
        format: String(localized: "bots.templates.originTemplateNamed", defaultValue: "From the %@ template"),
        picked.shownName)
    } else {
      navigationItem.subtitle = String(
        format: String(localized: "bots.new.runsOnHost", defaultValue: "Runs on %@."), session.name)
    }
    updateCreate()
    tableView.reloadData()
  }

  // MARK: Table

  // Use template, Import from another app and From a link, then the name, then the agent.
  override func numberOfSections(in tableView: UITableView) -> Int { 3 }

  private enum StartRow { case template, importing, link }

  private var startRows: [StartRow] {
    if case .ready = importRead { return [.template, .importing, .link] }
    return [.template, .link]
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? startRows.count : 1
  }

  /// "We found a bot in OpenClaw." (bot-import.ts botImportNudge): OpenClaw's, else Hermes'.
  private var importNudge: String? {
    guard case .ready(let sources) = importRead else { return nil }
    for app in ["openclaw", "hermes"] {
      let count = sources.first { $0.app == app }?.bots.count ?? 0
      guard count > 0, let label = BotImportSource.appNames[app] else { continue }
      return count == 1
        ? String(format: String(localized: "bots.import.nudgeOne", defaultValue: "We found a bot in %@."), label)
        : String(
          format: String(localized: "bots.import.nudgeMany", defaultValue: "We found %1$lld bots in %2$@."), count, label)
    }
    return nil
  }


  // The mascot sits between the template row and the name, as on the official sheet.
  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    section == 1 ? mascotHeader : nil
  }

  override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    section == 1 ? 104 : UITableView.automaticDimension
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    guard indexPath.section == 0, !creating else { return }
    switch startRows[indexPath.row] {
    case .template:
      navigationController?.pushViewController(BotTemplatesViewController { [weak self] in self?.use($0) }, animated: true)
    case .link:
      navigationController?.pushViewController(
        BotShareLinkViewController(session: session, agent: agent.id, onCreated: onCreated), animated: true)
    case .importing:
      navigationController?.pushViewController(
        BotImportViewController(
          session: session, read: importRead, mascotId: mascotId, agent: agent, onCreated: onCreated),
        animated: true)
    }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .none
    cell.accessoryType = .none
    if indexPath.section == 0 {
      var content = UIListContentConfiguration.valueCell()
      switch startRows[indexPath.row] {
      case .template:
        content.text = String(localized: "bots.new.fromTemplate", defaultValue: "Use template")
        content.secondaryText = template?.shownName
      case .importing:
        content = UIListContentConfiguration.subtitleCell()
        content.text = String(localized: "bots.import.title", defaultValue: "Import from another app")
        content.secondaryText = importNudge
        content.secondaryTextProperties.color = Palette.textSecondary
      case .link:
        content = UIListContentConfiguration.subtitleCell()
        content.text = String(localized: "bots.share.receive.fromLink", defaultValue: "From a link")
        content.secondaryText = String(localized: "bots.share.receive.pasteDescription", defaultValue: "Paste a link someone shared.")
        content.secondaryTextProperties.color = Palette.textSecondary
      }
      cell.contentConfiguration = content
      cell.contentView.subviews.filter { $0 is UIButton }.forEach { $0.removeFromSuperview() }
      cell.accessoryView = nil
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
      return cell
    }
    if indexPath.section == 1 {
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
    }
    var content = UIListContentConfiguration.valueCell()
    content.text = String(localized: "bots.new.agent", defaultValue: "Agent")
    content.secondaryText = agent.title
    cell.contentConfiguration = content
    // The agent's mark leads its name, as on the official row; the whole row opens the choice menu.
    let picker = UIButton(type: .system)
    picker.showsMenuAsPrimaryAction = true
    picker.menu = UIMenu(
      children: Self.agents.map { choice in
        UIAction(
          title: choice.title, image: choice.mark.image(size: 18),
          state: choice.id == agent.id ? .on : .off
        ) { [weak self] _ in
          self?.agent = choice
          self?.tableView.reloadSections([2], with: .none)
        }
      })
    picker.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.subviews.filter { $0 is UIButton }.forEach { $0.removeFromSuperview() }
    cell.contentView.addSubview(picker)
    picker.pin(to: cell.contentView)
    cell.accessoryView = UIImageView(image: Lucide.chevronsUpDown.image(size: 14))
    cell.accessoryView?.tintColor = Palette.textMuted
    return cell
  }
}
