import UIKit

/// Chat prose (components/markdown/mobile-markdown-styles.ts at the chat's 1.25 scale): body 13/21,
/// code 12, headings 16/23 and 18/25, all × 1.25.
enum ChatProse {
  /// The chat's 1.25 scale, times the reader's text size (Text size; 14 pt is 1×).
  static var scale: CGFloat { 1.25 * ChatTextSettings.current.factor }
  static var bodySize: CGFloat { 13 * scale }
  static var bodyLine: CGFloat { 21 * scale * ChatTextSettings.current.lineFactor }
  static var codeSize: CGFloat { 12 * scale }
  /// Activity lines, thoughts and the turn clock: the official 12 pt meta size, scaled like prose.
  static var metaSize: CGFloat { 12 * scale }

  static func bodyFont(weight: UIFont.Weight = .regular) -> UIFont {
    ChatTextSettings.current.bodyFont(ofSize: bodySize, weight: weight)
  }

  static func bodyAttributes(color: UIColor = Palette.textPrimary, font: UIFont? = nil) -> [NSAttributedString.Key: Any] {
    let font = font ?? bodyFont()
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = bodyLine
    paragraph.maximumLineHeight = bodyLine
    return [
      .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
      .baselineOffset: (bodyLine - font.lineHeight) / 2,
    ]
  }
}

/// One block of a rendered message.
enum ChatBlock {
  case text(NSAttributedString)
  case code(language: String?, text: String)
  case rule
}

enum ChatMarkdown {
  static func render(_ source: String, color: UIColor = Palette.textPrimary) -> [ChatBlock] {
    var blocks: [ChatBlock] = []
    var paragraph: [String] = []
    var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]

    func flush() {
      let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      paragraph = []
      guard !text.isEmpty else { return }
      blocks.append(.text(inline(text, color: color)))
    }

    while let line = lines.first {
      lines = lines.dropFirst()
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        flush()
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var code: [String] = []
        while let next = lines.first {
          lines = lines.dropFirst()
          if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
          code.append(next)
        }
        blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
      } else if trimmed.isEmpty {
        flush()
      } else if trimmed == "---" || trimmed == "***" {
        flush()
        blocks.append(.rule)
      } else if let level = headingLevel(trimmed) {
        flush()
        let text = String(trimmed.dropFirst(level + 1))
        let size: CGFloat = (level <= 1 ? 18 : 16) * ChatProse.scale
        let line: CGFloat = (level <= 1 ? 25 : 23) * ChatProse.scale * ChatTextSettings.current.lineFactor
        let font = ChatTextSettings.current.bodyFont(ofSize: size, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = line
        paragraph.maximumLineHeight = line
        blocks.append(
          .text(
            inline(
              text, color: color,
              base: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                .baselineOffset: (line - font.lineHeight) / 2,
              ])))
      } else if let item = listItem(trimmed) {
        flush()
        let indent = CGFloat(line.prefix { $0 == " " }.count / 2) * 16
        var base = ChatProse.bodyAttributes(color: color)
        let style = (base[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        style.headIndent = indent + 22
        style.firstLineHeadIndent = indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
        base[.paragraphStyle] = style
        let text = NSMutableAttributedString(string: item.marker + "\t", attributes: base)
        text.append(inline(item.text, color: color, base: base))
        blocks.append(.text(text))
      } else if trimmed.hasPrefix(">") {
        flush()
        let quote = String(trimmed.drop { $0 == ">" || $0 == " " })
        blocks.append(.text(inline(quote, color: Palette.textSecondary)))
      } else {
        paragraph.append(line)
      }
    }
    flush()
    return blocks
  }

  private static func headingLevel(_ line: String) -> Int? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    return hashes
  }

  private static func listItem(_ line: String) -> (marker: String, text: String)? {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
      return ("•", String(line.dropFirst(2)))
    }
    let digits = line.prefix { $0.isNumber }
    if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
      return ("\(digits).", String(line.dropFirst(digits.count + 2)))
    }
    return nil
  }

  /// Inline code, **bold**, *italic*, [links](url). Code that names a file reads as a link, as the official app does.
  static func inline(
    _ text: String, color: UIColor = Palette.textPrimary, base: [NSAttributedString.Key: Any]? = nil
  ) -> NSAttributedString {
    let base = base ?? ChatProse.bodyAttributes(color: color)
    let baseFont = base[.font] as? UIFont ?? ChatProse.bodyFont()
    let out = NSMutableAttributedString()
    var index = text.startIndex
    var plain = ""

    func emitPlain() {
      guard !plain.isEmpty else { return }
      out.append(NSAttributedString(string: plain, attributes: base))
      plain = ""
    }

    while index < text.endIndex {
      let rest = text[index...]
      if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
        emitPlain()
        let code = String(rest[rest.index(after: rest.startIndex)..<close])
        var attributes = base
        let codeFont = Typography.mono(ChatProse.codeSize)
        attributes[.font] = codeFont
        attributes[.chipBackground] = Palette.bgRaised
        attributes[.baselineOffset] = ((base[.baselineOffset] as? CGFloat) ?? 0) + (baseFont.lineHeight - codeFont.lineHeight) / 2 - 1
        if looksLikePath(code) {
          attributes[.foregroundColor] = Palette.accentBlue
          attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
          attributes[.orcaPath] = code
        }
        // The page draws code as a padded inline box: a thin space inside each edge of the chip, and 2 pt
        // of air outside it so neighbouring words do not touch the fill.
        if out.length > 0 { out.addAttribute(.kern, value: 2, range: NSRange(location: out.length - 1, length: 1)) }
        // Narrow no-break spaces in the body font: about 3 pt each, and they never wrap away from the code.
        let padded = NSMutableAttributedString(string: "\u{202F}\(code)\u{202F}", attributes: attributes)
        padded.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: 1))
        padded.addAttribute(.font, value: baseFont, range: NSRange(location: padded.length - 1, length: 1))
        padded.addAttribute(.kern, value: 2, range: NSRange(location: padded.length - 1, length: 1))
        out.append(padded)
        index = text.index(after: close)
      } else if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
        emitPlain()
        var attributes = base
        attributes[.font] = ChatTextSettings.current.bodyFont(ofSize: baseFont.pointSize, weight: .semibold)
        out.append(inline(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]), color: color, base: attributes))
        index = close.upperBound
      } else if rest.hasPrefix("["), let mid = rest.range(of: "]("), let end = rest[mid.upperBound...].firstIndex(of: ")"),
        !rest[rest.index(after: rest.startIndex)..<mid.lowerBound].contains("\n")
      {
        emitPlain()
        var attributes = base
        attributes[.foregroundColor] = Palette.accentBlue
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        if let url = URL(string: String(rest[mid.upperBound..<end])) { attributes[.link] = url }
        out.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<mid.lowerBound]), attributes: attributes))
        index = text.index(after: end)
      } else if (rest.hasPrefix("*") || rest.hasPrefix("_")), !rest.hasPrefix("**"),
        let close = rest.dropFirst().firstIndex(of: rest.first!), close > rest.index(after: rest.startIndex),
        !rest[rest.startIndex..<close].contains(" \n")
      {
        emitPlain()
        var attributes = base
        attributes[.font] = UIFont.italicSystemFont(ofSize: baseFont.pointSize)
        out.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<close]), attributes: attributes))
        index = text.index(after: close)
      } else {
        plain.append(text[index])
        index = text.index(after: index)
      }
    }
    emitPlain()
    return out
  }

  /// Marks bare file paths (src/greet.ts) as links, as the official transcript does in plain text.
  static func linkingPaths(_ text: NSAttributedString) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: text)
    let pattern = try! NSRegularExpression(pattern: #"(?<![\w/.])(?:[\w.-]+/)+[\w.-]+\.[A-Za-z0-9]{1,5}(?![\w/])"#)
    for match in pattern.matches(in: text.string, range: NSRange(location: 0, length: out.length)) {
      if out.attribute(.chipBackground, at: match.range.location, effectiveRange: nil) != nil { continue }
      out.addAttributes(
        [
          .foregroundColor: Palette.accentBlue, .underlineStyle: NSUnderlineStyle.single.rawValue,
          .orcaPath: (text.string as NSString).substring(with: match.range),
        ], range: match.range)
    }
    return out
  }

  private static func looksLikePath(_ code: String) -> Bool {
    guard !code.contains(" "), code.contains("/") || code.contains(".") else { return false }
    let ext = (code as NSString).pathExtension
    return code.contains("/") && !ext.isEmpty && ext.count <= 5 && !code.contains("(")
  }
}

extension NSAttributedString.Key {
  /// A file path in chat text, which opens the file's preview when tapped.
  static let orcaPath = NSAttributedString.Key("orca.path")
}
