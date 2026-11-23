import OrcaCore
import UIKit

/// What the transcript draws, projected from the host's items: each turn becomes the user's message, one
/// "Worked for …" row holding everything the agent did, and the agent's final answer.
enum ChatLine: Hashable {
  case user(id: String)
  case work(turnKey: String)
  case workItem(id: String)
  case answer(id: String)
  case pending(id: String)
  case prompt(id: String)
  /// A quiet divider in place of a message Orca sent itself, such as a new bot's first turn.
  case notice(id: String)
}

struct ChatProjection {
  var lines: [ChatLine] = []
  var items: [String: TranscriptItem] = [:]
  var pending: [String: PendingSend] = [:]
  /// The work rows' contents and summary, by turn.
  var work: [String: (items: [TranscriptItem], seconds: Int?, running: Bool)] = [:]

  init(rows: [ChatRow], expanded: Set<String>, transcript: ChatTranscript) {
    var currentWork: [TranscriptItem] = []
    var turnKey: String?
    var turnStart: Double?
    var answer: TranscriptItem?
    var reportedSeconds: [String: Int] = [:]
    // Turns whose work stays out of sight: Orca's own setup turn shows only its answer.
    var quietTurns: Set<String> = []

    func closeTurn(running: Bool) {
      guard let key = turnKey else { return }
      let end = answer?.observedAt ?? currentWork.last?.observedAt
      var seconds: Int?
      if let turnStart, let end { seconds = Int(max(1, (end - turnStart) / 1000)) }
      if !quietTurns.contains(key), !currentWork.isEmpty || answer != nil || running {
        work[key] = (currentWork, reportedSeconds[key] ?? seconds, running)
        lines.append(.work(turnKey: key))
        if expanded.contains(key) { lines += currentWork.map { .workItem(id: $0.id) } }
      }
      if let answer { lines.append(.answer(id: answer.id)) }
      turnKey = nil
      currentWork = []
      answer = nil
    }

    for row in rows {
      switch row {
      case .pending(let send):
        closeTurn(running: false)
        pending[send.id] = send
        lines.append(.pending(id: send.id))
      case .item(let item):
        items[item.id] = item
        switch item.body {
        case .message(let message) where message.role == "user" && message.origin == "bot-created":
          closeTurn(running: false)
          lines.append(.notice(id: item.id))
          turnKey = item.id
          quietTurns.insert(item.id)
          turnStart = nil
        case .message(let message) where message.role == "user":
          closeTurn(running: false)
          lines.append(.user(id: item.id))
          turnKey = item.id
          // Work is timed from the agent's first item, not from the message that asked for it.
          turnStart = nil
        case .approval, .question:
          closeTurn(running: false)
          lines.append(.prompt(id: item.id))
        case .message(let message) where message.role == "assistant" && !message.text.isEmpty:
          // Only the last assistant message of a turn is its answer; earlier ones are work.
          if let previous = answer { currentWork.append(previous) }
          answer = item
          if turnStart == nil { turnStart = item.observedAt }
          if turnKey == nil {
            turnKey = item.id
            turnStart = item.observedAt
          }
        case .turn(let turn):
          // The host's own measure of the turn wins over the gap between its first and last item.
          if let duration = turn.durationMs, let key = turnKey { reportedSeconds[key] = max(1, Int((duration / 1000).rounded(.down))) }
          continue
        default:
          if turnKey == nil { turnKey = item.id }
          if turnStart == nil { turnStart = item.observedAt }
          currentWork.append(item)
        }
      }
    }
    closeTurn(running: transcript.isWorking)
  }
}

private enum MessageClock {
  static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  static func time(_ milliseconds: Double) -> String {
    formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
  }
}

/// Small 44 pt icon buttons after a message's time (messages/MobileNativeChatMessageMeta.tsx).
final class MessageMetaView: UIStackView {
  var onCopy: (() -> Void)?
  private let time = TextLabel(size: Typography.metaSize + 1, color: Palette.textMuted, tabular: true)
  private var copyButton: UIButton!

  init(trailing: Bool, actions: [Lucide]) {
    super.init(frame: .zero)
    axis = .horizontal
    alignment = .center
    spacing = 0
    translatesAutoresizingMaskIntoConstraints = false
    if trailing { addArrangedSubview(UIView()) }
    addArrangedSubview(time)
    setCustomSpacing(4, after: time)
    for (index, icon) in actions.enumerated() {
      let button = UIButton(configuration: .plain())
      button.configuration?.image = icon.image(size: 16, strokeWidth: 2)
      button.configuration?.baseForegroundColor = Palette.textMuted
      button.configuration?.contentInsets = .init(top: 6, leading: 5, bottom: 6, trailing: 5)
      if index == 0 {
        copyButton = button
        button.addAction(UIAction { [weak self] _ in self?.copied() }, for: .primaryActionTriggered)
        button.accessibilityLabel = String(localized: "common.copy", defaultValue: "Copy")
      }
      addArrangedSubview(button)
    }
    if !trailing { addArrangedSubview(UIView()) }
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func set(time milliseconds: Double) { time.text = MessageClock.time(milliseconds) }

  /// Copy feedback is inline; the glyph turns into a check for 1.6 s.
  private func copied() {
    onCopy?()
    let original = copyButton.configuration?.image
    copyButton.configuration?.image = Lucide.check.image(size: 16, strokeWidth: 2.2)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
      self?.copyButton.configuration?.image = original
    }
  }
}

/// The user's message: a bubble on the right with its time, Copy and Reply under it.
final class UserMessageView: UIView {
  private let bubble = UIView()
  private let text = TextLabel(size: ChatProse.bodySize, lines: 0)
  private let meta = MessageMetaView(trailing: true, actions: [.copy, .reply])
  private var raw = ""

  init() {
    super.init(frame: .zero)
    bubble.translatesAutoresizingMaskIntoConstraints = false
    bubble.backgroundColor = Palette.chatUserSurface
    bubble.layer.cornerRadius = Radius.surface
    bubble.layer.borderWidth = 1
    bubble.addSubview(text)
    addSubview(bubble)
    addSubview(meta)
    meta.onCopy = { [weak self] in ChatClipboard.copy(self?.raw ?? "") }
    NSLayoutConstraint.activate([
      bubble.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.lg),
      bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.88, constant: -Spacing.lg * 2 * 0.88),
      // The 1 pt border takes room inside the box, as it does in React Native's layout.
      text.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Spacing.md + 1),
      text.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Spacing.md - 1),
      text.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Spacing.sm + 1),
      text.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Spacing.sm - 1),
      meta.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
      meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg + 5),
      meta.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(text value: String, at time: Double?, sending: Bool) {
    raw = value
    text.styledText = ChatMarkdown.linkingPaths(ChatMarkdown.inline(value, color: Palette.chatForegroundStrong))
    if let time { meta.set(time: time) }
    meta.isHidden = time == nil
    bubble.alpha = sending ? 0.6 : 1
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    updateColors()
  }

  private func updateColors() {
    bubble.layer.borderColor = Palette.chatUserBorder.resolvedColor(with: traitCollection).cgColor
  }
}

/// "Worked for 12s ›" (transcript/tool-results): the agent's work folded into one row, a hairline under it.
/// A label across the transcript between two hairlines (MobileNativeChatDivider.tsx).
final class NoticeDividerView: UIView {
  private let label = TextLabel(size: Typography.metaSize, color: Palette.textMuted)

  init() {
    super.init(frame: .zero)
    let left = Hairline()
    let right = Hairline()
    for view in [left, label, right] as [UIView] { addSubview(view) }
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.lg),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.lg),
      left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -Spacing.md),
      left.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Spacing.md),
      right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      right.centerYAnchor.constraint(equalTo: label.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ text: String) {
    label.text = text
    accessibilityLabel = text
    isAccessibilityElement = true
  }
}

final class WorkSummaryView: UIView {
  private let label = TextLabel(size: Typography.bodySize, color: Palette.textSecondary)
  private let chevron = LucideView(.chevronRight, size: 14, strokeWidth: 2, color: Palette.textSecondary)
  private let spinner = UIActivityIndicatorView(style: .medium)

  init() {
    super.init(frame: .zero)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
    let line = Hairline()
    for view in [spinner, label, chevron, line] as [UIView] { addSubview(view) }
    NSLayoutConstraint.activate([
      spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg - 4),
      spinner.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
      chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Spacing.sm),
      chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      line.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Spacing.md),
      line.leadingAnchor.constraint(equalTo: leadingAnchor),
      line.trailingAnchor.constraint(equalTo: trailingAnchor),
      line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(seconds: Int?, running: Bool, expanded: Bool) {
    if running {
      spinner.startAnimating()
      label.text = String(localized: "chat.turnStatus.working", defaultValue: "Working…")
    } else {
      spinner.stopAnimating()
      label.text = String(
        format: String(localized: "chat.turnStatus.workedFor", defaultValue: "Worked for %1$@"),
        Self.duration(seconds ?? 1))
    }
    label.transform = running ? CGAffineTransform(translationX: 22, y: 0) : .identity
    chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
    chevron.isHidden = running
    // A reused cell can arrive from the other state; lay the chevron out against the new text.
    setNeedsLayout()
  }

  /// formatMobileNativeChatDuration: "12s", "3m 4s", "1h 2m 3s" in the official copy.
  static func duration(_ seconds: Int) -> String {
    if seconds < 60 {
      return String(format: String(localized: "chat.turnStatus.seconds", defaultValue: "%1$lld s"), seconds)
    }
    let minutes = seconds / 60
    if minutes < 60 {
      return String(
        format: String(localized: "chat.turnStatus.minutesSeconds", defaultValue: "%1$@m %2$@s"), "\(minutes)",
        "\(seconds % 60)")
    }
    return String(
      format: String(localized: "chat.turnStatus.hoursMinutesSeconds", defaultValue: "%1$@h %2$@m %3$@s"),
      "\(minutes / 60)", "\(minutes % 60)", "\(seconds % 60)")
  }
}

/// A folded work entry once opened: a tool call, a note, or a passing message, in the muted meta style.
final class WorkItemView: UIView {
  private let icon = LucideView(.squareTerminal, size: 14, strokeWidth: 2, color: Palette.textMuted)
  private let label = TextLabel(size: Typography.bodySize, color: Palette.textSecondary, lineHeight: 20, lines: 3)

  init() {
    super.init(frame: .zero)
    addSubview(icon)
    addSubview(label)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      icon.topAnchor.constraint(equalTo: label.topAnchor, constant: 3),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Spacing.sm),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ item: TranscriptItem) {
    switch item.body {
    case .toolCall(let call):
      icon.icon = call.name.lowercased().contains("bash") ? .squareTerminal : .wrench
      label.text = [call.name, call.summary].filter { !$0.isEmpty }.joined(separator: "  ")
    case .message(let message) where message.role == "reasoning":
      icon.icon = .brain
      label.text = message.text
    case .message(let message):
      icon.icon = .messageSquareText
      label.text = message.text
    case .diff(let path, _, _):
      icon.icon = .filePen
      label.text = path
    case .status(let text, _):
      icon.icon = .info
      label.text = text
    default:
      icon.icon = .circleDot
      label.text = ""
    }
  }
}

/// The agent's answer as Markdown blocks, then its time, Copy, Fork and Scroll-to-top.
final class AnswerView: UIView {
  private let blocks = UIStackView()
  private let meta = MessageMetaView(trailing: false, actions: [.copy, .gitFork, .arrowUp])
  private var raw = ""

  init() {
    super.init(frame: .zero)
    blocks.axis = .vertical
    blocks.spacing = Spacing.sm
    blocks.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blocks)
    addSubview(meta)
    meta.onCopy = { [weak self] in ChatClipboard.copy(self?.raw ?? "") }
    NSLayoutConstraint.activate([
      blocks.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      blocks.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      blocks.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      meta.topAnchor.constraint(equalTo: blocks.bottomAnchor, constant: 2),
      meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      meta.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(markdown: String, at time: Double, streaming: Bool) {
    raw = markdown
    blocks.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for block in ChatMarkdown.render(markdown) {
      switch block {
      case .text(let text):
        let label = TextLabel(size: ChatProse.bodySize, lines: 0)
        label.styledText = text
        blocks.addArrangedSubview(label)
      case .code(_, let code):
        blocks.addArrangedSubview(CodeBlockView(code: code))
      case .rule:
        blocks.addArrangedSubview(Hairline())
      }
    }
    meta.set(time: time)
    meta.isHidden = streaming
  }
}

/// A fenced code block: Menlo 12 × 1.25 on the raised fill, scrolling sideways.
final class CodeBlockView: UIView {
  init(code: String) {
    super.init(frame: .zero)
    backgroundColor = Palette.bgRaised
    layer.cornerRadius = Radius.control
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    let label = TextLabel(size: ChatProse.codeSize, lines: 0)
    label.font = Typography.mono(ChatProse.codeSize)
    label.lineHeight = 17 * ChatProse.scale
    label.text = code
    addSubview(scroll)
    scroll.addSubview(label)
    scroll.pin(to: self)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Spacing.md),
      label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Spacing.md),
      label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.md),
      label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.md),
      label.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -Spacing.md * 2),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum ChatClipboard {
  /// Copy writes plain text and Markdown, so pasting back into the composer keeps formatting.
  static func copy(_ markdown: String) {
    UIPasteboard.general.items = [["public.utf8-plain-text": markdown, "net.daringfireball.markdown": Data(markdown.utf8)]]
  }
}
