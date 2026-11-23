import UIKit

/// Whether this phone's usage bars show the share of each limit used (default) or left
/// (usage-percentage-display-preference.ts). Kept per device, as on the desktop: a phone can show remaining
/// while the desktop shows used.
enum UsagePercentageDisplay: String, CaseIterable {
  case used, remaining

  /// Posted when the choice changes; screens with usage bars redraw on it.
  static let changed = Notification.Name("orca.usagePercentageDisplayChanged")
  private static let key = "orca.usagePercentageDisplay"

  static var current: UsagePercentageDisplay {
    get { UserDefaults.standard.string(forKey: key).flatMap(UsagePercentageDisplay.init) ?? .used }
    set {
      guard newValue != current else { return }
      UserDefaults.standard.set(newValue.rawValue, forKey: key)
      NotificationCenter.default.post(name: changed, object: nil)
    }
  }

  var title: String {
    switch self {
    case .used: String(localized: "settings.appearance.usage.used", defaultValue: "Used")
    case .remaining: String(localized: "settings.appearance.usage.remaining", defaultValue: "Remaining")
    }
  }
}

/// The language the app's own text is in (ui-language-settings-section.tsx). iOS picks an app's language
/// at launch from `AppleLanguages`, so a choice is written there and takes effect when Orca opens again.
/// Only the localizations this app ships are offered.
enum AppLanguage: String, CaseIterable {
  case system
  case english = "en"
  case simplifiedChinese = "zh-Hans"
  case traditionalChinese = "zh-Hant"

  private static let key = "orca.uiLanguage"

  static var current: AppLanguage {
    get { UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init) ?? .system }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: key)
      if newValue == .system {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
      } else {
        UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
      }
    }
  }

  /// The official native names (UI_LANGUAGE_NATIVE_NAMES), the same in every language.
  var nativeName: String {
    switch self {
    case .system: "System"
    case .english: "English"
    case .simplifiedChinese: "中文（简体）"
    case .traditionalChinese: "繁體中文（台灣）"
    }
  }

  /// The language "System" means on this device. The app's own `AppleLanguages` hides the device's list
  /// once a language is picked, so the global one is read first.
  static var systemResolved: AppLanguage {
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
    let preferences = current == .system ? Locale.preferredLanguages : (global ?? Locale.preferredLanguages)
    let shipped = allCases.filter { $0 != .system }.map(\.rawValue)
    let match = Bundle.preferredLocalizations(from: shipped, forPreferences: preferences).first ?? "en"
    return AppLanguage(rawValue: match) ?? .english
  }
}

/// Settings › Appearance (settings/appearance-settings-screen.tsx): theme, usage percentages and language,
/// all kept on this phone.
final class AppearanceViewController: SettingsPageViewController {
  enum Theme: String, CaseIterable {
    case system, light, dark

    var title: String {
      switch self {
      case .system: String(localized: "settings.appearance.theme.system", defaultValue: "System")
      case .light: String(localized: "settings.appearance.theme.light", defaultValue: "Light")
      case .dark: String(localized: "settings.appearance.theme.dark", defaultValue: "Dark")
      }
    }

    var style: UIUserInterfaceStyle {
      switch self {
      case .system: .unspecified
      case .light: .light
      case .dark: .dark
      }
    }

    static var current: Theme {
      get { Theme(rawValue: UserDefaults.standard.string(forKey: "orca.theme") ?? "") ?? .system }
      set {
        UserDefaults.standard.set(newValue.rawValue, forKey: "orca.theme")
        apply()
      }
    }

    static func apply() {
      for scene in UIApplication.shared.connectedScenes {
        for window in (scene as? UIWindowScene)?.windows ?? [] { window.overrideUserInterfaceStyle = current.style }
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.appearance.title", defaultValue: "Appearance")
    rebuild()
  }

  private func rebuild() {
    let theme = Theme.current
    let usage = UsagePercentageDisplay.current
    let language = AppLanguage.current
    sections = [
      Section(
        header: String(localized: "settings.appearance.theme.heading", defaultValue: "THEME"),
        footer: String(localized: "settings.appearance.theme.description", defaultValue: "System follows this device’s light or dark setting."),
        rows: Theme.allCases.map { choice in
          .check(title: choice.title, checked: choice == theme) { [weak self] in
            Theme.current = choice
            self?.rebuild()
          }
        }),
      Section(
        header: String(localized: "settings.appearance.usage.heading", defaultValue: "USAGE PERCENTAGES"),
        footer: String(
          localized: "settings.appearance.usage.description",
          defaultValue: "Usage bars on Home and Accounts show how much of each limit is used or left. Saved on this phone."),
        rows: UsagePercentageDisplay.allCases.map { choice in
          .check(title: choice.title, checked: choice == usage) { [weak self] in
            UsagePercentageDisplay.current = choice
            self?.rebuild()
          }
        }),
      Section(
        header: String(localized: "settings.appearance.language.heading", defaultValue: "LANGUAGE"),
        footer: String(
          localized: "settings.appearance.language.description",
          defaultValue: "System follows this device’s language. Permission prompts always use the device language."),
        rows: AppLanguage.allCases.map { choice in
          let title =
            choice == .system
            ? String(
              format: String(localized: "settings.appearance.language.systemWithCurrent", defaultValue: "System (%1$@)"),
              AppLanguage.systemResolved.nativeName)
            : choice.nativeName
          return .check(title: title, checked: choice == language) { [weak self] in
            guard choice != AppLanguage.current else { return }
            AppLanguage.current = choice
            self?.rebuild()
            self?.showAlert(
              title: String(localized: "orcaios.language.restartTitle", defaultValue: "Reopen Orca to change the language"),
              message: String(
                localized: "orcaios.language.restartMessage",
                defaultValue: "Close Orca from the app switcher and open it again. Until then, Orca keeps its current language."))
          }
        }),
    ]
  }
}
