import MarkdownParser
import MarkdownView
import UIKit

/// A file drawn by MarkdownView in a scroll view: a Markdown file rendered, or source code as one
/// highlighted block (Xcode's palette, line numbers). The text view lays out for the scroll view's width
/// and only draws what is on screen.
final class FileMarkdownView: UIScrollView {
  private let markdown = MarkdownTextView()
  private var source = ""
  private var laidOutWidth: CGFloat = 0
  /// Highlighting a very long file costs more than it reads; past this many lines code shows plain.
  static let highlightLineLimit = 4000

  init() {
    super.init(frame: .zero)
    backgroundColor = Palette.bgBase
    alwaysBounceVertical = true
    var theme = MarkdownTheme()
    theme.fonts.code = Typography.mono(12)
    theme.fonts.codeInline = Typography.mono(13)
    theme.colors.body = Palette.textPrimary
    theme.colors.highlight = Palette.accentBlue
    theme.colors.codeBackground = Palette.bgRaised
    theme.colors.codeBlockBackground = Palette.bgRaised
    markdown.theme = theme
    markdown.throttleInterval = nil
    markdown.trackedScrollView = self
    markdown.linkHandler = { payload, _, _ in
      if case .url(let url) = payload { UIApplication.shared.open(url) }
    }
    addSubview(markdown)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// A Markdown file as its rendered document.
  func showMarkdown(_ text: String) {
    source = text
    markdown.setContentImmediately(MarkdownContent(markdown: text, theme: markdown.theme))
    laidOutWidth = 0
    setNeedsLayout()
  }

  /// Source code as one highlighted block, in the language its extension names.
  func showCode(_ text: String, language: String) {
    showMarkdown("```\(language)\n\(text)\n```")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width - Spacing.md * 2
    guard width > 0, abs(width - laidOutWidth) > 0.5 else { return }
    laidOutWidth = width
    let height = markdown.boundingSize(for: width).height
    markdown.frame = CGRect(x: Spacing.md, y: Spacing.md, width: width, height: height)
    contentSize = CGSize(width: bounds.width, height: height + Spacing.md + Spacing.xl)
  }

  /// The fence language for a file's extension, or nil when it isn't code worth highlighting.
  static func language(for path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    let map: [String: String] = [
      "swift": "swift", "ts": "typescript", "tsx": "tsx", "js": "javascript", "jsx": "jsx", "mjs": "javascript",
      "cjs": "javascript", "py": "python", "rb": "ruby", "go": "go", "rs": "rust", "java": "java", "kt": "kotlin",
      "c": "c", "h": "c", "m": "objectivec", "mm": "objectivec", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "cs": "csharp",
      "php": "php", "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "json": "json", "yaml": "yaml",
      "yml": "yaml", "toml": "toml", "xml": "xml", "html": "html", "css": "css", "scss": "scss", "sql": "sql",
      "lua": "lua", "dart": "dart", "vue": "html", "svelte": "html", "graphql": "graphql", "dockerfile": "dockerfile",
    ]
    if (path as NSString).lastPathComponent.lowercased() == "dockerfile" { return "dockerfile" }
    return map[ext]
  }

  static func isMarkdown(_ path: String) -> Bool {
    ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
  }
}
