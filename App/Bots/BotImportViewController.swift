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

  override func numberOfSections(in tableView: UITableView) -> Int { max(1, sources.count) }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sources.isEmpty ? 0 : sources[section].bots.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    if loading {
      return String(format: String(localized: "bots.import.lookingOn", defaultValue: "Looking on %@…"), session.name)
    }
    guard section == 0, found > 0 else { return nil }
    return String(format: String(localized: "bots.import.foundOn", defaultValue: "%1$lld found on %2$@"), found, session.name)
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    guard section == max(1, sources.count) - 1, !loading else { return nil }
    return [
      String(localized: "bots.import.description", defaultValue: "Your new bot reads the old one and sets itself up."),
      String(localized: "bots.import.keysStay", defaultValue: "Keys and logins stay behind"),
    ].joined(separator: "\n")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
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
    let source = sources[indexPath.section]
    let bot = source.bots[indexPath.row]
    onPick(
      bot.name,
      ["app": .string(source.app), "path": .string(bot.absolutePath), "agent": .string(bot.agent), "name": .string(bot.name)])
    navigationController?.popViewController(animated: true)
  }
}
