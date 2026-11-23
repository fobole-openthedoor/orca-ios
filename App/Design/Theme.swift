import UIKit

// Official Orca mobile tokens (mobile/src/theme/mobile-theme.ts), value for value. The official app is the
// reference: change a value here only when it changes there.

extension UIColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(
      red: CGFloat((hex >> 16) & 0xff) / 255,
      green: CGFloat((hex >> 8) & 0xff) / 255,
      blue: CGFloat(hex & 0xff) / 255,
      alpha: alpha)
  }

  /// A colour that follows the interface style, as the official palette swaps per scheme.
  convenience init(light: UIColor, dark: UIColor) {
    self.init { $0.userInterfaceStyle == .dark ? dark : light }
  }

  fileprivate static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> UIColor {
    UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
  }
}

private func pair(_ light: UInt32, _ dark: UInt32) -> UIColor {
  UIColor(light: UIColor(hex: light), dark: UIColor(hex: dark))
}

private func pair(_ light: UIColor, _ dark: UIColor) -> UIColor {
  UIColor(light: light, dark: dark)
}

/// The palette. Names match the official `colors` keys.
enum Palette {
  static let bgBase = pair(0xffffff, 0x0a0a0a)
  static let bgPanel = pair(0xfafafa, 0x171717)
  static let bgRaised = pair(0xf5f5f5, 0x262626)
  static let borderSubtle = pair(UIColor(hex: 0xe5e5e5), .rgba(255, 255, 255, 0.07))
  static let editorSurface = pair(0xffffff, 0x1e1e1e)
  static let sheetSurface = pair(0xf5f5f5, 0x171717)
  static let sheetGroup = pair(0xffffff, 0x262626)
  static let translucentFill = pair(.rgba(120, 120, 128, 0.16), .rgba(120, 120, 128, 0.36))
  static let composerSurface = pair(0xffffff, 0x1f1f1f)
  static let composerBorder = pair(.rgba(10, 10, 10, 0.11), .rgba(250, 250, 250, 0.09))
  static let composerControl = pair(0xf5f5f5, 0x262626)
  static let floatingCardBorder = pair(.rgba(10, 10, 10, 0.14), .rgba(250, 250, 250, 0.16))
  static let choiceBorder = pair(.rgba(0, 0, 0, 0.44), .rgba(255, 255, 255, 0.34))
  static let choiceSelectedFill = pair(.rgba(20, 118, 56, 0.06), .rgba(134, 239, 172, 0.08))
  static let cardPillFill = pair(.rgba(120, 120, 128, 0.16), UIColor(hex: 0x262626))
  static let inputBorder = pair(0x737373, 0x737373)
  static let skillToken = pair(0x1d4ed8, 0x8ab4f8)
  static let skillTokenSurface = pair(.rgba(59, 130, 246, 0.12), .rgba(59, 130, 246, 0.2))
  static let chatUserSurface = pair(0xf5f5f5, 0x262626)
  static let chatUserBorder = pair(.rgba(10, 10, 10, 0.07), .rgba(250, 250, 250, 0.06))
  static let chatForegroundStrong = pair(0x1e1e1e, 0xe3e3e3)

  static let textPrimary = pair(0x0a0a0a, 0xfafafa)
  static let textSecondary = pair(0x696969, 0xacacac)
  static let textMuted = pair(0x696969, 0x898989)

  static let surfaceBright = pair(0x171717, 0xe5e5e5)
  static let createActionFill = pair(0x171717, 0x3276f2)
  static let onCreateActionFill = pair(0xffffff, 0xffffff)
  static let accentBlue = pair(0x225be3, 0x3276f2)
  static let onAccent = pair(0xffffff, 0xffffff)

  static let statusGreen = pair(0x147638, 0x86efac)
  static let statusAmber = pair(0xca8a04, 0xeab308)
  static let agentQuestion = pair(0xea580c, 0xf97316)
  static let agentQuestionText = pair(0xc2410c, 0xfdba74)
  static let agentQuestionTint = pair(.rgba(234, 88, 12, 0.12), .rgba(249, 115, 22, 0.12))
  static let statusRed = pair(0xe40014, 0xff6568)
  static let onStatusRed = pair(0xffffff, 0x450a0a)
  static let mergeGreen = pair(0x16a34a, 0x16a34a)
  static let onMergeGreen = pair(0xffffff, 0xffffff)
  static let statusPurple = pair(0x9333ea, 0xd8b4fe)
  static let gitDecorationAdded = pair(0x587c0c, 0x81b88b)
  static let gitDecorationDeleted = pair(0xad0707, 0xc74e39)
  static let gitDecorationModified = pair(0x895503, 0xe2c08d)

  static let diffAddedBg = pair(UIColor(hex: 0xdafbe1), .rgba(46, 160, 67, 0.15))
  static let diffDeletedBg = pair(UIColor(hex: 0xffebe9), .rgba(248, 81, 73, 0.13))
  static let diffAddedGutter = pair(UIColor(hex: 0xaceebb), .rgba(63, 185, 80, 0.3))
  static let diffDeletedGutter = pair(UIColor(hex: 0xffcecb), .rgba(248, 81, 73, 0.3))
  static let diffAddedSign = pair(0x1a7f37, 0x3fb950)
  static let diffDeletedSign = pair(0xcf222e, 0xf85149)
  static let diffLineNumber = pair(0x6e7781, 0x6e7681)
  static let diffFoldBg = pair(UIColor(hex: 0xddf4ff), .rgba(56, 139, 253, 0.1))
  static let diffFoldGutter = pair(.rgba(84, 174, 255, 0.4), .rgba(56, 139, 253, 0.22))
  static let diffFoldText = pair(0x0969da, 0x4493f8)
  static let chatDiffAdded = pair(0x415a0b, 0xa5ccac)
  static let chatDiffRemoved = pair(0x7c0808, 0xd68273)

  static let syntaxComment = pair(0x59636e, 0x8b949e)
  static let syntaxKeyword = pair(0xcf222e, 0xff7b72)
  static let syntaxString = pair(0x0a3069, 0xa5d6ff)
  static let syntaxNumber = pair(0x0550ae, 0x79c0ff)
  static let syntaxType = pair(0x953800, 0xffa657)
  static let syntaxFunction = pair(0x8250df, 0xd2a8ff)
  static let syntaxVariable = pair(0x953800, 0xffa657)
  static let syntaxMeta = pair(0x0550ae, 0x79c0ff)
  static let syntaxTag = pair(0x116329, 0x7ee787)

  static let terminalBg = pair(0x1a1b26, 0x1a1b26)
}

/// Per-agent dot colours (agents/presentation/AgentStateDot.tsx), the same in both schemes.
enum AgentColor {
  static let attention = UIColor(hex: 0xef4444)
  static let working = UIColor(hex: 0xeab308)
  static let done = UIColor(hex: 0x10b981)
  static let idle = UIColor.rgba(115, 115, 115, 0.4)
}

enum Spacing {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 24
}

enum Radius {
  /// Everything you tap: buttons, icon buttons, text fields, pickers, segmented controls.
  static let control: CGFloat = 12
  /// Badges, chips, status pills, dots, avatars; use half the height.
  static let pill: CGFloat = 999
  /// Cards, groups, sheets, banners, code boxes, menus.
  static let surface: CGFloat = 16
  /// The composer box and dialogs.
  static let floating: CGFloat = 24
  static let tile: CGFloat = 10
  static let mark: CGFloat = 4

  /// A shape inside another keeps its curve parallel to the parent's.
  static func concentric(_ parent: CGFloat, inset: CGFloat) -> CGFloat { max(mark, parent - inset) }
}

enum Typography {
  static let titleSize: CGFloat = 18
  static let bodySize: CGFloat = 14
  static let metaSize: CGFloat = 12

  static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
    .systemFont(ofSize: size, weight: weight)
  }

  /// Menlo, as the official app uses on iOS.
  static func mono(_ size: CGFloat) -> UIFont {
    UIFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
  }
}

enum Feedback {
  static let pressedOpacity: CGFloat = 0.7
  static let disabledOpacity: CGFloat = 0.4
}
