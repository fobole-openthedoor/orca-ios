import OrcaCore
import UIKit

/// New bot › Import from another app (bots/MobileBotImportSheet.tsx): the bots other apps keep on this
/// desktop. The new bot reads the old one's files itself in its first turn; keys and logins stay behind.
final class BotImportViewController: UITableViewController {
  private let session: HostSession
  /// The picked bot's name and the create's `importFrom`.
  private let onPick: (String, [String: JSONValue]) -> Void
  private var sources: [BotImportSource] = []
  private var loading = true

  init(session: HostSession, onPick: @escaping (String, [String: JSONValue]) -> Void) {
    self.session = session
    self.onPick = onPick
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.import.title", defaultValue: "Import from another app")
    navigationItem.largeTitleDisplayMode = .never
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    let api = session.api
    Task {
      sources = ((try? await api.botImportSources()) ?? []).filter { !$0.bots.isEmpty }
      loading = false
      tableView.reloadData()
    }
  }

  private var found: Int { sources.reduce(0) { $0 + $1.bots.count } }

  // The found apps' bots, then Another app… for one Orca can't see.
  private var foundSections: Int { max(1, sources.count) }

  override func numberOfSections(in tableView: UITableView) -> Int { foundSections + 1 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if section == foundSections { return loading ? 0 : 1 }
    return sources.isEmpty ? 0 : sources[section].bots.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    if loading {
      return String(format: String(localized: "bots.import.lookingOn", defaultValue: "Looking on %@…"), session.name)
    }
    guard section == 0, found > 0 else { return nil }
    return String(format: String(localized: "bots.import.foundOn", defaultValue: "%1$lld found on %2$@"), found, session.name)
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    if section == foundSections {
      return loading ? nil : String(localized: "bots.import.otherAppNote", defaultValue: "Your old bot copies its files for you")
    }
    guard section == foundSections - 1, !loading else { return nil }
    return [
      String(localized: "bots.import.description", defaultValue: "Your new bot reads the old one and sets itself up."),
      String(localized: "bots.import.keysStay", defaultValue: "Keys and logins stay behind"),
    ].joined(separator: "\n")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section == foundSections {
      let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
      var content = UIListContentConfiguration.cell()
      content.text = String(localized: "bots.import.otherApp", defaultValue: "Another app…")
      content.image = Lucide.folderPlus.image(size: 18)
      content.imageProperties.tintColor = Palette.textSecondary
      cell.contentConfiguration = content
      cell.accessoryType = .disclosureIndicator
      return cell
    }
    let source = sources[indexPath.section]
    let bot = source.bots[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = bot.name
    let app = BotImportSource.appNames[source.app] ?? source.app
    var detail = "\(app) · \(bot.path)"
    if let earlier = bot.importedAs {
      detail += " · " + String(format: String(localized: "bots.import.importedAs", defaultValue: "imported before as %@"), earlier)
    }
    content.secondaryText = detail
    content.secondaryTextProperties.color = Palette.textSecondary
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == foundSections {
      navigationController?.pushViewController(BotImportExportViewController(session: session, onPick: onPick), animated: true)
      return
    }
    let source = sources[indexPath.section]
    let bot = source.bots[indexPath.row]
    onPick(
      bot.name,
      ["app": .string(source.app), "path": .string(bot.absolutePath), "agent": .string(bot.agent), "name": .string(bot.name)])
    navigationController?.popViewController(animated: true)
  }
}
