import UIKit

/// The terminal's resting controls (session/MobileSessionCommandDock.tsx) while the keyboard is down: a row of
/// keys, then the Live input field with image and dictation. Native glass; the keyboard's own key bar takes
/// over while it is up.
final class TerminalDock: UIView {
  var onKey: ((String) -> Void)?
  /// What the Paste key read: text, or an image's data.
  var onPasteText: ((String) -> Void)?
  var onPasteImage: ((Data) -> Void)?
  var onShowKeyboard: (() -> Void)?
  var onImage: (() -> Void)?
  /// Dictated words, sent to the terminal when listening stops.
  var onDictated: ((String) -> Void)?
  var onError: ((String) -> Void)?
  private var micButton: UIButton?
  private var heard = ""

  /// Shift, Ctrl and Alt armed for the next key, from this row or the keyboard (terminal-dock-styles.ts keyLatched).
  enum Modifier: CaseIterable { case shift, ctrl, alt }
  private var latched: Set<Modifier> = [] { didSet { drawLatches() } }
  private var modifierKeys: [Modifier: UIButton] = [:]

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Palette.bgPanel

    // The key row: a fixed keyboard key, then the keys, scrolling sideways when they don't fit.
    let keyboard = Self.key(nil, icon: .keyboard) { [weak self] in self?.onShowKeyboard?() }
    keyboard.accessibilityLabel = String(localized: "session.commandDock.tapToShowKeyboard", defaultValue: "Tap to show keyboard")
    let keys = UIStackView()
    keys.spacing = Spacing.sm
    keys.alignment = .center
    for (title, action) in [
      // Reading the clipboard asks the system's Allow Paste first, as the official key does.
      ("Paste", { [weak self] in self?.pasteClipboard() }),
      ("Esc", { [weak self] in self?.press("\u{1b}") }),
      ("Tab", { [weak self] in self?.press("\t") }),
    ] as [(String, () -> Void)] {
      keys.addArrangedSubview(Self.key(title, action: action))
    }
    // A modifier arms for the next key, here or typed; tapping it again disarms it.
    for (modifier, title) in [(Modifier.shift, "Shift"), (.ctrl, "Ctrl"), (.alt, "Alt")] {
      let key = Self.key(title) { [weak self] in self?.toggle(modifier) }
      key.configurationUpdateHandler = { [weak self] button in
        guard let self else { return }
        let on = self.latched.contains(modifier)
        button.configuration?.background.strokeColor = on ? Palette.textPrimary : .clear
        button.configuration?.background.strokeWidth = on ? 1 : 0
        button.accessibilityTraits = on ? [.button, .selected] : .button
      }
      modifierKeys[modifier] = key
      keys.addArrangedSubview(key)
    }
    let scroll = UIScrollView()
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = true
    scroll.addSubview(keys)
    keys.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
    ])
    keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor).isActive = true
    let keyRow = UIStackView(arrangedSubviews: [keyboard, scroll])
    keyRow.spacing = Spacing.sm
    keyRow.alignment = .center
    keyRow.isLayoutMarginsRelativeArrangement = true
    keyRow.directionalLayoutMargins = .init(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm)

    let field = UIButton(configuration: .glass())
    var configuration = field.configuration!
    configuration.background.cornerRadius = Radius.control
    configuration.cornerStyle = .fixed
    configuration.image = Lucide.keyboard.image(size: 17, strokeWidth: 2)
    configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in Palette.textSecondary }
    configuration.imagePadding = Spacing.md
    configuration.baseForegroundColor = Palette.textPrimary
    configuration.attributedTitle = AttributedString(
      String(localized: "session.terminalLiveInputStatus.liveInput", defaultValue: "Live input"),
      attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 11, weight: .semibold)]))
    configuration.attributedSubtitle = AttributedString(
      String(localized: "session.commandDock.tapToShowKeyboard", defaultValue: "Tap to show keyboard"),
      attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15), .foregroundColor: Palette.textMuted]))
    configuration.titlePadding = 0
    configuration.titleAlignment = .leading
    configuration.contentInsets = .init(top: 4, leading: 12, bottom: 4, trailing: 12)
    field.configuration = configuration
    field.contentHorizontalAlignment = .leading
    field.addAction(UIAction { [weak self] _ in self?.onShowKeyboard?() }, for: .primaryActionTriggered)

    let image = Self.round(.imagePlus, label: String(localized: "chat.composer.attach", defaultValue: "Attach")) { [weak self] in
      self?.onImage?()
    }
    let mic = Self.round(.mic, label: String(localized: "chat.composer.dictate", defaultValue: "Dictate")) {}
    mic.addAction(UIAction { [weak self] _ in self?.toggleDictation() }, for: .primaryActionTriggered)
    micButton = mic
    let inputRow = UIStackView(arrangedSubviews: [field, image, mic])
    inputRow.spacing = Spacing.sm
    inputRow.alignment = .center
    inputRow.isLayoutMarginsRelativeArrangement = true
    inputRow.directionalLayoutMargins = .init(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md)

    let divider = Hairline(color: Palette.borderSubtle)
    let column = UIStackView(arrangedSubviews: [divider, keyRow, inputRow])
    column.axis = .vertical
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: topAnchor),
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.trailingAnchor.constraint(equalTo: trailingAnchor),
      column.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
      keyRow.heightAnchor.constraint(equalToConstant: 46),
      scroll.heightAnchor.constraint(equalTo: keyRow.heightAnchor),
      field.heightAnchor.constraint(equalToConstant: 44),
      image.widthAnchor.constraint(equalToConstant: 38), image.heightAnchor.constraint(equalToConstant: 38),
      mic.widthAnchor.constraint(equalToConstant: 38), mic.heightAnchor.constraint(equalToConstant: 38),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func pasteClipboard() {
    let pasteboard = UIPasteboard.general
    if pasteboard.hasImages, !pasteboard.hasStrings, let data = pasteboard.image?.pngData() {
      onPasteImage?(data)
    } else if let text = pasteboard.string, !text.isEmpty {
      onPasteText?(text)
    }
  }

  private func toggleDictation() {
    let dictation = Dictation.shared
    if dictation.isListening {
      dictation.stop()
      return
    }
    heard = ""
    setListening(true)
    Task {
      let refusal = await dictation.start(
        onText: { [weak self] text in self?.heard = text },
        onEnd: { [weak self] in
          guard let self else { return }
          self.setListening(false)
          let text = self.heard.trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty { self.onDictated?(text) }
        })
      if let refusal {
        setListening(false)
        onError?(refusal)
      }
    }
  }

  private func setListening(_ listening: Bool) {
    micButton?.configuration?.image = Lucide.mic.image(size: 17, strokeWidth: 2.4)
    micButton?.configuration?.baseForegroundColor = listening ? Palette.statusRed : Palette.textSecondary
  }

  private func toggle(_ modifier: Modifier) {
    if latched.contains(modifier) { latched.remove(modifier) } else { latched.insert(modifier) }
  }

  private func drawLatches() {
    for key in modifierKeys.values { key.setNeedsUpdateConfiguration() }
  }

  private func press(_ text: String) { onKey?(apply(text)) }

  /// The armed modifiers applied to one key's text, then disarmed: Ctrl makes a control character, Alt
  /// prefixes Escape, Shift upper-cases (and turns Tab into back-tab). Longer text, such as a paste, passes
  /// unchanged and leaves them armed.
  func apply(_ text: String) -> String {
    guard !latched.isEmpty, text.unicodeScalars.count == 1 else { return text }
    var out = text
    if latched.contains(.shift) { out = text == "\t" ? "\u{1b}[Z" : out.uppercased() }
    if latched.contains(.ctrl), let first = out.unicodeScalars.first, out.unicodeScalars.count == 1 {
      let value = first.value
      switch value {
      case 0x61...0x7a: out = String(UnicodeScalar(UInt8(value - 0x60)))  // a–z
      case 0x40...0x5f: out = String(UnicodeScalar(UInt8(value & 0x1f)))  // @ A–Z [ \ ] ^ _
      case 0x20: out = "\u{0}"
      case 0x3f: out = "\u{7f}"
      default: break
      }
    }
    if latched.contains(.alt) { out = "\u{1b}" + out }
    latched = []
    return out
  }

  /// A 32 pt key (terminal-dock-styles.ts), in glass.
  private static func key(_ title: String?, icon: Lucide? = nil, action: @escaping () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.glass()
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = Radius.control
    configuration.baseForegroundColor = Palette.textPrimary
    configuration.image = icon?.image(size: 15, strokeWidth: 2)
    if let title {
      configuration.attributedTitle = AttributedString(
        title, attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)]))
    }
    configuration.titleLineBreakMode = .byClipping
    configuration.contentInsets = .init(top: 0, leading: 9, bottom: 0, trailing: 9)
    let button = UIButton(configuration: configuration)
    NSLayoutConstraint.activate([
      button.heightAnchor.constraint(equalToConstant: 32),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
    ])
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.addAction(
      UIAction { _ in
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
      }, for: .primaryActionTriggered)
    return button
  }

  private static func round(_ icon: Lucide, label: String, action: @escaping () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.glass()
    configuration.cornerStyle = .capsule
    configuration.image = icon.image(size: 17, strokeWidth: 2.4)
    configuration.baseForegroundColor = Palette.textSecondary
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = label
    button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    return button
  }
}
