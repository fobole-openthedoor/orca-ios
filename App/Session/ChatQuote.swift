import UIKit

/// Quoting words from the chat into the next message. A quote travels as a Markdown block quote ahead of
/// the words typed, so the agent reads it as quoted; the bubble draws it as its own block.
enum ChatQuote {
  static func wrap(_ quote: String?, around typed: String) -> String {
    guard let quote, !quote.isEmpty else { return typed }
    let block = quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    return typed.isEmpty ? block : block + "\n\n" + typed
  }

  /// A message's leading block quote and the rest.
  static func split(_ text: String) -> (quote: String?, body: String) {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
    var quoted: [Substring] = []
    while let line = lines.first, line.hasPrefix(">") {
      quoted.append(line.dropFirst(line.hasPrefix("> ") ? 2 : 1))
      lines = lines.dropFirst()
    }
    guard !quoted.isEmpty else { return (nil, text) }
    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (quoted.joined(separator: "\n"), body)
  }
}

/// A quote as a block: an accent bar down its edge, the quoted words muted beside it, cut at a few lines.
final class ChatQuoteBlock: UIView {
  private let bar = UIView()
  private let label = TextLabel(size: ChatProse.metaSize, color: Palette.textSecondary, lines: 4)

  init() {
    super.init(frame: .zero)
    isHidden = true
    bar.backgroundColor = Palette.accentBlue
    bar.layer.cornerRadius = 1.5
    bar.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bar)
    addSubview(label)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      bar.widthAnchor.constraint(equalToConstant: 3),
      label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Spacing.sm),
      label.trailingAnchor.constraint(equalTo: trailingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ quote: String?) {
    label.text = quote
    isHidden = (quote ?? "").isEmpty
  }
}

/// The quote waiting to go with the next message, on glass over the composer: "Quote" over the words, an
/// x to drop it.
final class ChatQuoteBar: UIView {
  var onDismiss: (() -> Void)?
  private(set) var quoted: String?
  private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let heading = TextLabel(size: 12, color: Palette.accentBlue)
  private let block = ChatQuoteBlock()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    glass.cornerConfiguration = .uniformCorners(radius: 18)
    glass.translatesAutoresizingMaskIntoConstraints = false
    heading.text = String(localized: "orcaios.chat.quoting", defaultValue: "Quoting")
    let close = UIButton(
      configuration: {
        var configuration = UIButton.Configuration.plain()
        configuration.image = Lucide.x.image(size: 16, strokeWidth: 2)
        configuration.baseForegroundColor = Palette.textSecondary
        return configuration
      }(), primaryAction: UIAction { [weak self] _ in self?.onDismiss?() })
    close.accessibilityLabel = String(localized: "common.remove", defaultValue: "Remove")
    let column = UIStackView(arrangedSubviews: [heading, block])
    column.axis = .vertical
    column.spacing = 4
    column.translatesAutoresizingMaskIntoConstraints = false
    close.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    glass.contentView.addSubview(column)
    glass.contentView.addSubview(close)
    block.label(lines: 3)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Spacing.md + 2),
      column.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -Spacing.xs),
      column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: Spacing.sm + 2),
      column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Spacing.sm - 2),
      close.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -4),
      close.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 2),
      close.widthAnchor.constraint(equalToConstant: 40),
      close.heightAnchor.constraint(equalToConstant: 40),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ text: String?) {
    quoted = text
    block.show(text)
    isHidden = text == nil
  }
}

extension ChatQuoteBlock {
  /// How many lines the quote shows before it trails off.
  func label(lines: Int) {
    (subviews.last as? TextLabel)?.numberOfLines = lines
  }
}
