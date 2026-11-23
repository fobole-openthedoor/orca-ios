import OrcaCore
import UIKit

/// Import › Another app (bots/MobileBotImportExportSteps.tsx): for an old bot whose files Orca can't see.
/// The owner sends it a message, it saves a `<name>-export` folder in Downloads, and the new bot reads that.
final class BotImportExportViewController: UITableViewController, UITextViewDelegate {
  /// The message the owner pastes into the old bot (bot-import.ts BOT_IMPORT_EXPORT_PROMPT).
  static let prompt =
    "I'm moving to another assistant and need a complete copy of your setup. Don't change, pause or delete anything. If you keep your setup in files (persona or soul, memory, user notes, skills, routines), save copies of those files, unchanged, into a folder in my Downloads called <your name>-export, then list what you saved. Write out in full in your reply anything that isn't in a file. Never include passwords, API keys, tokens or cookies."

  private let session: HostSession
  private let onPick: (String, [String: JSONValue]) -> Void
  private var copied = false
  private var folder: (path: String, shown: String, count: Int)?
  private let reply = UITextView()

  init(session: HostSession, onPick: @escaping (String, [String: JSONValue]) -> Void) {
    self.session = session
    self.onPick = onPick
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.import.otherApp", defaultValue: "Another app…").replacingOccurrences(of: "…", with: "")
    navigationItem.largeTitleDisplayMode = .never
    let next = UIBarButtonItem(
      title: String(localized: "bots.share.receive.continue", defaultValue: "Continue"), style: .prominent,
      target: nil, action: nil)
    next.primaryAction = UIAction(title: next.title ?? "") { [weak self] _ in self?.finish() }
    navigationItem.rightBarButtonItem = next
    reply.font = .systemFont(ofSize: 15)
    reply.backgroundColor = .clear
    reply.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.keyboardDismissMode = .interactive
    update()
  }

  private func update() {
    navigationItem.rightBarButtonItem?.isEnabled = folder != nil
  }

  /// "sage-export" names the new bot "Sage" (bot-import.ts botNameFromExportFolder).
  private static func name(from path: String) -> String {
    let base = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    let id = base.replacingOccurrences(of: "[-_ ]export$", with: "", options: [.regularExpression, .caseInsensitive])
    let words = id.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return base }
    return first.uppercased() + words.dropFirst()
  }

  private func finish() {
    guard let folder else { return }
    let name = Self.name(from: folder.path)
    var from: [String: JSONValue] = ["app": "export", "path": .string(folder.path), "name": .string(name)]
    let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { from["reply"] = .string(String(text.prefix(200_000))) }
    onPick(name, from)
    if let root = navigationController?.viewControllers.first {
      navigationController?.popToViewController(root, animated: true)
    }
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { 3 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: 2
    case 1: folder == nil ? 1 : 2
    default: 1
    }
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0: "1. " + String(localized: "bots.import.sendStep", defaultValue: "Send your old bot this message")
    case 1: "2. " + String(localized: "bots.import.addStep", defaultValue: "Add the folder it made")
    default: String(localized: "bots.import.replyLabel", defaultValue: "Its reply")
    }
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    section == 1
      ? String(
        format: String(localized: "bots.import.addStepNote", defaultValue: "It saves a folder ending in -export in Downloads on %@."),
        session.name)
      : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .default
    cell.accessoryType = .none
    var content = UIListContentConfiguration.cell()
    content.imageProperties.tintColor = Palette.textSecondary
    switch (indexPath.section, indexPath.row) {
    case (0, 0):
      content.text = copied
        ? String(localized: "bots.import.copyAgain", defaultValue: "Copy again")
        : String(localized: "bots.import.copyMessage", defaultValue: "Copy message")
      content.image = (copied ? Lucide.check : Lucide.copy).image(size: 18)
      content.textProperties.color = Palette.accentBlue
    case (0, _):
      content.text = String(localized: "bots.import.seeMessage", defaultValue: "See the message")
      content.image = Lucide.messageSquare.image(size: 18)
    case (1, 0) where folder != nil:
      content = UIListContentConfiguration.subtitleCell()
      content.text = folder?.shown
      content.secondaryText = String(
        format: String(localized: "bots.import.folderItems", defaultValue: "%lld items"), folder?.count ?? 0)
      content.secondaryTextProperties.color = Palette.textSecondary
      content.image = Lucide.folder.image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
      cell.selectionStyle = .none
    case (1, _):
      content.text = folder == nil
        ? String(localized: "bots.import.chooseFolderRow", defaultValue: "Choose a folder…")
        : String(localized: "bots.import.chooseAnother", defaultValue: "Choose another folder…")
      content.image = Lucide.folderPlus.image(size: 18)
      cell.accessoryType = .disclosureIndicator
    default:
      cell.contentConfiguration = nil
      cell.selectionStyle = .none
      if reply.superview !== cell.contentView {
        reply.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(reply)
        NSLayoutConstraint.activate([
          reply.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor, constant: -4),
          reply.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
          reply.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 6),
          reply.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -6),
          reply.heightAnchor.constraint(equalToConstant: 120),
        ])
        let placeholder = UILabel()
        placeholder.text = String(localized: "bots.import.replyPlaceholder", defaultValue: "Paste its reply, if it wrote one")
        placeholder.textColor = Palette.textMuted
        placeholder.font = reply.font
        placeholder.tag = 7
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        reply.addSubview(placeholder)
        NSLayoutConstraint.activate([
          placeholder.leadingAnchor.constraint(equalTo: reply.leadingAnchor, constant: 5),
          placeholder.topAnchor.constraint(equalTo: reply.topAnchor, constant: 8),
        ])
      }
      return cell
    }
    cell.contentConfiguration = content
    return cell
  }

  func textViewDidChange(_ textView: UITextView) {
    textView.viewWithTag(7)?.isHidden = !textView.text.isEmpty
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch (indexPath.section, indexPath.row) {
    case (0, 0):
      UIPasteboard.general.string = Self.prompt
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      copied = true
      tableView.reloadSections([0], with: .none)
    case (0, _):
      let alert = UIAlertController(title: nil, message: Self.prompt, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
      present(alert, animated: true)
    case (1, let row) where row == (folder == nil ? 0 : 1):
      navigationController?.pushViewController(
        HostFolderPickerViewController(session: session) { [weak self] picked in
          guard let self else { return }
          self.folder = picked
          self.update()
          self.tableView.reloadSections([1], with: .automatic)
          self.navigationController?.popToViewController(self, animated: true)
        }, animated: true)
    default:
      break
    }
  }
}

/// A folder on the desktop (bots/MobileBotExportFolderPage.tsx), starting in Downloads.
final class HostFolderPickerViewController: UITableViewController {
  private let session: HostSession
  private let path: String?
  private let home: String?
  private let onPick: ((path: String, shown: String, count: Int)) -> Void
  private var directory: HostDirectory?
  private var loading = true

  init(session: HostSession, path: String? = nil, home: String? = nil, onPick: @escaping ((path: String, shown: String, count: Int)) -> Void) {
    self.session = session
    self.path = path
    self.home = home
    self.onPick = onPick
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.import.chooseFolderTitle", defaultValue: "Choose a folder")
    navigationItem.subtitle = String(format: String(localized: "bots.import.onHost", defaultValue: "On %@"), session.name)
    navigationItem.largeTitleDisplayMode = .never
    let select = UIBarButtonItem(
      title: String(localized: "bots.import.selectFolder", defaultValue: "Select folder"), style: .prominent,
      target: nil, action: nil)
    select.primaryAction = UIAction(title: select.title ?? "") { [weak self] _ in self?.selectCurrent() }
    select.isEnabled = false
    navigationItem.rightBarButtonItem = select
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    let api = session.api
    let path = path
    Task {
      do {
        if let path {
          directory = try await api.browseDirectory(path)
        } else {
          // The export prompt saves into Downloads; start there when it exists.
          let homeDirectory = try await api.browseDirectory("~")
          resolvedHome = homeDirectory.path
          directory = (try? await api.browseDirectory(homeDirectory.child("Downloads"))) ?? homeDirectory
        }
      } catch {
        directory = nil
      }
      loading = false
      navigationItem.rightBarButtonItem?.isEnabled = directory != nil
      if let directory { navigationItem.title = shown(directory.path) }
      tableView.reloadData()
    }
  }

  private var resolvedHome: String?

  /// "/Users/k/Downloads/sage-export" as "~/Downloads/sage-export".
  private func shown(_ path: String) -> String {
    guard let home = home ?? resolvedHome, path.hasPrefix(home), path != home else { return path }
    return "~" + path.dropFirst(home.count)
  }

  private func selectCurrent() {
    guard let directory else { return }
    onPick((directory.path, shown(directory.path), directory.itemCount))
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    directory?.folders.count ?? 0
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    if loading { return String(localized: "bots.import.loadingFolders", defaultValue: "Loading folders…") }
    return directory?.folders.isEmpty == true ? String(localized: "bots.import.noFolders", defaultValue: "No folders") : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.cell()
    content.text = directory?.folders[indexPath.row]
    content.image = Lucide.folder.image(size: 18)
    content.imageProperties.tintColor = Palette.textSecondary
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    guard let directory else { return }
    navigationController?.pushViewController(
      HostFolderPickerViewController(
        session: session, path: directory.child(directory.folders[indexPath.row]), home: home ?? resolvedHome, onPick: onPick),
      animated: true)
  }
}
