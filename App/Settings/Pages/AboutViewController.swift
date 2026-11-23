import UIKit

/// Settings › About (settings/about-screen.tsx): the Orca mark and tagline, Orca's links, this app's source
/// and the open-source licenses it ships, and the installed version.
final class AboutViewController: SettingsPageViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.aboutScreen.title", defaultValue: "About")
    tableView.tableHeaderView = brandHeader()
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "–"
    let build = info?["CFBundleVersion"] as? String
    let versionLabel = String(
      format: String(localized: "settings.appUpdateSettingsRows.installedVersion", defaultValue: "Version %1$@"),
      build.map { "\(version) (\($0))" } ?? version)
    sections = [
      Section(rows: [
        link(.globe, "orca.dev", "https://orca.dev"),
        link(.folderGit2, "stablyai/orca", "https://github.com/stablyai/orca"),
        link(.atSign, "@orca_build", "https://x.com/orca_build"),
      ]),
      Section(
        footer: versionLabel,
        rows: [
          link(.smartphone, "huami1314/orca-ios", "https://github.com/huami1314/orca-ios"),
          .value(
            icon: .scrollText, title: String(localized: "orcaios.about.licenses", defaultValue: "Open-source licenses"),
            navigates: true
          ) { [weak self] in self?.navigationController?.pushViewController(LicensesViewController(), animated: true) },
        ]),
    ]
  }

  private func link(_ icon: Lucide, _ title: String, _ url: String) -> Row {
    .value(icon: icon, title: title) { [weak self] in
      guard let url = URL(string: url) else { return }
      UIApplication.shared.open(url) { opened in
        guard !opened else { return }
        self?.showAlert(
          title: String(localized: "settings.aboutScreen.openLinkFailed", defaultValue: "Could not open the link. Try again."),
          message: nil)
      }
    }
  }

  private func brandHeader() -> UIView {
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 132))
    let logo = OrcaLogoView(size: 28)
    let name = UILabel()
    name.text = "Orca"
    name.font = .systemFont(ofSize: 22, weight: .heavy)
    name.textColor = Palette.textPrimary
    let tagline = UILabel()
    tagline.text = String(localized: "settings.aboutScreen.tagline", defaultValue: "Open-source agent IDE for 100x builders")
    tagline.font = .systemFont(ofSize: 13)
    tagline.textColor = Palette.textMuted
    tagline.textAlignment = .center
    tagline.numberOfLines = 0
    let stack = UIStackView(arrangedSubviews: [logo, name, tagline])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = Spacing.xs
    stack.setCustomSpacing(Spacing.sm, after: logo)
    stack.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: header.layoutMarginsGuide.leadingAnchor),
    ])
    return header
  }
}

/// The open-source work this app is built from, each linking to its license.
private final class LicensesViewController: SettingsPageViewController {
  private static let entries: [(name: String, license: String, url: String)] = [
    ("Orca", "MIT", "https://github.com/stablyai/orca/blob/main/LICENSE"),
    ("Ghostty", "MIT", "https://github.com/ghostty-org/ghostty/blob/main/LICENSE"),
    ("libghostty-spm", "MIT", "https://github.com/Lakr233/libghostty-spm"),
    ("Lucide", "ISC", "https://github.com/lucide-icons/lucide/blob/main/LICENSE"),
  ]

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "orcaios.about.licenses", defaultValue: "Open-source licenses")
    sections = [
      Section(
        rows: Self.entries.map { entry in
          .value(title: entry.name, value: entry.license) {
            if let url = URL(string: entry.url) { UIApplication.shared.open(url) }
          }
        })
    ]
  }
}
