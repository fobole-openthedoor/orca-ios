import UIKit

/// A panel of numbered steps with hairlines between them (components/list/NumberedStepsPanel.tsx).
final class NumberedStepsPanel: UIView {
  struct Step {
    let title: String
    let detail: String
  }

  private static let numberSize: CGFloat = 26

  init(steps: [Step]) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Palette.bgPanel
    layer.cornerRadius = Radius.surface
    clipsToBounds = true
    let column = UIStackView()
    column.axis = .vertical
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    column.pin(to: self)
    for (index, step) in steps.enumerated() {
      if index > 0 {
        let line = Hairline()
        let holder = UIView()
        holder.addSubview(line)
        NSLayoutConstraint.activate([
          line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Spacing.lg + Self.numberSize + 14),
          line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
          line.topAnchor.constraint(equalTo: holder.topAnchor),
          line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        column.addArrangedSubview(holder)
      }
      column.addArrangedSubview(row(number: index + 1, step: step))
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func row(number: Int, step: Step) -> UIView {
    let row = UIView()
    let disc = UIView()
    disc.translatesAutoresizingMaskIntoConstraints = false
    disc.backgroundColor = Palette.bgRaised
    disc.layer.cornerRadius = Self.numberSize / 2
    let digit = TextLabel("\(number)", size: 14, weight: .semibold, alignment: .center, tabular: true)
    disc.addSubview(digit)
    let title = TextLabel(step.title, size: 17, lineHeight: 22, lines: 0)
    let detail = TextLabel(step.detail, size: 15, color: Palette.textSecondary, lineHeight: 20, lines: 0)
    row.addSubview(disc)
    row.addSubview(title)
    row.addSubview(detail)
    NSLayoutConstraint.activate([
      disc.widthAnchor.constraint(equalToConstant: Self.numberSize),
      disc.heightAnchor.constraint(equalToConstant: Self.numberSize),
      disc.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Spacing.lg),
      disc.topAnchor.constraint(equalTo: row.topAnchor, constant: Spacing.lg),
      digit.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
      digit.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
      title.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 14),
      title.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Spacing.lg),
      title.topAnchor.constraint(equalTo: row.topAnchor, constant: Spacing.lg),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      detail.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Spacing.lg),
    ])
    return row
  }
}

/// Feed with no paired desktop (home/MobileHomeEmptyState.tsx): logo, title, body, three steps and Pair desktop.
final class HomeEmptyStateView: UIScrollView {
  var onPairDesktop: (() -> Void)?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    alwaysBounceVertical = true
    let content = UIView()
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    let guide = UIView()
    guide.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(guide)

    let logo = OrcaLogoView(size: 44)
    let title = TextLabel(
      String(localized: "home.emptyState.title", defaultValue: "Connect your desktop"), size: 28, weight: .bold,
      letterSpacing: -0.4, alignment: .center, lines: 0)
    title.accessibilityTraits = .header
    let body = TextLabel(
      String(
        localized: "home.emptyState.description",
        defaultValue:
          "Pair with Orca on your computer to check on your agents, jump into any terminal, and drive work from your phone."
      ), size: 17, color: Palette.textSecondary, lineHeight: 24, alignment: .center, lines: 0)
    let steps = NumberedStepsPanel(steps: [
      .init(
        title: String(localized: "home.emptyState.openDesktopTitle", defaultValue: "Open Orca desktop"),
        detail: String(
          localized: "home.emptyState.openDesktopDescription",
          defaultValue: "Go to Settings → Mobile and generate a pairing QR code.")),
      .init(
        title: String(localized: "home.emptyState.scanCodeTitle", defaultValue: "Scan the code"),
        detail: String(
          localized: "home.emptyState.scanCodeBelowDescription",
          defaultValue: "Tap Pair desktop below, then point your camera at the QR code on your screen.")),
      .init(
        title: String(localized: "home.emptyState.connectedTitle", defaultValue: "You're connected"),
        detail: String(
          localized: "home.emptyState.connectedDescription",
          defaultValue: "Your desktop will appear here. Everything is encrypted end-to-end.")),
    ])
    let button = PairDesktopButton()
    button.addAction(UIAction { [weak self] _ in self?.onPairDesktop?() }, for: .primaryActionTriggered)

    for view in [logo, title, body, steps, button] as [UIView] { guide.addSubview(view) }
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
      content.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
      // flexGrow: the guide centres in whatever height the screen leaves.
      // Centre in what the navigation and tab bars leave visible.
      content.heightAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.heightAnchor),

      guide.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Spacing.lg),
      guide.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Spacing.lg),
      guide.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      guide.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Spacing.lg),
      guide.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Spacing.lg),

      logo.topAnchor.constraint(equalTo: guide.topAnchor),
      logo.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      title.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 26),
      title.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Spacing.sm),
      title.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Spacing.sm),
      body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
      body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      steps.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 34),
      steps.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      steps.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      button.topAnchor.constraint(equalTo: steps.bottomAnchor, constant: 22),
      button.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      button.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// "Pair desktop": the official accent button as a prominent glass button.
final class PairDesktopButton: UIButton {
  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    var configuration = UIButton.Configuration.prominentGlass()
    configuration.title = String(localized: "home.emptyState.pairDesktopButton", defaultValue: "Pair desktop")
    configuration.image = Lucide.qrCode.image(size: 18, strokeWidth: 2.2)
    configuration.imagePadding = Spacing.sm
    configuration.baseBackgroundColor = Palette.accentBlue
    configuration.baseForegroundColor = Palette.onAccent
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 22)
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .systemFont(ofSize: 16, weight: .semibold)
      return attributes
    }
    self.configuration = configuration
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
