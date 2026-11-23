import UIKit

/// A command and its output drawn the way a terminal shows them: Tokyo Night colours, a coloured prompt
/// line, and the output's ANSI SGR colours (16, 256 and true colour, bold, dim, italic, underline) applied.
/// Other escape sequences are dropped, carriage-return progress lines keep their last state.
enum TerminalText {
  static let background = UIColor(red: 0x1a / 255, green: 0x1b / 255, blue: 0x26 / 255, alpha: 1)
  static let foreground = UIColor(red: 0xc0 / 255, green: 0xca / 255, blue: 0xf5 / 255, alpha: 1)

  private static let hexPalette: [UInt32] = [
    0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
    0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
  ]
  private static let palette: [UIColor] = hexPalette.map { (hex: UInt32) -> UIColor in
    UIColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
  }

  static func render(command: String?, output: String, size: CGFloat = 12) -> NSAttributedString {
    let regular = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    let out = NSMutableAttributedString()
    if let command, !command.isEmpty {
      out.append(NSAttributedString(string: "❯ ", attributes: [.font: regular, .foregroundColor: palette[2], .paragraphStyle: paragraph]))
      out.append(
        NSAttributedString(
          string: command + "\n\n",
          attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: size, weight: .semibold), .foregroundColor: palette[4],
            .paragraphStyle: paragraph,
          ]))
    }
    out.append(ansi(collapseCarriageReturns(output), size: size, paragraph: paragraph))
    return out
  }

  /// "40%\r80%\r100%" shows as its last state, as a terminal leaves it.
  private static func collapseCarriageReturns(_ text: String) -> String {
    guard text.contains("\r") else { return text }
    return text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? "" }
      .joined(separator: "\n")
  }

  private struct Style {
    var fg: UIColor?
    var bg: UIColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
  }

  private static func ansi(_ text: String, size: CGFloat, paragraph: NSParagraphStyle) -> NSAttributedString {
    let out = NSMutableAttributedString()
    var style = Style()
    var run = ""
    func flush() {
      guard !run.isEmpty else { return }
      var font = UIFont.monospacedSystemFont(ofSize: size, weight: style.bold ? .bold : .regular)
      if style.italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) { font = UIFont(descriptor: descriptor, size: size) }
      var color = style.fg ?? foreground
      if style.dim { color = color.withAlphaComponent(0.6) }
      var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
      if let bg = style.bg { attributes[.backgroundColor] = bg }
      if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      out.append(NSAttributedString(string: run, attributes: attributes))
      run = ""
    }
    var scalars = Array(text.unicodeScalars)[...]
    while let scalar = scalars.popFirst() {
      guard scalar == "\u{1B}" else {
        run.unicodeScalars.append(scalar)
        continue
      }
      guard scalars.first == "[" else {
        // OSC (title, links) runs to BEL or ST; anything else is a two-character escape.
        if scalars.first == "]" {
          while let next = scalars.popFirst(), next != "\u{07}" {
            if next == "\u{1B}", scalars.first == "\\" { scalars.removeFirst(); break }
          }
        } else {
          _ = scalars.popFirst()
        }
        continue
      }
      scalars.removeFirst()
      var body = ""
      var final: Unicode.Scalar = "m"
      while let next = scalars.popFirst() {
        if (0x40...0x7E).contains(next.value) { final = next; break }
        body.unicodeScalars.append(next)
      }
      guard final == "m" else { continue }
      flush()
      apply(body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }, to: &style)
    }
    flush()
    return out
  }

  private static func apply(_ codes: [Int], to style: inout Style) {
    var codes = codes.isEmpty ? [0] : codes
    while !codes.isEmpty {
      let code = codes.removeFirst()
      switch code {
      case 0: style = Style()
      case 1: style.bold = true
      case 2: style.dim = true
      case 3: style.italic = true
      case 4: style.underline = true
      case 22: style.bold = false; style.dim = false
      case 23: style.italic = false
      case 24: style.underline = false
      case 30...37: style.fg = palette[code - 30]
      case 90...97: style.fg = palette[code - 90 + 8]
      case 39: style.fg = nil
      case 40...47: style.bg = palette[code - 40]
      case 100...107: style.bg = palette[code - 100 + 8]
      case 49: style.bg = nil
      case 38, 48:
        let color = extended(&codes)
        if code == 38 { style.fg = color } else { style.bg = color }
      default: break
      }
    }
  }

  /// `5;n` (256 colours) or `2;r;g;b`.
  private static func extended(_ codes: inout [Int]) -> UIColor? {
    guard let mode = codes.first else { return nil }
    codes.removeFirst()
    if mode == 5, let n = codes.first {
      codes.removeFirst()
      if n < 16 { return palette[n] }
      if n < 232 {
        let i = n - 16
        let level = { (v: Int) -> CGFloat in v == 0 ? 0 : CGFloat(55 + v * 40) / 255 }
        return UIColor(red: level(i / 36), green: level(i / 6 % 6), blue: level(i % 6), alpha: 1)
      }
      let gray = CGFloat(8 + (n - 232) * 10) / 255
      return UIColor(white: gray, alpha: 1)
    }
    if mode == 2, codes.count >= 3 {
      let (r, g, b) = (codes[0], codes[1], codes[2])
      codes.removeFirst(3)
      return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    return nil
  }
}
