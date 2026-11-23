import UIKit

/// Shown on first launch, and again from Settings › About: who makes this app (a community project, kept by
/// huami1314), how to get push notifications (a prompt to hand to an AI on the desktop), and that its license
/// and policies are Orca's.
final class WelcomeViewController: UIViewController {
  /// Seen once; Settings can open it again.
  static var seen: Bool {
    get { UserDefaults.standard.bool(forKey: "orca.welcome.seen") }
    set { UserDefaults.standard.set(newValue, forKey: "orca.welcome.seen") }
  }

  static let maintainerURL = URL(string: "https://github.com/huami1314")!
  static let repositoryURL = URL(string: "https://github.com/huami1314/orca-ios")!
  static let gatewayOrigin = "https://orca-push.huami.dev"

  /// What to send an AI on the desktop so Orca there pushes to this app.
  static var pushPrompt: String {
    String(
      format: String(
        localized: "orcaios.welcome.pushPrompt",
        defaultValue: """
          Please set up push notifications from my Orca desktop to the community iPhone app (orca-ios, bundle id com.thm.orcaios):
          1. Orca desktop picks its push gateway from the environment variable ORCA_PUSH_GATEWAY_URL. Set it to %1$@.
          2. macOS: run `launchctl setenv ORCA_PUSH_GATEWAY_URL %1$@`, and add a LaunchAgent in ~/Library/LaunchAgents that runs the same command at login so it survives a restart. Windows: set a user environment variable with that name and value. Linux: add it to the environment Orca starts with (for example ~/.config/environment.d/orca.conf).
          3. Quit Orca completely and open it again.
          4. Tell me when it's done. Note: after this, this computer no longer sends notifications to the official Orca app; removing the variable and restarting Orca undoes it.
          """), gatewayOrigin)
  }

  /// Called when the person taps Continue (first launch) or Done.
  var onFinish: (() -> Void)?

  private let scroll = UIScrollView()
  private let column = UIStackView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.alwaysBounceVertical = true
    view.addSubview(scroll)
    column.axis = .vertical
    column.spacing = Spacing.lg
    column.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(column)

    var start = UIButton.Configuration.prominentGlass()
    start.title = String(localized: "orcaios.welcome.continue", defaultValue: "Continue")
    start.baseBackgroundColor = Palette.textPrimary
    start.baseForegroundColor = Palette.bgBase
    start.cornerStyle = .capsule
    start.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .systemFont(ofSize: 16, weight: .semibold)
      return attributes
    }
    let continueButton = UIButton(configuration: start, primaryAction: UIAction { [weak self] _ in
      Haptics.select()
      WelcomeViewController.seen = true
      self?.onFinish?()
    })
    continueButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(continueButton)

    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.xl * 2),
      column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg + 4),
      column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg - 4),
      column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -110),
      continueButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg + 4),
      continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg - 4),
      continueButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.md),
      continueButton.heightAnchor.constraint(equalToConstant: 52),
    ])
    build()
  }

  private func build() {
    // Who makes it.
    let logo = OrcaLogoView(size: 34)
    let logoRow = UIStackView(arrangedSubviews: [logo, UIView()])
    column.addArrangedSubview(logoRow)
    column.setCustomSpacing(Spacing.md, after: logoRow)
    let title = TextLabel(
      String(localized: "orcaios.welcome.title", defaultValue: "Orca iOS"), size: 30, weight: .bold, lines: 0)
    column.addArrangedSubview(title)
    column.setCustomSpacing(Spacing.sm, after: title)
    let badge = Self.badge(String(localized: "orcaios.welcome.badge", defaultValue: "Community project"))
    column.addArrangedSubview(badge)
    column.addArrangedSubview(
      Self.paragraph(
        String(
          localized: "orcaios.welcome.about",
          defaultValue:
            "Native iPhone client for Orca. Community-made, not official.")))

    column.addArrangedSubview(
      card(
        heading: String(localized: "orcaios.welcome.maintainerHeading", defaultValue: "Maintainer"),
        rows: [
          link(
            image: Self.avatar, title: "huami1314",
            detail: String(localized: "orcaios.welcome.maintainerRole", defaultValue: "Creator and core maintainer"),
            url: Self.maintainerURL),
          link(
            image: Self.github, title: "huami1314/orca-ios",
            detail: String(localized: "orcaios.welcome.repository", defaultValue: "Source code, issues and contributions"),
            url: Self.repositoryURL),
        ]))

    // Notifications.
    let copy = UIButton(
      configuration: {
        var configuration = UIButton.Configuration.glass()
        configuration.title = String(localized: "orcaios.welcome.copyPrompt", defaultValue: "Copy prompt")
        configuration.image = UIImage(systemName: "doc.on.doc")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = Palette.textPrimary
        configuration.cornerStyle = .capsule
        return configuration
      }())
    copy.addAction(UIAction { [weak copy] _ in
      UIPasteboard.general.string = WelcomeViewController.pushPrompt
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      copy?.configuration?.title = String(localized: "orcaios.welcome.copied", defaultValue: "Copied")
      copy?.configuration?.image = UIImage(systemName: "checkmark")
    }, for: .primaryActionTriggered)
    let pushText = Self.paragraph(
      String(
        localized: "orcaios.welcome.push",
        defaultValue:
          "Orca's push only reaches the official app. Send this prompt to an AI on your computer to switch it to the community gateway."),
      size: 15)
    column.addArrangedSubview(
      card(
        heading: String(localized: "orcaios.welcome.pushHeading", defaultValue: "Push notifications"),
        views: [pushText, copy]))

    // License and policies.
    let legal = Self.paragraph(
      String(
        localized: "orcaios.welcome.legal",
        defaultValue:
          "License and privacy policy follow upstream Orca."),
      size: 15)
    column.addArrangedSubview(
      card(
        heading: String(localized: "orcaios.welcome.legalHeading", defaultValue: "License and policies"),
        views: [legal],
        rows: [
          link(
            icon: "doc.text", title: String(localized: "orcaios.welcome.license", defaultValue: "License (MIT)"), detail: nil,
            url: URL(string: "https://github.com/huami1314/orca-ios/blob/main/LICENSE")!),
          link(
            icon: "hand.raised", title: String(localized: "settings.menuScreen.privacyPolicy", defaultValue: "Privacy policy"),
            detail: "orca.dev/privacy", url: URL(string: "https://orca.dev/privacy")!),
        ]))
  }

  // MARK: Pieces

  /// huami1314's GitHub avatar, round, as large as the row icons.
  static let avatar: UIImage? = {
    guard let photo = UIImage(named: "MaintainerAvatar") else { return nil }
    let side: CGFloat = 26
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
      UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
      photo.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }.withRenderingMode(.alwaysOriginal)
  }()

  /// GitHub's own mark, centred in the same 26 pt square as the other rows' symbols.
  private static let github: UIImage = {
    let mark = BrandGlyph.github(size: 20)
    let box = CGSize(width: 26, height: 26)
    return UIGraphicsImageRenderer(size: box).image { _ in mark.draw(at: CGPoint(x: 3, y: 3)) }.withRenderingMode(.alwaysTemplate)
  }()

  /// A symbol centred in a 26 pt square, so the rows' words line up.
  private static func boxed(_ symbol: UIImage) -> UIImage {
    let glyph = symbol.withConfiguration(UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
    let box = CGSize(width: 26, height: 26)
    return UIGraphicsImageRenderer(size: box).image { _ in
      glyph.draw(at: CGPoint(x: (box.width - glyph.size.width) / 2, y: (box.height - glyph.size.height) / 2))
    }.withRenderingMode(.alwaysTemplate)
  }

  private static func paragraph(_ text: String, size: CGFloat = 16) -> TextLabel {
    TextLabel(text, size: size, color: Palette.textSecondary, lineHeight: size * 1.45, lines: 0)
  }

  private static func badge(_ text: String) -> UIView {
    let label = TextLabel(text, size: 13, weight: .semibold, color: Palette.accentBlue)
    let pill = UIView()
    pill.backgroundColor = Palette.accentBlue.withAlphaComponent(0.14)
    pill.layer.cornerRadius = 12
    pill.layer.cornerCurve = .continuous
    pill.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
      label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
      label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
    ])
    let row = UIStackView(arrangedSubviews: [pill, UIView()])
    return row
  }

  private func card(heading: String, views: [UIView] = [], rows: [UIView] = []) -> UIView {
    let header = TextLabel(heading, size: 13, weight: .semibold, color: Palette.textMuted)
    let stack = UIStackView(arrangedSubviews: views + rows)
    stack.axis = .vertical
    stack.spacing = Spacing.md
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    let card = UIView()
    card.backgroundColor = Palette.bgRaised
    card.layer.cornerRadius = Radius.surface
    card.layer.cornerCurve = .continuous
    card.addSubview(stack)
    stack.pin(to: card, insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
    let outer = UIStackView(arrangedSubviews: [header, card])
    outer.axis = .vertical
    outer.spacing = Spacing.sm
    return outer
  }

  private func link(icon: String, title: String, detail: String?, url: URL) -> UIView {
    link(image: UIImage(systemName: icon).map(Self.boxed), title: title, detail: detail, url: url)
  }

  private func link(image: UIImage?, title: String, detail: String?, url: URL) -> UIView {
    var configuration = UIButton.Configuration.plain()
    configuration.image = image
    configuration.imagePadding = 12
    configuration.title = title
    configuration.subtitle = detail
    configuration.baseForegroundColor = Palette.textPrimary
    configuration.contentInsets = .zero
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .systemFont(ofSize: 16, weight: .medium)
      return attributes
    }
    configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .systemFont(ofSize: 13)
      attributes.foregroundColor = Palette.textMuted
      return attributes
    }
    let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in UIApplication.shared.open(url) })
    button.contentHorizontalAlignment = .leading
    let chevron = UIImageView(image: UIImage(systemName: "arrow.up.right"))
    chevron.tintColor = Palette.textMuted
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [button, chevron])
    row.alignment = .center
    return row
  }
}
