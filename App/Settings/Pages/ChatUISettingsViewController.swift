import UIKit

/// Settings › Chat UI (settings/native-chat-settings-screen.tsx): chat text size, font and line spacing, and
/// whether agent sessions open as a chat. All kept on this phone; the text rows edit `ChatTextSettings`.
final class ChatUISettingsViewController: SettingsPageViewController {
  private let preview = ChatTextPreviewView()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.nativeChatSettingsScreen.title", defaultValue: "Chat UI")
    tableView.tableHeaderView = preview
    preview.onHeightChange = { [weak self] in self?.resizePreview() }
    rebuild()
    // A pinch in a chat or the session's Text size sheet changes the same values.
    NotificationCenter.default.addObserver(forName: ChatTextSettings.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.rebuildIfIdle() }
    }
  }

  /// Rebuilds unless a slider drag is under way, which a reload would cut off.
  private func rebuildIfIdle() {
    guard !tableView.isTracking else { return }
    rebuild()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    resizePreview()
  }

  private func resizePreview() {
    let width = tableView.bounds.width
    guard width > 0 else { return }
    preview.prepare(width: width)
    let height = preview.systemLayoutSizeFitting(
      CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
    ).height
    if abs(preview.frame.height - height) > 0.5 || preview.frame.width != width {
      preview.frame = CGRect(x: 0, y: 0, width: width, height: height)
      tableView.tableHeaderView = preview
    }
  }

  private func rebuild() {
    let text = ChatTextSettings.current
    preview.apply(text)
    resizePreview()
    let spacing = ChatTextSettings.Spacing.allCases
    let chatDefault = PhoneSettings.openSessionsInChat
    sections = [
      Section(
        header: String(localized: "settings.nativeChatText.heading", defaultValue: "TEXT"),
        footer: String(localized: "settings.nativeChatText.footer", defaultValue: "Pinch in a chat to change it; it saves here."),
        rows: [
          .slider(
            title: String(localized: "settings.nativeChatText.size", defaultValue: "Text size"),
            value: text.sizeLabel,
            range: Double(ChatTextSettings.minSize)...Double(ChatTextSettings.maxSize),
            current: Double(text.size), stepper: false,
            onPreview: { [weak self] next in
              var draft = ChatTextSettings.current
              draft.size = Int(next)
              self?.preview.apply(draft)
              self?.resizePreview()
              return draft.sizeLabel
            },
            onCommit: { [weak self] next in
              var settings = ChatTextSettings.current
              if settings.size != Int(next) {
                settings.size = Int(next)
                ChatTextSettings.current = settings
              }
              self?.rebuild()
            }),
          .menu(
            title: String(localized: "settings.nativeChatText.font", defaultValue: "Font"),
            value: ChatTextSettings.fontName(text.font),
            options: ChatTextSettings.Font.allCases.map { choice in
              Option(title: ChatTextSettings.fontName(choice), subtitle: Self.subtitle(choice), selected: choice == text.font) {
                var settings = ChatTextSettings.current
                settings.font = choice
                ChatTextSettings.current = settings
              }
            }),
          .segmented(
            title: String(localized: "settings.nativeChatText.lineSpacing", defaultValue: "Line spacing"),
            items: spacing.map(ChatTextSettings.spacingName),
            selected: spacing.firstIndex(of: text.lineSpacing) ?? 1,
            onChange: { index in
              var settings = ChatTextSettings.current
              settings.lineSpacing = spacing[index]
              ChatTextSettings.current = settings
            }),
        ]),
      Section(
        header: String(localized: "settings.nativeChatSettingsScreen.defaultViewHeading", defaultValue: "DEFAULT VIEW"),
        footer: String(
          localized: "settings.nativeChatSettingsScreen.defaultViewDescription",
          defaultValue:
            "Choose how supported agent sessions (Claude, Codex, and other chat-capable agents) open on this device. Terminal shows the raw CLI; Chat UI shows a chat interface like the desktop app. You can still switch any individual session from its long-press menu."
        ),
        rows: [
          .toggle(
            title: String(localized: "settings.nativeChatSettingsScreen.openInChatUi", defaultValue: "Open sessions in Chat UI"),
            subtitle: chatDefault
              ? String(localized: "settings.nativeChatSettingsScreen.on", defaultValue: "On")
              : String(localized: "settings.nativeChatSettingsScreen.off", defaultValue: "Off"),
            isOn: chatDefault,
            onChange: { [weak self] on in
              PhoneSettings.openSessionsInChat = on
              self?.rebuild()
            })
        ]),
      Section(rows: [
        .button(
          title: String(localized: "settings.nativeChatText.reset", defaultValue: "Reset text settings"),
          enabled: text != ChatTextSettings()
        ) {
          ChatTextSettings.current = ChatTextSettings()
        }
      ]),
    ]
  }

  private static func subtitle(_ font: ChatTextSettings.Font) -> String {
    switch font {
    case .system: "SF Pro"
    case .serif: "New York"
    case .mono: String(localized: "settings.nativeChatText.fontMonoSubtitle", defaultValue: "Same as code")
    }
  }
}

/// A sample exchange in the chosen chat text settings (native-chat-text-preview.tsx): a question bubble, a
/// tool line, then an answer with a code block, drawn by the chat's own answer renderer.
private final class ChatTextPreviewView: UIView {
  private static let code = "```ts\nawait vi.waitFor(() =>\n  expect(rows).toHaveLength(3))\n```"
  private static let margin: CGFloat = 20

  var onHeightChange: (() -> Void)?
  private let question = UILabel()
  private let bubble = UIView()
  private let tools = UILabel()
  private let answerSlot = UIView()
  private var answer = ChatAnswerMarkdownView()
  /// The saved settings the answer was drawn in. The renderer reads the saved settings, so a slider drag
  /// shows in the answer once it is let go.
  private var answerSettings: ChatTextSettings?
  private var answerWidth: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    preservesSuperviewLayoutMargins = false
    directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: Self.margin, bottom: 0, trailing: Self.margin)
    accessibilityElementsHidden = true
    bubble.backgroundColor = Palette.chatUserSurface
    bubble.layer.cornerRadius = Radius.surface
    bubble.layer.cornerCurve = .continuous
    bubble.layer.borderWidth = 1
    bubble.layer.borderColor = Palette.chatUserBorder.cgColor
    for label in [question, tools] {
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
    }
    tools.textColor = Palette.textSecondary
    question.textColor = Palette.textPrimary
    answerSlot.translatesAutoresizingMaskIntoConstraints = false
    bubble.translatesAutoresizingMaskIntoConstraints = false
    bubble.addSubview(question)
    addSubview(bubble)
    addSubview(tools)
    addSubview(answerSlot)
    NSLayoutConstraint.activate([
      bubble.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
      bubble.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      bubble.leadingAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.leadingAnchor, constant: 48),
      question.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Spacing.sm + 2),
      question.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -(Spacing.sm + 2)),
      question.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Spacing.md),
      question.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Spacing.md),
      tools.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: Spacing.md),
      tools.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      tools.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      answerSlot.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: Spacing.sm),
      answerSlot.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      answerSlot.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      answerSlot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
    ])
    question.text = String(localized: "settings.nativeChatText.previewQuestion", defaultValue: "Why is the resume test flaky?")
    tools.text = String(localized: "settings.nativeChatText.previewTools", defaultValue: "Read 3 files · Ran pnpm test")
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.setNeedsLayout() }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    bubble.layer.borderColor = Palette.chatUserBorder.resolvedColor(with: traitCollection).cgColor
  }

  func apply(_ settings: ChatTextSettings) {
    let size = CGFloat(settings.size)
    let spacing = settings.lineFactor
    let body = settings.bodyFont(ofSize: size)
    func styled(_ text: String, _ font: UIFont) -> NSAttributedString {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineHeightMultiple = spacing * 1.15
      return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
    }
    question.attributedText = styled(question.text ?? "", body)
    tools.font = .systemFont(ofSize: size * 13 / 14)
    showAnswer()
  }

  /// The answer's wrap width, set before the header is measured so its height is known up front.
  func prepare(width: CGFloat) {
    answerWidth = width - Self.margin * 2
    answer.setWidth(answerWidth)
  }

  private func showAnswer() {
    let saved = ChatTextSettings.current
    guard saved != answerSettings else { return }
    answerSettings = saved
    // The renderer keeps what it drew when only the settings change, so new settings get a new one.
    answer.removeFromSuperview()
    answer = ChatAnswerMarkdownView()
    answer.isUserInteractionEnabled = false
    answer.onHeightChange = { [weak self] in self?.onHeightChange?() }
    answer.translatesAutoresizingMaskIntoConstraints = false
    answerSlot.addSubview(answer)
    NSLayoutConstraint.activate([
      answer.topAnchor.constraint(equalTo: answerSlot.topAnchor),
      answer.bottomAnchor.constraint(equalTo: answerSlot.bottomAnchor),
      answer.leadingAnchor.constraint(equalTo: answerSlot.leadingAnchor),
      answer.trailingAnchor.constraint(equalTo: answerSlot.trailingAnchor),
    ])
    if answerWidth > 0 { answer.setWidth(answerWidth) }
    let prose = String(
      localized: "settings.nativeChatText.previewAnswer",
      defaultValue: "The test waits on `setTimeout(0)` while the stream is still flushing, so it passes only when the flush wins.")
    answer.show("\(prose)\n\n\(Self.code)", streaming: false, identity: "settings.preview")
  }
}
