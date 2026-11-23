import UIKit

/// Settings › About (settings/about-screen.tsx): the Orca mark and tagline, Orca's links, this app's source
/// and the open-source licenses it ships, and the installed version.
final class AboutViewController: SettingsPageViewController {
  private let versionLabel = UILabel()
  private let errorLabel = UILabel()
  private lazy var footer = makeFooter()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.aboutScreen.title", defaultValue: "About")
    tableView.tableHeaderView = brandHeader()
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?.?.?"
    let build = info?["CFBundleVersion"] as? String
    // app/about.tsx: `v1.2.3 (45)`, or `v1.2.3` without a build number.
    versionLabel.text = build.map { "v\(version) (\($0))" } ?? "v\(version)"
    let globe = Lucide.globe.image(size: 18).withRenderingMode(.alwaysTemplate)
    sections = [
      Section(rows: [
        link(globe, "orca.dev", String(localized: "settings.aboutScreen.website", defaultValue: "Orca website"), "https://orca.dev"),
        link(
          BrandGlyph.github, "stablyai/orca", String(localized: "settings.aboutScreen.sourceCode", defaultValue: "Orca source code"),
          "https://github.com/stablyai/orca"),
        link(BrandGlyph.x, "@orca_build", String(localized: "settings.aboutScreen.socialProfile", defaultValue: "Orca on X"), "https://x.com/orca_build"),
      ]),
      Section(
        footerView: footer,
        rows: [
          link(
            BrandGlyph.github, "huami1314/orca-ios", String(localized: "orcaios.about.thisApp", defaultValue: "This app’s source code"),
            "https://github.com/huami1314/orca-ios"),
          .value(
            icon: .scrollText, title: String(localized: "orcaios.about.licenses", defaultValue: "Open-source licenses"),
            navigates: true
          ) { [weak self] in self?.navigationController?.pushViewController(LicensesViewController(), animated: true) },
        ]),
    ]
  }

  private func link(_ image: UIImage, _ title: String, _ label: String, _ url: String) -> Row {
    .link(image: image, title: title, accessibilityLabel: label) { [weak self] in
      guard let url = URL(string: url) else { return }
      self?.showLinkError(false)
      UIApplication.shared.open(url) { opened in self?.showLinkError(!opened) }
    }
  }

  /// The official red line under the version, in place of an alert.
  private func showLinkError(_ shown: Bool) {
    guard errorLabel.isHidden == shown else { return }
    errorLabel.isHidden = !shown
    if shown { UIAccessibility.post(notification: .announcement, argument: errorLabel.text) }
    tableView.performBatchUpdates(nil)
  }

  private func makeFooter() -> UIView {
    for label in [versionLabel, errorLabel] {
      label.font = .systemFont(ofSize: Typography.metaSize)
      label.textAlignment = .center
      label.numberOfLines = 0
    }
    versionLabel.textColor = Palette.textMuted
    errorLabel.textColor = Palette.statusRed
    errorLabel.text = String(localized: "settings.aboutScreen.openLinkFailed", defaultValue: "Could not open the link. Try again.")
    errorLabel.isHidden = true
    let stack = UIStackView(arrangedSubviews: [versionLabel, errorLabel])
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    stack.translatesAutoresizingMaskIntoConstraints = false
    let view = UIView()
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Spacing.sm),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])
    return view
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

/// The GitHub and X marks the official About screen draws inline (about-screen.tsx), filled from the same
/// SVG paths in a 24×24 box and tinted like the row icons.
private enum BrandGlyph {
  static let github = image(
    "M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z"
  )
  static let x = image(
    "M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"
  )

  private static func image(_ d: String, size: CGFloat = 18) -> UIImage {
    let path = CGMutablePath()
    SVGPathParser.append(d, to: path)
    return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: .preferred()).image { context in
      let cg = context.cgContext
      cg.scaleBy(x: size / 24, y: size / 24)
      cg.addPath(path)
      cg.setFillColor(UIColor.black.cgColor)
      cg.fillPath()
    }.withRenderingMode(.alwaysTemplate)
  }
}
