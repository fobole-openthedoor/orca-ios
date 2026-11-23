import Foundation

/// Markdown read as one line of plain words, for a list row's preview: emphasis, code marks, headings,
/// quotes, list bullets and link targets go; the words stay. Rows show the reply, not its syntax.
enum MarkdownPreview {
  static func plain(_ text: String) -> String {
    var value = text
    let rules: [(String, String)] = [
      ("```[a-zA-Z0-9_+-]*", ""),  // fence openers
      ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),  // links and images keep their words
      ("(?m)^\\s{0,3}#{1,6}\\s+", ""),  // headings
      ("(?m)^\\s*>\\s?", ""),  // quotes
      ("(?m)^\\s*([-*+]|\\d+[.)])\\s+", ""),  // list markers
      ("(\\*\\*|__)(.+?)\\1", "$2"),  // bold
      ("(?<![\\w*])[*_](?!\\s)(.+?)(?<!\\s)[*_](?![\\w*])", "$1"),  // italics
      ("~~(.+?)~~", "$1"),
      ("`([^`]*)`", "$1"),
      ("(?m)^\\s*\\|?[-:| ]{3,}\\|?\\s*$", ""),  // table rules
      ("\\|", " "),
      ("\\s+", " "),
    ]
    for (pattern, template) in rules {
      value = value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
