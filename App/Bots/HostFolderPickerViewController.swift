import OrcaCore
import UIKit

/// Import › Another app (bots/MobileBotImportExportSteps.tsx): for an old bot whose files Orca can't see.
/// The owner sends it this message, it saves a `<name>-export` folder in Downloads, and the new bot reads that.
enum BotImportExport {
  /// The message the owner pastes into the old bot (bot-import.ts BOT_IMPORT_EXPORT_PROMPT).
  static let prompt =
    "I'm moving to another assistant and need a complete copy of your setup. Don't change, pause or delete anything. If you keep your setup in files (persona or soul, memory, user notes, skills, routines), save copies of those files, unchanged, into a folder in my Downloads called <your name>-export, then list what you saved. Write out in full in your reply anything that isn't in a file. Never include passwords, API keys, tokens or cookies."
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
