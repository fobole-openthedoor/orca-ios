import GhosttyTerminal
import GhosttyTheme
import UIKit

/// The terminal settings iGhostVT ships with: Apple's system palette in each appearance, Ghostty's own
/// face at 10 pt, a blinking block cursor. The view paints no padding so its grid is exact.
@MainActor
enum TerminalAppearance {
  // The official terminal is Tokyo Night in both appearances (theme terminalBg #1a1b26).
  static let lightThemeName = "TokyoNight Night"
  static let darkThemeName = "TokyoNight Night"
  static let defaultFontSize: Float = 10
  static let fontSizeRange: ClosedRange<Float> = 4...64

  static var light: GhosttyThemeDefinition? { GhosttyThemeCatalog.theme(named: lightThemeName) }
  static var dark: GhosttyThemeDefinition? { GhosttyThemeCatalog.theme(named: darkThemeName) }

  /// The desktop's palette as the theme for both appearances; the bundled theme when it sent none.
  static func theme(colors: [String: String]?) -> TerminalTheme {
    guard let colors, colors["background"] != nil else { return theme }
    let configuration = self.configuration(fontSize: fontSize, colors: colors)
    return TerminalTheme(light: configuration, dark: configuration)
  }

  static var theme: TerminalTheme {
    guard let light, let dark else {
      return .default
    }
    return TerminalTheme(light: light.toTerminalConfiguration(), dark: dark.toTerminalConfiguration())
  }

  /// xterm theme keys in ANSI palette order, as the desktop sends them.
  private static let ansiNames = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
  ]

  /// `colors` is the desktop's palette; when present it wins over the bundled theme, so both screens match.
  static func configuration(fontSize: Float, colors: [String: String]? = nil) -> TerminalConfiguration {
    TerminalConfiguration { builder in
      builder.withFontSize(fontSize)
      if let colors {
        if let background = colors["background"] { builder.withCustom("background", background) }
        if let foreground = colors["foreground"] { builder.withCustom("foreground", foreground) }
        if let cursor = colors["cursor"] { builder.withCustom("cursor-color", cursor) }
        if let selection = colors["selectionBackground"], selection.count == 7 {
          builder.withCustom("selection-background", selection)
        }
        for (index, name) in ansiNames.enumerated() {
          if let value = colors[name], value.hasPrefix("#") { builder.withCustom("palette", "\(index)=\(value)") }
        }
      }
      builder.withCursorStyleBlink(true)
      builder.withWindowPaddingX(0)
      builder.withWindowPaddingY(0)
      builder.withCustom("window-padding-balance", "false")
      builder.withCustom("window-padding-color", "extend")
    }
  }

  /// The theme's background for an appearance, painted around the terminal so the screen reads as one surface.
  static func background(for traits: UITraitCollection) -> UIColor {
    let definition = traits.userInterfaceStyle == .dark ? dark : light
    return definition.flatMap { UIColor(hex: $0.background) } ?? .systemBackground
  }

  /// One size for pinch and Settings › Terminal: Settings' value once the reader set one there, else the
  /// size pinching last left (or the default).
  static var fontSize: Float {
    get {
      if UserDefaults.standard.object(forKey: "orca.settings.terminalFontSize") != nil {
        return Float(PhoneSettings.terminalFontSize)
      }
      let stored = UserDefaults.standard.float(forKey: "Terminal.fontSize")
      return stored == 0 ? defaultFontSize : min(max(stored, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: "Terminal.fontSize")
      // Keep Settings in step once it owns the value; its range is narrower than pinch's.
      if UserDefaults.standard.object(forKey: "orca.settings.terminalFontSize") != nil {
        UserDefaults.standard.set(Double(min(max(newValue.rounded(), 8), 26)), forKey: "orca.settings.terminalFontSize")
      }
    }
  }
}

extension UIColor {
  convenience init?(hex: String) {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
      return nil
    }
    self.init(hex: value)
  }
}

/// Ghostty's view with paste routed through the controller, so an image becomes a host path rather than
/// a path on the phone, and the long-press menu's Paste takes the same route.
final class OrcaTerminalView: TerminalView {
  var onPaste: (() -> Bool)?
  /// Presses that went down in the current run-loop turn, while a composing input mode (Pinyin, Kana, Hangul)
  /// is active.
  private var pressesThisTurn: Set<UIPress> = []

  // Under a composing input mode Ghostty loans a printable key to the input method and, for the process's
  // first such key, finds out at the next run-loop turn whether the system handed it over. If the key is
  // already up by then (a quick tap, or synthetic typing), it is passed on without its event, the input
  // method never takes it, and the claim of the next key discards it: "echo" arrived as "cho". Holding a
  // release that lands in the same turn as its press until after that check keeps the press down for it.
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesBegan(presses, with: event)
    guard Self.composes(textInputMode) else {
      return
    }
    if pressesThisTurn.isEmpty {
      DispatchQueue.main.async { [weak self] in self?.pressesThisTurn.removeAll() }
    }
    pressesThisTurn.formUnion(presses)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard !pressesThisTurn.isDisjoint(with: presses) else {
      super.pressesEnded(presses, with: event)
      return
    }
    // Queued after Ghostty's own check, which pressesBegan queued first.
    DispatchQueue.main.async { super.pressesEnded(presses, with: event) }
  }

  private static func composes(_ mode: UITextInputMode?) -> Bool {
    let language = mode?.primaryLanguage?.lowercased() ?? ""
    return language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")
  }

  override func paste(_ sender: Any?) {
    if onPaste?() != true {
      super.paste(sender)
    }
  }

  override func touchMenuItems(for context: TerminalTouchMenuContext) -> [UIMenuElement] {
    super.touchMenuItems(for: context).map(routingPaste)
  }

  override func touchSelectionMenuItems(for context: TerminalTouchSelectionMenuContext) -> [UIMenuElement] {
    super.touchSelectionMenuItems(for: context).map(routingPaste)
  }

  private func routingPaste(_ element: UIMenuElement) -> UIMenuElement {
    guard let action = element as? UIAction, action.identifier.rawValue == "terminal.paste" else {
      return element
    }
    return UIAction(title: action.title, image: action.image, identifier: action.identifier) { [weak self] _ in
      self?.paste(nil)
    }
  }
}
