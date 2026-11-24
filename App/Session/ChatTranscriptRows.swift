import OrcaCore
import UIKit

/// What the transcript draws, projected from the host's items:
/// - a turn still running, or one the reader opened, keeps every row in place: the agent's words where it
///   said them, consecutive tool calls as one activity line, consecutive thoughts as one line, changed files
///   as one card, and a question or approval as a line that opens its sheet;
/// - a finished turn that answered folds into "Worked for …" above its final answer.
enum ChatLine: Hashable {
  case user(id: String)
  case pending(id: String)
  /// A quiet divider in place of a message Orca sent itself, such as a new bot's first turn.
  case notice(id: String)
  /// "Worked for …" (folded or opened) or the running turn's clock.
  case work(turnKey: String)
  /// The agent's words; `final` carries the time and actions row.
  case answer(id: String)
  /// Consecutive tool calls, keyed by the first call; opens in place.
  case run(key: String)
  /// One call of an opened run.
  case call(id: String)
  /// The images a run's reads showed the agent, under its line (native-chat-tool-viewed-images.ts).
  case viewedImages(key: String)
  /// Consecutive thoughts, keyed by the first; opens in place.
  case thoughts(key: String)
  case thoughtText(id: String)
  /// Consecutive file edits as one card.
  case files(key: String)
  /// A question or approval: a line that opens its sheet.
  case prompt(id: String)
  /// A status or other note, in the muted style.
  case workItem(id: String)
  case subagent(itemId: String, agentId: String)
  case agentStarted(id: String)
  case agentMail(id: String)
  /// The running turn's last line.
  case working
}

struct ChatProjection {
  struct Run {
    var items: [TranscriptItem]
    var running: Bool
    var calls: [TranscriptItem.ToolCall] {
      items.compactMap { if case .toolCall(let call) = $0.body { call } else { nil } }
    }
  }

  var lines: [ChatLine] = []
  var items: [String: TranscriptItem] = [:]
  var pending: [String: PendingSend] = [:]
  /// Each turn's clock: worked seconds, whether it still runs, whether its work is folded away.
  var work: [String: (items: [TranscriptItem], seconds: Int?, running: Bool)] = [:]
  var folded: Set<String> = []
  var runs: [String: Run] = [:]
  /// Each run's viewed images, by run key.
  var viewedImages: [String: [String]] = [:]
  var thoughts: [String: (items: [TranscriptItem], seconds: Int?, live: Bool)] = [:]
  var files: [String: [ChangedFilesView.File]] = [:]
  /// Answers that end their turn: only these show the time and actions.
  var finalAnswers: Set<String> = []
  /// Questions and approvals still waiting, oldest first.
  var waiting: [String] = []

  init(
    rows: [ChatRow], expanded: Set<String>, openThoughts: Set<String> = [], openRuns: Set<String> = [],
    transcript: ChatTranscript, showsQuestionCalls: Bool = false
  ) {
    // Split the stream into turns: each starts at the person's message (or a pending send).
    struct Turn {
      var key: String
      var head: ChatLine?
      var items: [TranscriptItem] = []
      var seconds: Int?
      var quiet = false
    }
    var turns: [Turn] = []
    for row in rows {
      switch row {
      case .pending(let send):
        pending[send.id] = send
        turns.append(Turn(key: send.id, head: .pending(id: send.id)))
      case .item(let item):
        items[item.id] = item
        switch item.body {
        case .message(let message) where message.role == "user":
          let botCreated = message.origin == "bot-created"
          let head: ChatLine = message.agentSenders != nil ? .agentMail(id: item.id)
            : botCreated ? .notice(id: item.id) : .user(id: item.id)
          turns.append(Turn(key: item.id, head: head, quiet: botCreated))
        case .turn(let turn):
          if let duration = turn.durationMs, !turns.isEmpty {
            turns[turns.count - 1].seconds = max(1, Int((duration / 1000).rounded(.down)))
          }
        default:
          if turns.isEmpty { turns.append(Turn(key: item.id)) }
          turns[turns.count - 1].items.append(item)
        }
      }
    }

    for (index, turn) in turns.enumerated() {
      if let head = turn.head { lines.append(head) }
      let live = index == turns.count - 1 && transcript.isWorking
      let items = turn.items.filter(Self.draws).filter { item in
        if case .toolCall(let call) = item.body { return showsQuestionCalls || !ToolCategory.isAsk(call) }
        return true
      }
      func agentLines(_ item: TranscriptItem) -> [ChatLine] {
        switch item.body {
        case .message(let message) where message.agentSenders != nil:
          return [.agentMail(id: item.id)]
        case .message(let message):
          return message.subagents.map { .subagent(itemId: item.id, agentId: $0.id) }
        case .agentStarted:
          return [.agentStarted(id: item.id)]
        default:
          return []
        }
      }
      // A turn's answer is its last words that say something: a closing bare NO_REPLY (a bot with nothing
      // more to add) yields to what it said before, and only stands when it said nothing else.
      let answerIndex =
        items.lastIndex { Self.prose($0).map { !BotQuietResult.strip($0).words.isEmpty } ?? false }
        ?? items.lastIndex { Self.prose($0) != nil }
      let hasWork = items.indices.contains { $0 != answerIndex }
      var seconds = turn.seconds
      if seconds == nil, let first = items.first?.observedAt, let last = items.last?.observedAt, last > first {
        seconds = max(1, Int((last - first) / 1000))
      }

      // Orca's own setup turn shows only its answer.
      if turn.quiet, let answerIndex {
        lines.append(contentsOf: items.flatMap(agentLines))
        lines.append(.answer(id: items[answerIndex].id))
        finalAnswers.insert(items[answerIndex].id)
        continue
      }
      let folds = !live && answerIndex != nil && hasWork
      if folds {
        work[turn.key] = (items, seconds, false)
        lines.append(.work(turnKey: turn.key))
      }
      if folds && !expanded.contains(turn.key) {
        folded.insert(turn.key)
        // Folded, the images the turn's reads showed the agent still show, as the official folded turn keeps them.
        let calls = items.compactMap { item -> TranscriptItem.ToolCall? in
          if case .toolCall(let call) = item.body { return call }
          return nil
        }
        let shown = Self.viewedImagePaths(calls)
        if !shown.isEmpty {
          let key = turn.key + "#images"
          viewedImages[key] = shown
          lines.append(.viewedImages(key: key))
        }
        // Folded: what still waits on the person, then the answer.
        for item in items {
          lines.append(contentsOf: agentLines(item))
          if Self.isWaiting(item) {
            lines.append(.prompt(id: item.id))
            waiting.append(item.id)
          }
        }
        lines.append(.answer(id: items[answerIndex!].id))
        finalAnswers.insert(items[answerIndex!].id)
        continue
      }

      // In place: group consecutive calls, thoughts and edits.
      var runKey: String?
      var thoughtKey: String?
      var filesKey: String?
      let lastIndex = items.indices.last
      for (position, item) in items.enumerated() {
        let agentRows = agentLines(item)
        if !agentRows.isEmpty {
          runKey = nil
          thoughtKey = nil
          filesKey = nil
          lines.append(contentsOf: agentRows)
          if case .message(let message) = item.body, !message.isSubagentNotice,
            message.agentSenders == nil, !message.text.isEmpty {
            if Self.prose(item) != nil {
              lines.append(.answer(id: item.id))
              if !live && position == answerIndex { finalAnswers.insert(item.id) }
            } else {
              lines.append(.workItem(id: item.id))
            }
          }
          continue
        }
        switch item.body {
        case .toolCall:
          thoughtKey = nil
          filesKey = nil
          if let key = runKey {
            runs[key]?.items.append(item)
          } else {
            runKey = item.id
            runs[item.id] = Run(items: [item], running: false)
            lines.append(.run(key: item.id))
          }
          if live && position == lastIndex { runs[runKey!]?.running = true }
        case .message(let message) where message.role == "reasoning":
          runKey = nil
          filesKey = nil
          if let key = thoughtKey {
            thoughts[key]?.items.append(item)
          } else {
            thoughtKey = item.id
            thoughts[item.id] = ([item], nil, false)
            lines.append(.thoughts(key: item.id))
            if openThoughts.contains(item.id) { lines.append(.thoughtText(id: item.id)) }
          }
          if live && position == lastIndex { thoughts[thoughtKey!]?.live = true }
        case .diff(let path, let patch, let truncated):
          runKey = nil
          thoughtKey = nil
          let file = ChangedFilesView.File(path: path, patch: patch, truncated: truncated)
          if let key = filesKey {
            files[key]?.append(file)
          } else {
            filesKey = item.id
            files[item.id] = [file]
            lines.append(.files(key: item.id))
          }
        case .approval, .question:
          runKey = nil
          thoughtKey = nil
          filesKey = nil
          lines.append(.prompt(id: item.id))
          if Self.isWaiting(item) { waiting.append(item.id) }
        default:
          runKey = nil
          thoughtKey = nil
          filesKey = nil
          if let words = Self.prose(item) {
            // A bare NO_REPLY that isn't the turn's answer says nothing; it gets no row.
            if position != answerIndex, BotQuietResult.strip(words).words.isEmpty, BotQuietResult.strip(words).quiet { continue }
            lines.append(.answer(id: item.id))
            if !live && position == answerIndex { finalAnswers.insert(item.id) }
          } else {
            lines.append(.workItem(id: item.id))
          }
        }
      }
      // The running turn's last line spins; a thought or a call already spinning there says the same.
      if live {
        let tailSpins: Bool = {
          guard let last = items.last else { return false }
          switch last.body {
          case .toolCall: return true
          case .message(let message): return message.role == "reasoning"
          default: return false
          }
        }()
        if !tailSpins { lines.append(.working) }
      }
    }
    // A thought row's open text follows the whole group, not only its first member. Done once, after every
    // turn: inside the turn loop it re-inserted earlier turns' groups on each later turn.
    for (key, group) in thoughts where openThoughts.contains(key) && group.items.count > 1 {
      if let at = lines.firstIndex(of: .thoughtText(id: key)) {
        lines.insert(contentsOf: group.items.dropFirst().map { ChatLine.thoughtText(id: $0.id) }, at: at + 1)
      }
    }
    // What a run's reads showed the agent sits right under its line, without opening it.
    for (key, run) in runs {
      let paths = Self.viewedImagePaths(run.calls)
      guard !paths.isEmpty, let at = lines.firstIndex(of: .run(key: key)) else { continue }
      viewedImages[key] = paths
      lines.insert(.viewedImages(key: key), at: at + 1)
    }
    // An opened run lists its calls under it.
    for (key, run) in runs where openRuns.contains(key) {
      if let at = lines.firstIndex(of: .run(key: key)) {
        lines.insert(contentsOf: run.items.map { ChatLine.call(id: $0.id) }, at: at + 1)
      }
    }
    // The list's identities must be unique, or the data source throws; a line seen twice keeps its first place.
    var seen = Set<ChatLine>()
    var shownAgents = Set<String>()
    lines = lines.filter { line in
      if case .subagent(_, let id) = line { return shownAgents.insert(id).inserted }
      return seen.insert(line).inserted
    }
    // Thought seconds: from a group's first item to whatever follows it.
    for (key, group) in thoughts {
      guard let first = group.items.first, let last = group.items.last else { continue }
      let end = items.values.filter { $0.sequence > last.sequence || ($0.sequence == last.sequence && $0.sequenceIndex > last.sequenceIndex) }
        .map(\.observedAt).min() ?? last.observedAt
      thoughts[key]?.seconds = max(1, Int((end - first.observedAt) / 1000))
    }
  }

  /// The agent's words, when the item is prose.
  /// The raster file a successful read names (absolute path), else the images a call returned.
  static func viewedImagePaths(_ calls: [TranscriptItem.ToolCall]) -> [String] {
    let raster: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff"]
    var seen = Set<String>()
    var paths: [String] = []
    for call in calls {
      let path = ["file_path", "path"].lazy.compactMap { call.input[$0]?.stringValue }.first
      if ToolCategory.of(call) == .read, call.input["command"] == nil, let path, path.hasPrefix("/"),
        raster.contains((path as NSString).pathExtension.lowercased())
      {
        if call.state != "failed", call.state != "running", seen.insert(path).inserted { paths.append(path) }
      } else {
        for stored in call.outputImagePaths where seen.insert(stored).inserted { paths.append(stored) }
      }
    }
    return paths
  }

  static func prose(_ item: TranscriptItem) -> String? {
    guard case .message(let message) = item.body, message.role == "assistant",
      message.agentSenders == nil, !message.text.isEmpty else { return nil }
    return message.text
  }

  static func isWaiting(_ item: TranscriptItem) -> Bool {
    switch item.body {
    case .approval(let prompt), .question(let prompt): prompt.isPending
    default: false
    }
  }

  /// Rows that draw nothing are dropped before grouping, so they never split a run.
  private static func draws(_ item: TranscriptItem) -> Bool {
    switch item.body {
    case .message(let message):
      !message.subagents.isEmpty || message.agentSenders != nil || !message.text.isEmpty || !message.imagePaths.isEmpty
    case .other: false
    case .status(let text, _): !text.isEmpty
    default: true
    }
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
  /// The other actions, by their position after Copy (1 is the first after it).
  var onAction: ((Int) -> Void)?
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
      } else {
        button.addAction(UIAction { [weak self] _ in self?.onAction?(index) }, for: .primaryActionTriggered)
        button.accessibilityLabel = Self.label(icon)
      }
      addArrangedSubview(button)
    }
    if !trailing { addArrangedSubview(UIView()) }
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func set(time milliseconds: Double) { time.text = MessageClock.time(milliseconds) }

  private static func label(_ icon: Lucide) -> String {
    switch icon {
    case .reply: String(localized: "chat.messageActionsSheet.rewind", defaultValue: "Rewind to here")
    case .gitFork: String(localized: "chat.message.forkFromResponse", defaultValue: "Fork from this response")
    case .arrowUp: String(localized: "chat.message.scrollMessageToTop", defaultValue: "Scroll this message to top")
    default: ""
    }
  }

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
  private let quoted = ChatQuoteBlock()
  private let meta: MessageMetaView
  private let images = ChatImageStack()
  private var raw = ""
  /// Opens the message's image at that index in the viewer.
  var onOpenImage: ((Int) -> Void)? {
    didSet { images.onOpen = onOpenImage }
  }
  /// Rewind to here: the conversation drops this message and everything after it.
  var onRewind: (() -> Void)? {
    didSet { meta.onAction = { [weak self] _ in self?.onRewind?() } }
  }

  init(allowsRewind: Bool = true) {
    meta = MessageMetaView(trailing: true, actions: allowsRewind ? [.copy, .reply] : [.copy])
    super.init(frame: .zero)
    bubble.translatesAutoresizingMaskIntoConstraints = false
    bubble.backgroundColor = Palette.chatUserSurface
    bubble.layer.cornerRadius = Radius.surface
    bubble.layer.borderWidth = 1
    let column = UIStackView(arrangedSubviews: [quoted, text, images])
    column.axis = .vertical
    column.alignment = .leading
    column.spacing = Spacing.sm
    column.translatesAutoresizingMaskIntoConstraints = false
    bubble.addSubview(column)
    addSubview(bubble)
    addSubview(meta)
    meta.onCopy = { [weak self] in ChatClipboard.copy(self?.raw ?? "") }
    NSLayoutConstraint.activate([
      bubble.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.lg),
      bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.88, constant: -Spacing.lg * 2 * 0.88),
      // The 1 pt border takes room inside the box, as it does in React Native's layout.
      column.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Spacing.md + 1),
      column.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Spacing.md - 1),
      column.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Spacing.sm + 1),
      column.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Spacing.sm - 1),
      meta.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
      meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg + 5),
      meta.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(
    text value: String, images sources: [ImageViewerController.Source] = [], at time: Double?, sending: Bool
  ) {
    raw = value
    // A quote it opens with draws as its own block over the words.
    let parts = ChatQuote.split(value)
    quoted.show(parts.quote)
    text.styledText = ChatMarkdown.linkingPaths(ChatMarkdown.inline(parts.body, color: Palette.chatForegroundStrong))
    text.isHidden = parts.body.isEmpty
    images.show(sources)
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
    rails = TimelineRails(in: self, iconSize: 14, centeredOn: icon.centerYAnchor)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var rails: TimelineRails?

  /// Joins this note to the activity above and below it.
  func connect(up: Bool, down: Bool) { rails?.show(up: up, down: down) }

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

/// The agent's answer, rendered by MarkdownView, then its time, Copy, Fork and Scroll-to-top.
final class AnswerView: UIView {
  private let body = ChatAnswerMarkdownView()
  private let meta: MessageMetaView
  /// The time and actions row ends the view once the turn is over; mid-turn the words end it, so a hidden
  /// row leaves no gap before the next activity.
  private lazy var metaAtBottom = meta.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm)
  private lazy var bodyAtBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm)
  private var raw = ""
  /// A tapped link or file path in the answer.
  var onOpenURL: ((URL) -> Void)? {
    didSet { body.onOpenURL = onOpenURL }
  }
  var onOpenPath: ((String) -> Void)? {
    didSet { body.onOpenPath = onOpenPath }
  }
  /// Type out what arrives (see ChatAnswerMarkdownView.reveals).
  var reveals: Bool {
    get { body.reveals }
    set { body.reveals = newValue }
  }
  var onRevealFinished: (() -> Void)? {
    didSet { body.onRevealFinished = onRevealFinished }
  }
  var isRevealing: Bool { body.isRevealing }

  /// Selected words, sent to the composer as a quote.
  var onQuote: ((String) -> Void)? {
    didSet { body.onQuote = onQuote }
  }
  var onFork: (() -> Void)?
  var onScrollToTop: (() -> Void)?
  /// The streamed text grew a line: the row should re-measure.
  var onHeightChange: (() -> Void)? {
    didSet { body.onHeightChange = onHeightChange }
  }

  init(allowsFork: Bool = true) {
    meta = MessageMetaView(trailing: false, actions: allowsFork ? [.copy, .gitFork, .arrowUp] : [.copy, .arrowUp])
    super.init(frame: .zero)
    body.translatesAutoresizingMaskIntoConstraints = false
    addSubview(body)
    addSubview(meta)
    meta.onCopy = { [weak self] in ChatClipboard.copy(self?.raw ?? "") }
    meta.onAction = { [weak self] index in
      if allowsFork && index == 1 { self?.onFork?() } else { self?.onScrollToTop?() }
    }
    NSLayoutConstraint.activate([
      body.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      meta.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 2),
      meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      metaAtBottom,
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// `width` is the row's: the text wraps inside its margins, measured before the row is laid out.
  func show(markdown: String, id: String, at time: Double, streaming: Bool, width: CGFloat) {
    raw = markdown
    body.setWidth(width - Spacing.lg * 2)
    body.show(markdown, streaming: streaming, identity: id)
    meta.set(time: time)
    meta.isHidden = streaming
    // Release one end before taking the other, so the two never hold at once.
    (streaming ? metaAtBottom : bodyAtBottom).isActive = false
    (streaming ? bodyAtBottom : metaAtBottom).isActive = true
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

/// bot-quiet-result.ts: a bot's answer that ends with NO_REPLY had nothing worth reporting. The marker never
/// shows; an answer that was only the marker reads "Nothing to report".
enum BotQuietResult {
  static let marker = "NO_REPLY"
  private static let ending = try! NSRegularExpression(pattern: "(?:^|\\s)[`*_]*NO_REPLY[`*_.!]*\\s*$")

  /// The words without their trailing marker(s), and whether there was one.
  static func strip(_ text: String) -> (words: String, quiet: Bool) {
    var words = text
    var quiet = false
    while let match = ending.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
      let range = Range(match.range, in: words)
    {
      quiet = true
      words = String(words[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return (words, quiet)
  }
}

enum ChatClipboard {
  /// Copy writes plain text and Markdown, so pasting back into the composer keeps formatting.
  static func copy(_ markdown: String) {
    UIPasteboard.general.items = [["public.utf8-plain-text": markdown, "net.daringfireball.markdown": Data(markdown.utf8)]]
  }
}
