import UIKit

/// Settings › Browser (settings/browser-settings-screen.tsx): where links tapped in terminal output and chat
/// open. Kept on this phone.
final class BrowserSettingsViewController: SettingsPageViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.browserSettingsScreen.title", defaultValue: "Browser")
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Back from the choices, the row reads the new one.
    rebuild()
  }

  private func rebuild() {
    sections = [
      Section(
        header: String(localized: "settings.browserSettingsScreen.linksHeading", defaultValue: "LINKS"),
        footer: String(
          localized: "settings.browserSettingsScreen.terminalAndChatLinksDescription",
          defaultValue: "Choose where web links tapped in terminal output and chat open."),
        rows: [
          // The official row: its title over the current choice, and a chevron to the choices.
          .value(
            icon: .globe, title: String(localized: "settings.browserSettingsScreen.openLinks", defaultValue: "Open links"),
            subtitle: Self.title(PhoneSettings.linkOpenMode), navigates: true
          ) { [weak self] in
            self?.navigationController?.pushViewController(LinkOpenModeViewController(), animated: true)
          }
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

/// Settings › Browser › Open links: the official picker's three choices, each with what it does; picking one
/// saves it and goes back.
final class LinkOpenModeViewController: SettingsPageViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.browserSettingsScreen.openLinks", defaultValue: "Open links")
    rebuild()
  }

  private func rebuild() {
    let current = PhoneSettings.linkOpenMode
    sections = [
      Section(
        rows: PhoneSettings.LinkOpenMode.allCases.map { mode in
          .check(
            title: BrowserSettingsViewController.title(mode), subtitle: BrowserSettingsViewController.subtitle(mode),
            checked: mode == current
          ) { [weak self] in
            PhoneSettings.linkOpenMode = mode
            self?.rebuild()
            self?.navigationController?.popViewController(animated: true)
          }
        })
    ]
  }
}
