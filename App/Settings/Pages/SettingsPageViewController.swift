import UIKit

/// A settings page on a system grouped list: sections of rows a subclass rebuilds whenever its values change.
class SettingsPageViewController: UITableViewController {
  struct Section {
    var header: String?
    var footer: String?
    /// A footer the page draws itself, in place of `footer`'s grey text.
    var footerView: UIView?
    var rows: [Row]

    init(header: String? = nil, footer: String? = nil, footerView: UIView? = nil, rows: [Row]) {
      self.header = header
      self.footer = footer
      self.footerView = footerView
      self.rows = rows
    }
  }

  struct Option {
    var title: String
    var subtitle: String? = nil
    var selected: Bool
    var enabled = true
    var action: () -> Void
  }

  enum Row {
    /// A title with a value; pushes or acts when `action` is set.
    case value(icon: Lucide? = nil, title: String, value: String? = nil, subtitle: String? = nil, navigates: Bool = false, enabled: Bool = true, action: (() -> Void)? = nil)
    /// A title whose value opens a menu of choices.
    case menu(icon: Lucide? = nil, title: String, value: String, options: [Option], enabled: Bool = true)
    case toggle(title: String, subtitle: String? = nil, isOn: Bool, enabled: Bool = true, onChange: (Bool) -> Void)
    /// A segmented control under its title.
    case segmented(title: String, items: [String], selected: Int, enabled: Bool = true, onChange: (Int) -> Void)
    /// A slider under its title, between a small and a large "A", with an optional −/+ stepper.
    case slider(title: String, value: String, range: ClosedRange<Double>, current: Double, stepper: Bool, onPreview: (Double) -> String, onCommit: (Double) -> Void)
    /// A choice with a checkmark.
    case check(title: String, subtitle: String? = nil, checked: Bool, enabled: Bool = true, action: () -> Void)
    case button(title: String, destructive: Bool = false, enabled: Bool = true, action: () -> Void)
    /// A status line: an icon in its colour, a title and a detail.
    case status(icon: Lucide, color: UIColor, title: String, detail: String?, detailColor: UIColor? = nil)
    /// An outside link: a leading glyph and a title, no chevron (the official ListRow with only `onPress`).
    case link(image: UIImage, title: String, accessibilityLabel: String? = nil, action: () -> Void)
    case spinner(String)
    /// A cell the page owns and keeps, such as a text field that must keep its focus across reloads.
    case custom(UITableViewCell)
  }

  var sections: [Section] = [] {
    didSet { if isViewLoaded { tableView.reloadData() } }
  }

  init() { super.init(style: .insetGrouped) }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.register(StackedControlCell.self, forCellReuseIdentifier: "stacked")
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].header }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

  override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { sections[section].footerView }

  override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { UITableView.automaticDimension }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section].rows[indexPath.row]
    switch row {
    case .segmented(let title, let items, let selected, let enabled, let onChange):
      let cell = tableView.dequeueReusableCell(withIdentifier: "stacked", for: indexPath) as! StackedControlCell
      cell.showSegments(title: title, items: items, selected: selected, enabled: enabled, onChange: onChange)
      return cell
    case .slider(let title, let value, let range, let current, let stepper, let onPreview, let onCommit):
      let cell = tableView.dequeueReusableCell(withIdentifier: "stacked", for: indexPath) as! StackedControlCell
      cell.showSlider(title: title, value: value, range: range, current: current, stepper: stepper, onPreview: onPreview, onCommit: onCommit)
      return cell
    case .custom(let cell):
      return cell
    default:
      break
    }
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgRaised
    cell.accessibilityTraits.remove(.selected)
    cell.accessoryType = .none
    cell.accessoryView = nil
    cell.selectionStyle = .none
    var content = UIListContentConfiguration.valueCell()
    content.textProperties.color = Palette.textPrimary
    content.secondaryTextProperties.color = Palette.textSecondary
    content.imageProperties.tintColor = Palette.textSecondary
    content.imageToTextPadding = 16
    // A disabled row fades as a whole (feedback.disabledOpacity), as the official ListRow does.
    var dimmed = false
    switch row {
    case .value(let icon, let title, let value, let subtitle, let navigates, let enabled, let action):
      if subtitle != nil { content = subtitleContent() }
      content.image = icon?.image(size: 20, strokeWidth: 1.8)
      content.text = title
      content.secondaryText = subtitle ?? value
      if subtitle != nil, let value { content.text = title; cell.accessoryView = valueLabel(value) }
      if navigates {
        // The system chevron sits outside the content and accessory views, so a faded row draws its own.
        if enabled { cell.accessoryType = .disclosureIndicator } else { cell.accessoryView = chevron() }
      }
      cell.selectionStyle = action != nil && enabled ? .default : .none
      dimmed = !enabled
    case .menu(let icon, let title, let value, let options, let enabled):
      content.image = icon?.image(size: 20, strokeWidth: 1.8)
      content.text = title
      cell.accessoryView = menuButton(value: value, options: options, enabled: enabled)
      dimmed = !enabled
    case .link(let image, let title, let label, _):
      content.image = image
      content.text = title
      cell.selectionStyle = .default
      cell.accessibilityLabel = label
    case .toggle(let title, let subtitle, let isOn, let enabled, let onChange):
      if subtitle != nil { content = subtitleContent() }
      content.text = title
      content.secondaryText = subtitle
      let toggle = UISwitch()
      toggle.isOn = isOn
      toggle.isEnabled = enabled
      toggle.accessibilityLabel = title
      toggle.addAction(UIAction { [weak toggle] _ in onChange(toggle?.isOn ?? false) }, for: .valueChanged)
      cell.accessoryView = toggle
      dimmed = !enabled
    case .check(let title, let subtitle, let checked, let enabled, _):
      if subtitle != nil { content = subtitleContent() }
      content.text = title
      content.secondaryText = subtitle
      // The official radio row's tick: Lucide Check in the text colour, not the system's blue checkmark.
      if checked {
        let tick = UIImageView(image: Lucide.check.image(size: 17, strokeWidth: 2.4).withRenderingMode(.alwaysTemplate))
        tick.tintColor = Palette.textPrimary
        cell.accessoryView = tick
      }
      // The system checkmark said "selected" on its own; a drawn tick has to say it.
      if checked { cell.accessibilityTraits.insert(.selected) }
      cell.selectionStyle = enabled ? .default : .none
      dimmed = !enabled
    case .button(let title, let destructive, let enabled, _):
      content = .cell()
      content.text = title
      content.textProperties.color =
        !enabled ? Palette.textMuted : destructive ? Palette.statusRed : Palette.accentBlue
      cell.selectionStyle = enabled ? .default : .none
    case .status(let icon, let color, let title, let detail, let detailColor):
      content = subtitleContent()
      content.image = icon.image(size: 18, strokeWidth: 2)
      content.imageProperties.tintColor = color
      content.text = title
      content.secondaryText = detail
      content.secondaryTextProperties.color = detailColor ?? Palette.textSecondary
    case .spinner(let title):
      content.text = title
      content.textProperties.color = Palette.textSecondary
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      cell.accessoryView = spinner
    case .segmented, .slider, .custom:
      break
    }
    if case .link = row {} else { cell.accessibilityLabel = nil }
    cell.contentConfiguration = content
    cell.contentView.alpha = dimmed ? Feedback.disabledOpacity : 1
    cell.accessoryView?.alpha = dimmed ? Feedback.disabledOpacity : 1
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section].rows[indexPath.row] {
    case .value(_, _, _, _, _, let enabled, let action) where enabled:
      action?()
    case .check(_, _, let checked, let enabled, let action) where enabled:
      // Picking a new option ticks; re-tapping the picked one doesn't.
      if !checked { UISelectionFeedbackGenerator().selectionChanged() }
      action()
    case .button(_, _, let enabled, let action) where enabled:
      action()
    case .link(_, _, _, let action):
      action()
    default:
      break
    }
  }

  override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    switch sections[indexPath.section].rows[indexPath.row] {
    case .value(_, _, _, _, _, let enabled, let action): enabled && action != nil
    case .check(_, _, _, let enabled, _), .button(_, _, let enabled, _): enabled
    case .link: true
    default: false
    }
  }

  /// An error or result shown in an alert with one OK button.
  func showAlert(title: String, message: String?) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  private func subtitleContent() -> UIListContentConfiguration {
    var content = UIListContentConfiguration.subtitleCell()
    content.textProperties.color = Palette.textPrimary
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
    content.textToSecondaryTextVerticalPadding = 3
    content.imageToTextPadding = 16
    return content
  }

  private func chevron() -> UIImageView {
    let view = UIImageView(
      image: UIImage(systemName: "chevron.forward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    view.tintColor = .tertiaryLabel
    return view
  }

  private func valueLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = Palette.textSecondary
    label.sizeToFit()
    return label
  }

  private func menuButton(value: String, options: [Option], enabled: Bool) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.title = value
    configuration.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.baseForegroundColor = Palette.textSecondary
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 0)
    let button = UIButton(configuration: configuration)
    button.isEnabled = enabled
    button.showsMenuAsPrimaryAction = true
    button.menu = UIMenu(
      options: .singleSelection,
      children: options.map { option in
        let action = UIAction(title: option.title, subtitle: option.subtitle, state: option.selected ? .on : .off) { _ in
          option.action()
        }
        if !option.enabled { action.attributes = .disabled }
        return action
      })
    button.sizeToFit()
    return button
  }
}

/// A row whose control sits under its title (the official StackedRow): a segmented control or a size slider.
final class StackedControlCell: UITableViewCell {
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let segments = UISegmentedControl()
  private let slider = UISlider()
  private let sliderRow = UIStackView()
  private let stepper = UISegmentedControl()
  private var onSegment: ((Int) -> Void)?
  private var onPreview: ((Double) -> String)?
  private var onCommit: ((Double) -> Void)?
  private var lastStep: Double = 0
  private var range: ClosedRange<Double> = 0...1

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = Palette.bgRaised
    selectionStyle = .none
    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.textColor = Palette.textPrimary
    valueLabel.font = .preferredFont(forTextStyle: .body)
    valueLabel.textColor = Palette.textSecondary
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    let header = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
    header.spacing = Spacing.md

    let small = UILabel()
    small.text = "A"
    small.font = .systemFont(ofSize: 12)
    small.textColor = Palette.textSecondary
    let large = UILabel()
    large.text = "A"
    large.font = .systemFont(ofSize: 20)
    large.textColor = Palette.textSecondary
    for label in [small, large] {
      label.isAccessibilityElement = false
      label.setContentHuggingPriority(.required, for: .horizontal)
    }
    stepper.insertSegment(with: Lucide.minus.image(size: 16, strokeWidth: 2.2), at: 0, animated: false)
    stepper.insertSegment(with: Lucide.plus.image(size: 16, strokeWidth: 2.2), at: 1, animated: false)
    stepper.isMomentary = true
    stepper.setContentHuggingPriority(.required, for: .horizontal)
    stepper.widthAnchor.constraint(equalToConstant: 88).isActive = true
    stepper.addAction(UIAction { [weak self] _ in self?.step() }, for: .valueChanged)
    for view in [small, slider, large, stepper] as [UIView] { sliderRow.addArrangedSubview(view) }
    sliderRow.spacing = Spacing.sm
    sliderRow.alignment = .center
    sliderRow.setCustomSpacing(Spacing.md, after: large)

    slider.addAction(UIAction { [weak self] _ in self?.sliderMoved() }, for: .valueChanged)
    slider.addAction(UIAction { [weak self] _ in self?.sliderEnded() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    segments.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        self.onSegment?(self.segments.selectedSegmentIndex)
      }, for: .valueChanged)

    let stack = UIStackView(arrangedSubviews: [header, segments, sliderRow])
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.md),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func showSegments(title: String, items: [String], selected: Int, enabled: Bool, onChange: @escaping (Int) -> Void) {
    titleLabel.text = title
    titleLabel.textColor = Palette.textPrimary
    contentView.alpha = enabled ? 1 : Feedback.disabledOpacity
    valueLabel.isHidden = true
    sliderRow.isHidden = true
    segments.isHidden = false
    segments.removeAllSegments()
    for (index, item) in items.enumerated() { segments.insertSegment(withTitle: item, at: index, animated: false) }
    segments.selectedSegmentIndex = selected
    segments.isEnabled = enabled
    segments.accessibilityLabel = title
    onSegment = onChange
    onPreview = nil
    onCommit = nil
  }

  func showSlider(
    title: String, value: String, range: ClosedRange<Double>, current: Double, stepper showsStepper: Bool,
    onPreview: @escaping (Double) -> String, onCommit: @escaping (Double) -> Void
  ) {
    titleLabel.text = title
    titleLabel.textColor = Palette.textPrimary
    contentView.alpha = 1
    valueLabel.isHidden = false
    valueLabel.text = value
    segments.isHidden = true
    sliderRow.isHidden = false
    stepper.isHidden = !showsStepper
    self.range = range
    slider.minimumValue = Float(range.lowerBound)
    slider.maximumValue = Float(range.upperBound)
    slider.value = Float(current)
    slider.accessibilityLabel = title
    slider.accessibilityValue = value
    lastStep = current
    updateStepper()
    self.onPreview = onPreview
    self.onCommit = onCommit
    onSegment = nil
  }

  private func sliderMoved() {
    let stepped = Double(slider.value).rounded()
    guard stepped != lastStep else { return }
    lastStep = stepped
    UISelectionFeedbackGenerator().selectionChanged()
    valueLabel.text = onPreview?(stepped)
    slider.accessibilityValue = valueLabel.text
    updateStepper()
  }

  private func sliderEnded() {
    let stepped = Double(slider.value).rounded()
    slider.value = Float(stepped)
    onCommit?(stepped)
  }

  private func step() {
    let next = lastStep + (stepper.selectedSegmentIndex == 0 ? -1 : 1)
    guard range.contains(next) else { return }
    lastStep = next
    slider.setValue(Float(next), animated: true)
    valueLabel.text = onPreview?(next)
    updateStepper()
    onCommit?(next)
  }

  private func updateStepper() {
    stepper.setEnabled(lastStep > range.lowerBound, forSegmentAt: 0)
    stepper.setEnabled(lastStep < range.upperBound, forSegmentAt: 1)
    stepper.setAccessibilityLabelsForSegments()
  }
}

private extension UISegmentedControl {
  func setAccessibilityLabelsForSegments() {
    guard numberOfSegments == 2 else { return }
    imageForSegment(at: 0)?.accessibilityLabel = String(localized: "app.terminalSettings.smaller", defaultValue: "Smaller")
    imageForSegment(at: 1)?.accessibilityLabel = String(localized: "app.terminalSettings.larger", defaultValue: "Larger")
  }
}
