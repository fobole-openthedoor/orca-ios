import UIKit

/// A rounded group of rows with inset hairlines between them (components/list/ListGroup.tsx), for the
/// stack-built PR screens.
final class ListGroupView: UIView {
  private let stack = UIStackView()
  /// Where a separator starts: past the leading glyph when the rows have one.
  var separatorInset: CGFloat = Spacing.lg

  init(rows: [UIView] = [], separatorInset: CGFloat = Spacing.lg) {
    self.separatorInset = separatorInset
    super.init(frame: .zero)
    backgroundColor = Palette.sheetGroup
    layer.cornerRadius = Radius.surface
    layer.cornerCurve = .continuous
    clipsToBounds = true
    stack.axis = .vertical
    addSubview(stack)
    stack.pin(to: self)
    rows.forEach(add)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func add(_ row: UIView) {
    if !stack.arrangedSubviews.isEmpty {
      let line = Hairline()
      let holder = UIView()
      holder.addSubview(line)
      NSLayoutConstraint.activate([
        line.topAnchor.constraint(equalTo: holder.topAnchor),
        line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: separatorInset),
        line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
      ])
      stack.addArrangedSubview(holder)
    }
    stack.addArrangedSubview(row)
  }
}

/// One list row (ListRow): a 20 pt glyph in a 24 pt slot, a 15 pt title over a 13 pt subtitle, then a value,
/// an accessory or a chevron when it navigates. 48 pt tall, 60 with a subtitle.
final class ListRowView: PressableControl {
  static let leadingInset: CGFloat = Spacing.lg + 24 + Spacing.md

  let titleLabel = TextLabel(size: 15, lines: 0)
  let subtitleLabel = TextLabel(size: 13, color: Palette.textSecondary, lines: 2)
  private let row = UIStackView()

  init(
    title: String, subtitle: String? = nil, leading: UIView? = nil, value: String? = nil, accessory: UIView? = nil,
    navigates: Bool = false, titleColor: UIColor = Palette.textPrimary, onPress: (() -> Void)? = nil
  ) {
    super.init(frame: .zero)
    self.onPress = onPress
    isUserInteractionEnabled = onPress != nil || accessory is UIControl
    titleLabel.text = title
    titleLabel.textColor = titleColor
    titleLabel.font = Typography.font(15, subtitle == nil ? .regular : .medium)
    subtitleLabel.text = subtitle
    subtitleLabel.isHidden = subtitle == nil
    let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    text.axis = .vertical
    text.spacing = 2
    text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if let leading {
      let slot = UIView()
      slot.translatesAutoresizingMaskIntoConstraints = false
      slot.addSubview(leading)
      leading.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        slot.widthAnchor.constraint(equalToConstant: 24),
        leading.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
        leading.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        slot.heightAnchor.constraint(equalTo: leading.heightAnchor),
      ])
      row.addArrangedSubview(slot)
    }
    row.addArrangedSubview(text)
    if let value {
      let label = TextLabel(value, size: 15, color: Palette.textSecondary, alignment: .right)
      label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      label.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
      row.addArrangedSubview(label)
    }
    if let accessory { row.addArrangedSubview(accessory) }
    if navigates { row.addArrangedSubview(LucideView(.chevronRight, size: 16, strokeWidth: 2.2, color: Palette.textMuted)) }
    row.spacing = Spacing.md
    row.alignment = .center
    row.isUserInteractionEnabled = accessory is UIControl
    row.isLayoutMarginsRelativeArrangement = true
    row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg)
    addSubview(row)
    row.pin(to: self)
    heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 48 : 60).isActive = true
    onPressedChange = { [weak self] pressed in
      self?.backgroundColor = pressed ? Palette.translucentFill : .clear
    }
    accessibilityTraits = onPress == nil ? .staticText : .button
    isAccessibilityElement = !(accessory is UIControl)
    accessibilityLabel = [title, subtitle, value].compactMap { $0 }.joined(separator: ", ")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A section's 13 pt label above a group, with an optional trailing text action (SectionHeader).
final class SectionLabelView: UIView {
  init(_ title: String, action: (title: String, handler: () -> Void)? = nil) {
    super.init(frame: .zero)
    let label = TextLabel(title, size: 13, weight: .medium, color: Palette.textSecondary)
    let row = UIStackView(arrangedSubviews: [label, UIView()])
    row.alignment = .center
    if let action {
      var configuration = UIButton.Configuration.plain()
      configuration.contentInsets = .zero
      configuration.attributedTitle = AttributedString(
        action.title,
        attributes: AttributeContainer([.font: Typography.font(13, .semibold), .foregroundColor: Palette.textPrimary]))
      row.addArrangedSubview(UIButton(configuration: configuration, primaryAction: UIAction { _ in action.handler() }))
    }
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.heightAnchor.constraint(equalToConstant: 24),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The PR's state as a pill with its icon: Open, Draft, Merged, Closed (prStateBadge).
enum PullRequestBadge {
  static func color(_ state: String) -> UIColor {
    switch state {
    case "merged": Palette.statusPurple
    case "closed": Palette.statusRed
    case "draft": Palette.textSecondary
    default: Palette.statusGreen
    }
  }

  static func icon(_ state: String) -> Lucide {
    switch state {
    case "merged": .gitMerge
    case "closed": .gitPullRequestClosed
    case "draft": .gitPullRequestDraft
    default: .gitPullRequest
    }
  }

  static func label(_ state: String) -> String {
    switch state {
    case "merged": String(localized: "pullRequest.prChecksPresentation.stateMerged", defaultValue: "Merged")
    case "closed": String(localized: "pullRequest.prChecksPresentation.stateClosed", defaultValue: "Closed")
    case "draft": String(localized: "pullRequest.prChecksPresentation.stateDraft", defaultValue: "Draft")
    default: String(localized: "pullRequest.prChecksPresentation.stateOpen", defaultValue: "Open")
    }
  }

  static func view(_ state: String) -> UIView {
    let color = color(state)
    let row = UIStackView(arrangedSubviews: [
      LucideView(icon(state), size: 12, strokeWidth: 2.2, color: color),
      TextLabel(label(state), size: Typography.metaSize, weight: .semibold, color: color),
    ])
    row.spacing = 4
    row.alignment = .center
    row.isLayoutMarginsRelativeArrangement = true
    row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 1, leading: Spacing.sm, bottom: 1, trailing: Spacing.sm)
    row.layer.cornerRadius = 10
    row.layer.borderWidth = 1 / UIScreen.main.scale
    row.layer.borderColor = color.cgColor
    row.setContentHuggingPriority(.required, for: .horizontal)
    row.setContentCompressionResistancePriority(.required, for: .horizontal)
    return row
  }
}

/// How long ago, as the PR tab and comment rows say it (pr-comment-relative-time.ts).
enum PRRelativeTime {
  static func string(_ iso: String?, now: Date = Date()) -> String? {
    guard let iso, !iso.isEmpty else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
    return string(date: date, now: now)
  }

  static func string(date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return now.timeIntervalSince(date) < 60
      ? String(localized: "sourceControl.gitHistory.justNow", defaultValue: "just now")
      : formatter.localizedString(for: date, relativeTo: now)
  }
}
