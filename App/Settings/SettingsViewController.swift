import UIKit

/// Settings (app/settings.tsx): the official menu on a system grouped list.
final class SettingsViewController: UITableViewController {
  private struct Row {
    let icon: Lucide?
    let title: String
    var detail: String? = nil
    var opens: (() -> UIViewController)? = nil
    var action: (() -> Void)? = nil
  }

  private var sections: [[Row]] = []

  init() {
    super.init(style: .insetGrouped)
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "common.settings", defaultValue: "Settings")
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    sections = [
      [
        Row(
          icon: .sunMoon, title: String(localized: "settings.menuItems.appearance", defaultValue: "Appearance"),
          opens: { AppearanceViewController() }),
        Row(
          icon: .terminal, title: String(localized: "settings.menuItems.terminal", defaultValue: "Terminal"),
          opens: { TerminalSettingsViewController() }),
        Row(
          icon: .messageSquare, title: String(localized: "settings.menuItems.chatUi", defaultValue: "Chat UI"),
          opens: { ChatUISettingsViewController() }),
        Row(
          icon: .globe, title: String(localized: "settings.menuItems.browser", defaultValue: "Browser"),
          opens: { BrowserSettingsViewController() }),
        Row(
          icon: .mic, title: String(localized: "settings.menuItems.voice", defaultValue: "Voice"),
          opens: { VoiceSettingsViewController() }),
        Row(
          icon: .bell, title: String(localized: "settings.menuItems.notifications", defaultValue: "Notifications"),
          opens: { NotificationsViewController() }),
        Row(
          icon: .wrench, title: String(localized: "settings.menuItems.troubleshooting", defaultValue: "Troubleshooting"),
          opens: { TroubleshootingViewController() }),
        Row(
          icon: .info, title: String(localized: "settings.menuItems.about", defaultValue: "About"),
          opens: { AboutViewController() }),
      ],
      [
        Row(
          icon: nil,
          title: String(format: String(localized: "settings.appUpdateSettingsRows.installedVersion", defaultValue: "Version %1$@"), version))
      ],
      [
        Row(
          icon: .shield, title: String(localized: "settings.menuScreen.privacyPolicy", defaultValue: "Privacy policy"),
          action: { UIApplication.shared.open(URL(string: "https://orca.dev/privacy")!) }),
        Row(
          icon: .lifeBuoy, title: String(localized: "settings.menuScreen.support", defaultValue: "Support"),
          action: { UIApplication.shared.open(URL(string: "https://github.com/huami1314/orca-ios/issues")!) }),
      ],
    ]
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section][indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.valueCell()
    content.text = row.title
    content.textProperties.font = .systemFont(ofSize: 17)
    content.secondaryText = row.detail
    content.image = row.icon?.image(size: 22, strokeWidth: 1.8)
    content.imageProperties.tintColor = Palette.textSecondary
    content.imageToTextPadding = 16
    cell.contentConfiguration = content
    cell.backgroundColor = Palette.bgRaised
    cell.accessoryType = row.opens != nil || (row.action == nil && row.icon != nil) ? .disclosureIndicator : .none
    cell.selectionStyle = row.opens != nil || row.action != nil ? .default : .none
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    let row = sections[indexPath.section][indexPath.row]
    if let opens = row.opens {
      navigationController?.pushViewController(opens(), animated: true)
    } else {
      row.action?()
    }
  }
}
