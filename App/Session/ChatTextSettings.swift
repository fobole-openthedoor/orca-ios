import UIKit

/// The chat's text settings, kept on this phone (native-chat-text-settings.ts): size in points (14 is the
/// chat's original scale), font and line spacing. Session ⋯ › Text size and Settings › Chat UI both edit it.
struct ChatTextSettings: Codable, Equatable {
  enum Font: String, Codable, CaseIterable { case system, serif, mono }
  enum Spacing: String, Codable, CaseIterable { case compact, `default`, relaxed }

  static let minSize = 11
  static let maxSize = 24
  static let defaultSize = 14
  static let changed = Notification.Name("orca.chatTextChanged")

  var size = ChatTextSettings.defaultSize
  var font = Font.system
  var lineSpacing = Spacing.default

  private static let key = "orca.chatText"

  static var current: ChatTextSettings {
    get {
      guard let data = UserDefaults.standard.data(forKey: key),
        let value = try? JSONDecoder().decode(ChatTextSettings.self, from: data)
      else { return ChatTextSettings() }
      return value
    }
    set {
      var value = newValue
      value.size = min(maxSize, max(minSize, value.size))
      UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
      NotificationCenter.default.post(name: changed, object: nil)
    }
  }

  /// How much bigger than the original 14 pt everything in the chat draws.
  var factor: CGFloat { CGFloat(size) / CGFloat(Self.defaultSize) }

  var lineFactor: CGFloat {
    switch lineSpacing {
    case .compact: 0.9
    case .default: 1
    case .relaxed: 1.15
    }
  }

  func bodyFont(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
    switch font {
    case .system: return .systemFont(ofSize: size, weight: weight)
    case .mono: return .monospacedSystemFont(ofSize: size, weight: weight)
    case .serif:
      let base = UIFont.systemFont(ofSize: size, weight: weight)
      return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
    }
  }

  var sizeLabel: String {
    size == Self.defaultSize
      ? String(localized: "settings.nativeChatText.sizeDefault", defaultValue: "Default")
      : String(format: String(localized: "settings.nativeChatText.sizePoints", defaultValue: "%@ pt"), "\(size)")
  }

  static func fontName(_ font: Font) -> String {
    switch font {
    case .system: String(localized: "settings.nativeChatText.fontSystem", defaultValue: "System")
    case .serif: String(localized: "settings.nativeChatText.fontSerif", defaultValue: "Serif")
    case .mono: String(localized: "settings.nativeChatText.fontMono", defaultValue: "Mono")
    }
  }

  static func spacingName(_ spacing: Spacing) -> String {
    switch spacing {
    case .compact: String(localized: "settings.nativeChatText.spacingCompact", defaultValue: "Compact")
    case .default: String(localized: "settings.nativeChatText.spacingDefault", defaultValue: "Default")
    case .relaxed: String(localized: "settings.nativeChatText.spacingRelaxed", defaultValue: "Relaxed")
    }
  }
}

/// Session ⋯ › Text size: a small sheet with the size stepped by one point, the font and the spacing,
/// applied to the chat as they change.
final class ChatTextSettingsController: UITableViewController {
  init() { super.init(style: .insetGrouped) }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func sheet() -> UIViewController {
    let navigation = UINavigationController(rootViewController: ChatTextSettingsController())
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.nativeChatText.size", defaultValue: "Text size")
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    tableView.backgroundColor = .clear
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 3 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0: String(localized: "settings.nativeChatText.size", defaultValue: "Text size")
    case 1: String(localized: "settings.nativeChatText.font", defaultValue: "Font")
    default: String(localized: "settings.nativeChatText.lineSpacing", defaultValue: "Line spacing")
    }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .none
    cell.contentView.subviews.filter { $0 is UISegmentedControl }.forEach { $0.removeFromSuperview() }
    cell.accessoryView = nil
    let settings = ChatTextSettings.current
    switch indexPath.section {
    case 0:
      var content = UIListContentConfiguration.valueCell()
      content.text = settings.sizeLabel
      cell.contentConfiguration = content
      let stepper = UIStepper()
      stepper.minimumValue = Double(ChatTextSettings.minSize)
      stepper.maximumValue = Double(ChatTextSettings.maxSize)
      stepper.value = Double(settings.size)
      stepper.addAction(
        UIAction { [weak self, weak stepper] _ in
          var next = ChatTextSettings.current
          next.size = Int(stepper?.value ?? 14)
          ChatTextSettings.current = next
          UISelectionFeedbackGenerator().selectionChanged()
          self?.tableView.reloadSections([0], with: .none)
        }, for: .valueChanged)
      cell.accessoryView = stepper
    default:
      cell.contentConfiguration = nil
      let isFont = indexPath.section == 1
      let titles = isFont ? ChatTextSettings.Font.allCases.map(ChatTextSettings.fontName) : ChatTextSettings.Spacing.allCases.map(ChatTextSettings.spacingName)
      let control = UISegmentedControl(items: titles)
      control.selectedSegmentIndex =
        isFont
        ? ChatTextSettings.Font.allCases.firstIndex(of: settings.font) ?? 0
        : ChatTextSettings.Spacing.allCases.firstIndex(of: settings.lineSpacing) ?? 1
      control.addAction(
        UIAction { [weak control] _ in
          guard let index = control?.selectedSegmentIndex else { return }
          var next = ChatTextSettings.current
          if isFont { next.font = ChatTextSettings.Font.allCases[index] } else { next.lineSpacing = ChatTextSettings.Spacing.allCases[index] }
          ChatTextSettings.current = next
        }, for: .valueChanged)
      control.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(control)
      NSLayoutConstraint.activate([
        control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
        control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
        control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
      ])
    }
    return cell
  }
}

/// What tapping send does while the agent is working: steer into the running turn (the default) or queue
/// the message for after it. Holding send always offers the other.
enum SendWhileWorking: String, CaseIterable {
  case steer, queue

  private static let key = "orca.chat.sendWhileWorking"

  static var current: SendWhileWorking {
    get { UserDefaults.standard.string(forKey: key).flatMap(SendWhileWorking.init) ?? .steer }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }

  var title: String {
    switch self {
    case .steer: String(localized: "chat.composer.sendSteer", defaultValue: "Steer")
    case .queue: String(localized: "chat.composer.sendQueue", defaultValue: "Queue")
    }
  }

  var subtitle: String {
    switch self {
    case .steer: String(localized: "chat.composer.sendSteerHint", defaultValue: "Goes into what the agent is doing now")
    case .queue: String(localized: "chat.composer.sendQueueHint", defaultValue: "Runs after the current turn")
    }
  }
}
