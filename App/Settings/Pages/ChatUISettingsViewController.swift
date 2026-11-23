import UIKit

/// Settings › Chat UI (settings/native-chat-settings-screen.tsx): chat text size, font and line spacing, and
/// whether agent sessions open as a chat. All kept on this phone; the text rows edit `ChatTextSettings`.
final class ChatUISettingsViewController: SettingsPageViewController {
  private let preview = ChatTextPreviewView()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.nativeChatSettingsScreen.title", defaultValue: "Chat UI")
    tableView.tableHeaderView = preview
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

/// A sample exchange in the chosen chat text settings: a question bubble, a tool line and an answer.
private final class ChatTextPreviewView: UIView {
  private let question = UILabel()
  private let bubble = UIView()
  private let tools = UILabel()
  private let answer = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    bubble.backgroundColor = Palette.chatUserSurface
    bubble.layer.cornerRadius = Radius.surface
    bubble.layer.cornerCurve = .continuous
    bubble.layer.borderWidth = 1
    bubble.layer.borderColor = Palette.chatUserBorder.cgColor
    for label in [question, tools, answer] {
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
    }
    tools.textColor = Palette.textSecondary
    answer.textColor = Palette.chatForegroundStrong
    question.textColor = Palette.textPrimary
    bubble.translatesAutoresizingMaskIntoConstraints = false
    bubble.addSubview(question)
    addSubview(bubble)
    addSubview(tools)
    addSubview(answer)
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
      answer.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: Spacing.sm),
      answer.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      answer.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      answer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
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
    let answerText = String(
      localized: "settings.nativeChatText.previewAnswer",
      defaultValue: "The test waits on `setTimeout(0)` while the stream is still flushing, so it passes only when the flush wins.")
    answer.attributedText = styled(answerText.replacingOccurrences(of: "`", with: ""), body)
  }
}
