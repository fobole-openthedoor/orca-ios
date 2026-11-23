import UIKit

/// Settings › Browser (settings/browser-settings-screen.tsx): where links tapped in terminal output and chat
/// open. Kept on this phone.
final class BrowserSettingsViewController: SettingsPageViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.browserSettingsScreen.title", defaultValue: "Browser")
    rebuild()
  }

  private func rebuild() {
    let current = PhoneSettings.linkOpenMode
    sections = [
      Section(
        header: String(localized: "settings.browserSettingsScreen.linksHeading", defaultValue: "LINKS"),
        footer: String(
          localized: "settings.browserSettingsScreen.terminalAndChatLinksDescription",
          defaultValue: "Choose where web links tapped in terminal output and chat open."),
        rows: [
          .menu(
            icon: .globe, title: String(localized: "settings.browserSettingsScreen.openLinks", defaultValue: "Open links"),
            value: Self.title(current),
            options: PhoneSettings.LinkOpenMode.allCases.map { mode in
              Option(title: Self.title(mode), subtitle: Self.subtitle(mode), selected: mode == current) { [weak self] in
                PhoneSettings.linkOpenMode = mode
                self?.rebuild()
              }
            })
        ])
    ]
  }

  static func title(_ mode: PhoneSettings.LinkOpenMode) -> String {
    switch mode {
    case .ask: String(localized: "settings.browserSettingsScreen.askEachTime", defaultValue: "Ask each time")
    case .orcaBrowser: String(localized: "settings.browserSettingsScreen.desktopBrowser", defaultValue: "Orca browser on desktop")
    case .phoneBrowser: String(localized: "settings.browserSettingsScreen.phoneBrowser", defaultValue: "Phone browser")
    }
  }

  static func subtitle(_ mode: PhoneSettings.LinkOpenMode) -> String {
    switch mode {
    case .ask:
      String(
        localized: "settings.browserSettingsScreen.askEachTimeDescription",
        defaultValue: "Choose Orca browser, phone browser, or copy the link each time.")
    case .orcaBrowser:
      String(
        localized: "settings.browserSettingsScreen.desktopBrowserDescription",
        defaultValue: "Open in the streamed browser from your paired desktop.")
    case .phoneBrowser:
      String(
        localized: "settings.browserSettingsScreen.phoneBrowserDescription",
        defaultValue: "Open in Safari, Chrome, or another browser on this phone.")
    }
  }
}
