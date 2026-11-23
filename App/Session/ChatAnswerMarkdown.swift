import Litext
import MarkdownParser
import MarkdownView
import UIKit

/// An answer's Markdown, drawn by MarkdownView (FlowDown's renderer): headings, lists, tables, quotes and
/// code blocks highlighted in Xcode's palette, new words fading in while the answer streams. It reports
/// its height for the width it is given, so a chat row sizes without a second layout pass.
final class ChatAnswerMarkdownView: UIView {
  /// A tapped link, or a file path written as code.
  var onOpenURL: ((URL) -> Void)?
  var onOpenPath: ((String) -> Void)?
  /// Selected words the reader chose to quote.
  var onQuote: ((String) -> Void)? {
    didSet { markdown.onQuote = onQuote }
  }
  /// The content's height changed after it was laid out (a stream added a line): the row should re-measure.
  var onHeightChange: (() -> Void)?

  private let markdown = ReportingStreamView()
  private var width: CGFloat = 0
  private var shown: String?
  private var themeKey: ChatTextSettings?

  init() {
    super.init(frame: .zero)
    markdown.throttleInterval = 1 / 20
    markdown.onApplied = { [weak self] in self?.contentChanged() }
    markdown.linkHandler = { [weak self] payload, _, _ in
      guard let self else { return }
      let target: String =
        switch payload {
        case .url(let url): url.absoluteString
        case .string(let text): text
        }
      if target.hasPrefix(Self.pathScheme) {
        self.onOpenPath?(String(target.dropFirst(Self.pathScheme.count)).removingPercentEncoding ?? "")
      } else if let url = URL(string: target) {
        self.onOpenURL?(url)
      }
    }
    addSubview(markdown)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The width the text wraps at; set before `show` so the first measure is right.
  func setWidth(_ value: CGFloat) {
    guard abs(value - width) > 0.5 else { return }
    width = value
    invalidateIntrinsicContentSize()
  }

  /// Done typing out a reply that arrived whole.
  var onRevealFinished: (() -> Void)?

  /// Words that arrive in one piece (or a big jump) type out over a moment, as ChatGPT's do, instead of
  /// landing as a block. Set by the chat for replies arriving now, not for history scrolled to.
  var reveals = false

  private var target: (text: String, streaming: Bool, identity: String)?
  private var revealed = 0
  private var revealLink: CADisplayLink?

  func show(_ raw: String, streaming: Bool, identity: String) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let fresh = markdown.streamIdentity != AnyHashable(identity)
    // How far the words already on screen go; a new reply starts from nothing.
    let from = fresh ? 0 : (revealLink != nil ? revealed : (shown?.count ?? 0))
    let jump = text.count - from
    guard reveals, jump > 24 else {
      stopReveal()
      apply(text, streaming: streaming, identity: identity)
      return
    }
    target = (text, streaming, identity)
    revealed = from
    if fresh { apply("", streaming: true, identity: identity) }
    if revealLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(revealStep))
      link.add(to: .main, forMode: .common)
      revealLink = link
    }
  }

  @objc private func revealStep() {
    guard let target else { return stopReveal() }
    let total = target.text.count
    // Quick: a long reply still finishes in about a second.
    revealed = min(total, revealed + max(3, Int((Double(total) / 70).rounded(.up))))
    if revealed >= total {
      stopReveal()
      apply(target.text, streaming: target.streaming, identity: target.identity)
      if !target.streaming { onRevealFinished?() }
      return
    }
    apply(String(target.text.prefix(revealed)), streaming: true, identity: target.identity)
  }

  private func stopReveal() {
    revealLink?.invalidate()
    revealLink = nil
    target = nil
  }

  /// Still typing out.
  var isRevealing: Bool { revealLink != nil }

  private func apply(_ text: String, streaming: Bool, identity: String) {
    let settings = ChatTextSettings.current
    if settings != themeKey {
      themeKey = settings
      markdown.theme = Self.theme(settings)
    }
    guard text != shown || markdown.isStreaming != streaming else { return }
    let first = markdown.streamIdentity != AnyHashable(identity)
    markdown.streamIdentity = identity
    markdown.isStreaming = streaming
    shown = text
    let content = MarkdownContent(markdown: Self.linkingPaths(text), theme: markdown.theme, isStreaming: streaming)
    if first || !streaming {
      markdown.setContentImmediately(content)
    } else {
      markdown.setContent(content)
    }
    invalidateIntrinsicContentSize()
  }

  private func contentChanged() {
    let before = intrinsicContentSize.height
    invalidateIntrinsicContentSize()
    if abs(intrinsicContentSize.height - before) > 0.5 { onHeightChange?() }
  }

  override var intrinsicContentSize: CGSize {
    guard width > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: 0) }
    return CGSize(width: UIView.noIntrinsicMetric, height: ceil(markdown.boundingSize(for: width).height))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.width > 0 { setWidth(bounds.width) }
    markdown.frame = bounds
  }

  private static let pathScheme = "orca-path:"

  /// Code that names a file reads as a link, as the official app does: `src/app.ts` becomes
  /// [`src/app.ts`](orca-path:src/app.ts). Fenced blocks are left alone.
  static func linkingPaths(_ text: String) -> String {
    guard text.contains("`") else { return text }
    var out = ""
    var inFence = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
      out += inFence || line.hasPrefix("```") ? String(line) : linkCodeSpans(String(line))
      out += "\n"
    }
    return String(out.dropLast())
  }

  private static let codeSpan = try! NSRegularExpression(pattern: "(?<![\\[`])`([^`\\n]+)`(?![`\\]])")

  private static func linkCodeSpans(_ line: String) -> String {
    let ns = line as NSString
    var result = line
    for match in codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
      let code = ns.substring(with: match.range(at: 1))
      guard ChatMarkdown.looksLikePath(code) || code.hasPrefix("~/"),
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
        let range = Range(match.range, in: result)
      else { continue }
      result.replaceSubrange(range, with: "[`\(code)`](\(pathScheme)\(encoded))")
    }
    return result
  }

  /// The chat's prose on MarkdownView: the reader's font and size, the official colours.
  private static func theme(_ settings: ChatTextSettings) -> MarkdownTheme {
    var theme = MarkdownTheme()
    let size = ChatProse.bodySize
    theme.fonts.body = settings.bodyFont(ofSize: size)
    theme.fonts.bold = settings.bodyFont(ofSize: size, weight: .semibold)
    theme.fonts.italic = UIFont.italicSystemFont(ofSize: size)
    theme.fonts.codeInline = Typography.mono(ChatProse.codeSize)
    theme.fonts.code = Typography.mono(ChatProse.codeSize)
    theme.fonts.largeTitle = settings.bodyFont(ofSize: size * 1.3, weight: .bold)
    theme.fonts.title = settings.bodyFont(ofSize: size * 1.12, weight: .semibold)
    theme.fonts.footnote = settings.bodyFont(ofSize: size * 0.85)
    theme.colors.body = Palette.chatForegroundStrong
    theme.colors.highlight = Palette.accentBlue
    theme.colors.emphasis = Palette.accentBlue
    theme.colors.code = Palette.textPrimary
    theme.colors.codeBackground = Palette.bgRaised
    theme.colors.codeBlockBackground = Palette.bgRaised
    theme.spacings.general = 8 * settings.lineFactor
    theme.spacings.paragraph = 12 * settings.lineFactor
    return theme
  }
}

/// A stream view that says when a new document has been laid out, so its row can re-measure.
private final class ReportingStreamView: MarkdownStreamView {
  var onApplied: (() -> Void)?
  var onQuote: ((String) -> Void)?

  /// The selection's menu: the system's (Copy, Look Up, Translate, Share) with Quote after Copy, which puts
  /// the selected words over the composer as a quote.
  override func textLabelView(
    _ label: TextLabelView, editMenuForSelection range: NSRange, suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    guard let onQuote else { return nil }
    let quote = UIAction(
      title: String(localized: "orcaios.chat.quote", defaultValue: "Quote"), image: UIImage(systemName: "text.quote")
    ) { [weak label] _ in
      guard let label, let text = label.selectionGroup?.selectedPlainText() ?? label.selectedPlainText() else { return }
      label.clearSelection()
      onQuote(text)
    }
    var actions = suggestedActions
    actions.insert(quote, at: min(1, actions.count))
    return UIMenu(children: actions)
  }

  override func applyDocument(_ document: NSAttributedString, newContextViews: [UIView], animated: Bool) {
    super.applyDocument(document, newContextViews: newContextViews, animated: animated)
    onApplied?()
  }
}
