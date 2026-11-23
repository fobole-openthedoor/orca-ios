import UIKit

extension Notification.Name {
  /// Posted when any `PhoneSettings` value changes; `object` is the changed key's name.
  static let orcaSettingsChanged = Notification.Name("orca.settingsChanged")
}

/// Settings kept on this phone (the official app's AsyncStorage preferences), under `orca.settings.<name>`.
/// Each setter posts `.orcaSettingsChanged` so open screens can apply it.
enum PhoneSettings {
  enum TerminalFont: String, CaseIterable {
    case system
    case menlo
    case courierNew = "courier-new"

    var title: String {
      switch self {
      case .system: "SF Mono"
      case .menlo: "Menlo"
      case .courierNew: "Courier New"
      }
    }

    /// The font at `size`; `weight` is the official 300/400/500 scale.
    func font(size: CGFloat, weight: Int) -> UIFont {
      let uiWeight: UIFont.Weight = weight <= 300 ? .light : weight >= 500 ? .medium : .regular
      switch self {
      case .system: return .monospacedSystemFont(ofSize: size, weight: uiWeight)
      case .menlo: return UIFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: uiWeight)
      case .courierNew: return UIFont(name: "CourierNewPSMT", size: size) ?? .monospacedSystemFont(ofSize: size, weight: uiWeight)
      }
    }
  }

  enum LinkOpenMode: String, CaseIterable {
    case ask
    case orcaBrowser = "orca-browser"
    case phoneBrowser = "phone-browser"
  }

  enum DictationEngine: String, CaseIterable {
    case automatic, phone, computer
  }

  // MARK: Terminal

  static let terminalFontSizeRange: ClosedRange<Double> = 8...26
  static let terminalLineHeights: [Double] = [1, 1.15, 1.3]
  static let terminalWeights: [Int] = [300, 400, 500]

  private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  /// The terminal's text size in points, whole points from 8 to 26 (13 on a phone, 15 on an iPad).
  static var terminalFontSize: Double {
    get { double("terminalFontSize").map { min(max($0.rounded(), 8), 26) } ?? defaultTerminalFontSize }
    set { set(min(max(newValue.rounded(), 8), 26), "terminalFontSize") }
  }
  static var defaultTerminalFontSize: Double { isPad ? 15 : 13 }

  static var terminalFont: TerminalFont {
    get { string("terminalFont").flatMap(TerminalFont.init) ?? .system }
    set { set(newValue.rawValue, "terminalFont") }
  }

  /// Line height multiplier: 1 (Tight), 1.15 (Normal) or 1.3 (Roomy).
  static var terminalLineHeight: Double {
    get { double("terminalLineHeight").flatMap { terminalLineHeights.contains($0) ? $0 : nil } ?? (isPad ? 1.15 : 1) }
    set { set(newValue, "terminalLineHeight") }
  }

  /// Regular text weight: 300 (Light), 400 (Regular) or 500 (Medium); bold is two steps heavier.
  static var terminalFontWeight: Int {
    get { double("terminalFontWeight").map(Int.init).flatMap { terminalWeights.contains($0) ? $0 : nil } ?? (isPad ? 400 : 300) }
    set { set(newValue, "terminalFontWeight") }
  }

  static func resetTerminalFont() {
    remove(["terminalFontSize", "terminalFont", "terminalLineHeight", "terminalFontWeight"])
  }

  // MARK: Chat UI

  // Chat text size, font and spacing live in `ChatTextSettings` (App/Session/ChatTextSettings.swift).

  /// Agent sessions that can show as a chat open in Chat UI instead of the terminal.
  static var openSessionsInChat: Bool {
    get { defaults.bool(forKey: key("openSessionsInChat")) }
    set { set(newValue, "openSessionsInChat") }
  }

  // MARK: Browser

  /// Where web links tapped in terminal output and chat open.
  static var linkOpenMode: LinkOpenMode {
    get { string("linkOpenMode").flatMap(LinkOpenMode.init) ?? .ask }
    set { set(newValue.rawValue, "linkOpenMode") }
  }

  // MARK: Voice

  /// Where dictation is transcribed.
  static var dictationEngine: DictationEngine {
    get { string("dictationEngine").flatMap(DictationEngine.init) ?? .automatic }
    set { set(newValue.rawValue, "dictationEngine") }
  }

  // MARK: Storage

  private static let defaults = UserDefaults.standard

  static func key(_ name: String) -> String { "orca.settings.\(name)" }

  /// Every key this enum stores, for a reset.
  static let allNames = [
    "terminalFontSize", "terminalFont", "terminalLineHeight", "terminalFontWeight", "openSessionsInChat",
    "linkOpenMode", "dictationEngine",
  ]

  static func resetAll() { remove(allNames) }

  private static func double(_ name: String) -> Double? {
    defaults.object(forKey: key(name)) == nil ? nil : defaults.double(forKey: key(name))
  }

  private static func string(_ name: String) -> String? { defaults.string(forKey: key(name)) }

  private static func set(_ value: Any, _ name: String) {
    defaults.set(value, forKey: key(name))
    NotificationCenter.default.post(name: .orcaSettingsChanged, object: name)
  }

  private static func remove(_ names: [String]) {
    for name in names { defaults.removeObject(forKey: key(name)) }
    NotificationCenter.default.post(name: .orcaSettingsChanged, object: nil)
  }
}
