import OrcaCore
import UIKit

/// The chat composer: the official card's layout (text, then + · model · … · mic · send) on a Liquid Glass
/// surface, with a send button that changes with the chat's state.
final class ChatComposerView: UIView, UITextViewDelegate, UIDropInteractionDelegate {
  enum Action: Equatable {
    case send, stop, loading, dictate
  }

  var onSend: ((String, [OutgoingAttachment]) -> Void)?
  var onStop: (() -> Void)?
  var onHeightChange: (() -> Void)?
  /// The + menu's sources: photos, the camera, files. The composer pastes on its own.
  var onPickPhotos: (() -> Void)?
  var onTakePhoto: (() -> Void)?
  var onPickFiles: (() -> Void)?
  /// An image chip was tapped: the images waiting to go, and which one.
  var onOpenImages: (([UIImage], Int) -> Void)?
  /// Something the composer can't do, said by its screen.
  var onError: ((String) -> Void)?
  private var dictationBase = ""

  let textView = ComposerTextView()
  /// What goes with the next message, shown as chips above the text.
  private(set) var attachments: [OutgoingAttachment] = [] { didSet { drawAttachments() } }
  private let attachmentStrip = UIScrollView()
  private let attachmentRow = UIStackView()
  private let placeholder = TextLabel(size: 16, color: Palette.textMuted, lines: 1)
  private let container = UIVisualEffectView(effect: UIGlassContainerEffect())
  private let surface = UIVisualEffectView()
  private let attach = UIButton(configuration: .glass())
  let modelChip = UIButton(configuration: .glass())
  private let mic = UIButton(configuration: .plain())
  private let sendButton = SendButton()
  private var textHeight: NSLayoutConstraint!
  private var textTop: NSLayoutConstraint!
  private var textUnderChips: NSLayoutConstraint!
  private var working = false

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    (container.effect as? UIGlassContainerEffect)?.spacing = 8
    container.translatesAutoresizingMaskIntoConstraints = false
    let glass = UIGlassEffect(style: .regular)
    // Not interactive: an interactive glass takes the text view's long press, and with it Paste.
    glass.isInteractive = false
    surface.effect = glass
    surface.cornerConfiguration = .uniformCorners(radius: .fixed(Radius.floating))
    surface.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)
    container.contentView.addSubview(surface)

    textView.font = .systemFont(ofSize: 16)
    textView.textColor = Palette.textPrimary
    textView.backgroundColor = .clear
    textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    textView.textContainer.lineFragmentPadding = 0
    textView.isScrollEnabled = false
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.keyboardDismissMode = .interactive
    placeholder.text = String(localized: "chat.composer.placeholder", defaultValue: "Ask anything, @ to mention files, / for commands")
    placeholder.isUserInteractionEnabled = false

    attach.configuration?.image = Lucide.plus.image(size: 20, strokeWidth: 2)
    attach.configuration?.baseForegroundColor = Palette.textPrimary
    attach.configuration?.cornerStyle = .capsule
    attach.configuration?.contentInsets = .init(top: 10, leading: 10, bottom: 10, trailing: 10)
    attach.accessibilityLabel = String(localized: "chat.composer.addToMessage", defaultValue: "Add to message")
    attach.showsMenuAsPrimaryAction = true
    attach.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.attachMenu() ?? []) }
    ])
    textView.onPasteAttachments = { [weak self] providers in self?.take(providers) }
    textView.onPasteText = { [weak self] text in self?.add([AttachmentIntake.textFile(text)]) }
    addInteraction(UIDropInteraction(delegate: self))

    attachmentStrip.showsHorizontalScrollIndicator = false
    attachmentStrip.translatesAutoresizingMaskIntoConstraints = false
    attachmentRow.spacing = Spacing.sm
    attachmentRow.alignment = .center
    attachmentRow.translatesAutoresizingMaskIntoConstraints = false
    attachmentStrip.addSubview(attachmentRow)
    attachmentStrip.isHidden = true

    modelChip.configuration?.cornerStyle = .capsule
    modelChip.configuration?.baseForegroundColor = Palette.textPrimary
    modelChip.configuration?.imagePadding = 6
    modelChip.configuration?.image = Lucide.shieldAlert.image(size: 15, strokeWidth: 2).withTintColor(Palette.statusAmber, renderingMode: .alwaysOriginal)
    modelChip.configuration?.contentInsets = .init(top: 10, leading: 12, bottom: 10, trailing: 14)
    modelChip.showsMenuAsPrimaryAction = true
    modelChip.isHidden = true

    mic.configuration?.image = Lucide.mic.image(size: 20, strokeWidth: 2)
    mic.configuration?.baseForegroundColor = Palette.textSecondary
    mic.accessibilityLabel = String(localized: "dictation.controls.start", defaultValue: "Dictate")
    mic.addAction(UIAction { [weak self] _ in self?.toggleDictation() }, for: .primaryActionTriggered)

    sendButton.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .touchUpInside)

    let row = UIStackView(arrangedSubviews: [attach, modelChip, UIView(), mic, sendButton])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = Spacing.sm
    row.translatesAutoresizingMaskIntoConstraints = false
    for view in [attachmentStrip, textView, placeholder, row] as [UIView] { surface.contentView.addSubview(view) }
    // The text sits under the attachment chips when there are any.
    textTop = textView.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: Spacing.md + 2)
    textUnderChips = textView.topAnchor.constraint(equalTo: attachmentStrip.bottomAnchor, constant: Spacing.sm)

    textHeight = textView.heightAnchor.constraint(equalToConstant: 32)
    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: topAnchor),
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      surface.topAnchor.constraint(equalTo: container.contentView.topAnchor),
      surface.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: Spacing.md),
      surface.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -Spacing.md),
      surface.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -Spacing.sm),
      textTop,
      attachmentStrip.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: Spacing.md),
      attachmentStrip.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: Spacing.md),
      attachmentStrip.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -Spacing.md),
      attachmentStrip.heightAnchor.constraint(equalToConstant: 56),
      attachmentRow.leadingAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.leadingAnchor),
      attachmentRow.trailingAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.trailingAnchor),
      attachmentRow.topAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.topAnchor),
      attachmentRow.bottomAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.bottomAnchor),
      attachmentRow.heightAnchor.constraint(equalTo: attachmentStrip.frameLayoutGuide.heightAnchor),
      textView.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: Spacing.lg + 2),
      textView.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -Spacing.lg),
      textHeight,
      placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
      placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
      row.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: Spacing.sm),
      row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: Spacing.md),
      row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -Spacing.md),
      row.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor, constant: -Spacing.md),
      mic.widthAnchor.constraint(equalToConstant: 44),
      mic.heightAnchor.constraint(equalToConstant: 44),
    ])
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The model chip's label and menu, from the session's options.
  /// "Opus 5.5 Med": the model in the primary colour, its effort muted, as the official chip.
  func setModel(title: String?, detail: String? = nil, menu: UIMenu?) {
    modelChip.isHidden = title == nil
    var configuration = modelChip.configuration
    configuration?.attributedTitle = title.map {
      var text = AttributedString($0, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: Palette.textPrimary]))
      if let detail {
        text += AttributedString(" \(detail)", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15), .foregroundColor: Palette.textMuted]))
      }
      return text
    }
    modelChip.configuration = configuration
    modelChip.menu = menu
  }

  func setWorking(_ working: Bool) {
    self.working = working
    refresh()
  }

  func textViewDidChange(_ textView: UITextView) {
    refresh()
  }

  private var currentText: String { textView.text.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func refresh() {
    placeholder.isHidden = !textView.text.isEmpty
    let action: Action = !currentText.isEmpty || !attachments.isEmpty ? .send : working ? .stop : .dictate
    sendButton.set(action)
    // Grow up to six lines, then scroll, as the official field does.
    let width = max(textView.bounds.width, 100)
    let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let maximum = (textView.font?.lineHeight ?? 20) * 6 + 8
    let height = min(max(32, ceil(fitting)), maximum)
    textView.isScrollEnabled = fitting > maximum
    if textHeight.constant != height {
      textHeight.constant = height
      onHeightChange?()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    refresh()
  }

  private func primaryTapped() {
    switch sendButton.action {
    case .send:
      let text = textView.text ?? ""
      guard !currentText.isEmpty || !attachments.isEmpty else { return }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      let sending = attachments
      textView.text = ""
      attachments = []
      refresh()
      onSend?(text, sending)
    case .stop:
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      sendButton.set(.loading)
      onStop?()
    case .dictate:
      toggleDictation()
    case .loading:
      break
    }
  }

  /// Puts text in the field (a rewound message, ready to edit), with the keyboard up.
  func setText(_ value: String) {
    textView.text = value
    refresh()
    textView.becomeFirstResponder()
  }

  // MARK: Dictation

  /// Tap to listen, tap again to stop; the words land after whatever was typed.
  private func toggleDictation() {
    let dictation = Dictation.shared
    if dictation.isListening {
      dictation.stop()
      return
    }
    dictationBase = textView.text.isEmpty || textView.text.hasSuffix(" ") || textView.text.hasSuffix("\n") ? textView.text : textView.text + " "
    setListening(true)
    Task {
      let refusal = await dictation.start(
        onText: { [weak self] text in
          guard let self else { return }
          self.textView.text = self.dictationBase + text
          self.refresh()
        },
        onEnd: { [weak self] in self?.setListening(false) })
      if let refusal {
        setListening(false)
        onError?(refusal)
      }
    }
  }

  private func setListening(_ listening: Bool) {
    mic.configuration?.image = Lucide.mic.image(size: 20, strokeWidth: 2)
    mic.configuration?.baseForegroundColor = listening ? Palette.statusRed : Palette.textSecondary
    mic.accessibilityValue = listening ? String(localized: "orcaios.dictation.listening", defaultValue: "Listening") : nil
  }

  // MARK: Attachments

  func add(_ new: [OutgoingAttachment]) {
    guard !new.isEmpty else { return }
    attachments += new
    refresh()
  }

  private func take(_ providers: [NSItemProvider]) {
    Task { add(await AttachmentIntake.load(providers)) }
  }

  private func attachMenu() -> [UIMenuElement] {
    var items: [UIMenuElement] = [
      UIAction(title: String(localized: "session.nativeChatAttachActions.photos", defaultValue: "Photos"), image: UIImage(systemName: "photo.on.rectangle")) {
        [weak self] _ in self?.onPickPhotos?()
      },
      UIAction(title: String(localized: "session.nativeChatAttachActions.files", defaultValue: "Files"), image: UIImage(systemName: "folder")) {
        [weak self] _ in self?.onPickFiles?()
      },
    ]
    if UIImagePickerController.isSourceTypeAvailable(.camera) {
      items.insert(
        UIAction(title: String(localized: "orcaios.composer.camera", defaultValue: "Take Photo"), image: UIImage(systemName: "camera")) {
          [weak self] _ in self?.onTakePhoto?()
        }, at: 1)
    }
    let pasteboard = UIPasteboard.general
    if pasteboard.hasImages || AttachmentIntake.canAttach(pasteboard.itemProviders) {
      items.append(
        UIMenu(options: .displayInline, children: [
          UIAction(title: String(localized: "session.accessoryKeys.pasteFromClipboard", defaultValue: "Paste from clipboard"), image: UIImage(systemName: "doc.on.clipboard")) {
            [weak self] _ in self?.take(UIPasteboard.general.itemProviders)
          }
        ]))
    }
    return items
  }

  private func drawAttachments() {
    attachmentRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for attachment in attachments {
      attachmentRow.addArrangedSubview(chip(for: attachment))
    }
    let shown = !attachments.isEmpty
    attachmentStrip.isHidden = !shown
    textTop.isActive = !shown
    textUnderChips.isActive = shown
    onHeightChange?()
  }

  private func openImage(_ id: UUID) {
    let images = attachments.filter { $0.kind == .image }
    let decoded = images.compactMap { attachment in UIImage(data: attachment.data).map { (attachment.id, $0) } }
    guard let index = decoded.firstIndex(where: { $0.0 == id }) else { return }
    onOpenImages?(decoded.map(\.1), index)
  }

  /// A 48 pt thumbnail, or a file's name, with an x to take it back out.
  private func chip(for attachment: OutgoingAttachment) -> UIView {
    let chip = UIView()
    chip.translatesAutoresizingMaskIntoConstraints = false
    chip.backgroundColor = Palette.bgRaised
    chip.layer.cornerRadius = Radius.control
    chip.layer.cornerCurve = .continuous
    chip.clipsToBounds = true
    if let thumbnail = AttachmentIntake.thumbnail(for: attachment, maxPixel: 160) {
      let image = UIImageView(image: thumbnail)
      image.contentMode = .scaleAspectFill
      image.translatesAutoresizingMaskIntoConstraints = false
      chip.addSubview(image)
      image.pin(to: chip)
      chip.widthAnchor.constraint(equalToConstant: 48).isActive = true
      let id = attachment.id
      let open = UIButton(primaryAction: UIAction { [weak self] _ in self?.openImage(id) })
      open.accessibilityLabel = String(localized: "chat.nativeChatProse.attachedImage", defaultValue: "Attached image")
      open.translatesAutoresizingMaskIntoConstraints = false
      chip.addSubview(open)
      open.pin(to: chip)
    } else {
      let icon = LucideView(.fileText, size: 16, strokeWidth: 2, color: Palette.textSecondary)
      let name = TextLabel(attachment.name, size: 13, color: Palette.textPrimary)
      name.lineBreakMode = .byTruncatingMiddle
      let row = UIStackView(arrangedSubviews: [icon, name])
      row.spacing = 6
      row.alignment = .center
      row.translatesAutoresizingMaskIntoConstraints = false
      chip.addSubview(row)
      NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
        row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -26),
        row.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        chip.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
      ])
    }
    chip.heightAnchor.constraint(equalToConstant: 48).isActive = true
    var close = UIButton.Configuration.filled()
    close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold))
    close.baseBackgroundColor = UIColor.black.withAlphaComponent(0.6)
    close.baseForegroundColor = .white
    close.cornerStyle = .capsule
    close.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
    let id = attachment.id
    let remove = UIButton(configuration: close, primaryAction: UIAction { [weak self] _ in
      self?.attachments.removeAll { $0.id == id }
      self?.refresh()
    })
    remove.accessibilityLabel = String(localized: "common.remove", defaultValue: "Remove")
    remove.translatesAutoresizingMaskIntoConstraints = false
    chip.addSubview(remove)
    NSLayoutConstraint.activate([
      remove.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
      remove.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -3),
    ])
    return chip
  }

  // MARK: Drop

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    AttachmentIntake.canAttach(session.items.map(\.itemProvider))
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    take(session.items.map(\.itemProvider))
  }
}

/// The send button: a 30 pt circle in a 44 pt target, morphing between send, stop, loading and dictate.
final class SendButton: UIControl {
  private(set) var action: ChatComposerView.Action = .dictate
  private let circle = UIView()
  private let glyph = UIImageView()
  private let arc = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    circle.translatesAutoresizingMaskIntoConstraints = false
    circle.isUserInteractionEnabled = false
    circle.layer.cornerRadius = 15
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.contentMode = .center
    arc.fillColor = nil
    arc.lineWidth = 2.25
    arc.lineCap = .round
    arc.strokeColor = UIColor.white.cgColor
    addSubview(circle)
    circle.addSubview(glyph)
    circle.layer.addSublayer(arc)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 44),
      heightAnchor.constraint(equalToConstant: 44),
      circle.widthAnchor.constraint(equalToConstant: 30),
      circle.heightAnchor.constraint(equalToConstant: 30),
      circle.centerXAnchor.constraint(equalTo: centerXAnchor),
      circle.centerYAnchor.constraint(equalTo: centerYAnchor),
      glyph.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
      glyph.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
    ])
    let path = UIBezierPath(arcCenter: CGPoint(x: 15, y: 15), radius: 7.5, startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
    arc.path = path.cgPath
    arc.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
    apply(.dictate, animated: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func set(_ next: ChatComposerView.Action) {
    guard next != action else { return }
    apply(next, animated: window != nil)
  }

  private func apply(_ next: ChatComposerView.Action, animated: Bool) {
    action = next
    let changes = {
      switch next {
      case .send:
        self.circle.backgroundColor = Palette.surfaceBright
        self.glyph.image = Lucide.arrowUp.image(size: 16, strokeWidth: 2.6).withTintColor(Palette.bgBase, renderingMode: .alwaysOriginal)
      case .stop:
        self.circle.backgroundColor = Palette.surfaceBright
        self.glyph.image = UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))?
          .withTintColor(Palette.bgBase, renderingMode: .alwaysOriginal)
      case .loading:
        self.circle.backgroundColor = .systemGray
        self.glyph.image = nil
      case .dictate:
        self.circle.backgroundColor = Palette.translucentFill
        self.glyph.image = Lucide.arrowUp.image(size: 16, strokeWidth: 2.4).withTintColor(Palette.textMuted, renderingMode: .alwaysOriginal)
      }
      self.arc.isHidden = next != .loading
    }
    accessibilityLabel =
      switch next {
      case .send: String(localized: "chat.composer.sendMessage", defaultValue: "Send message")
      case .stop: String(localized: "session.smartKeys.stop", defaultValue: "Stop")
      case .loading: String(localized: "session.terminalMoreKeys.sending", defaultValue: "Sending…")
      case .dictate: String(localized: "chat.composer.sendMessage", defaultValue: "Send message")
      }
    isEnabled = next == .send || next == .stop
    if next == .loading {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.toValue = CGFloat.pi * 2
      spin.duration = 0.8
      spin.repeatCount = .infinity
      arc.add(spin, forKey: "spin")
    } else {
      arc.removeAllAnimations()
    }
    guard animated else {
      changes()
      return
    }
    // A cross-dissolve with a keyframe pop: down to 0.72 over the first 45%, back to identity after.
    UIView.transition(with: circle, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)
    if !UIAccessibility.isReduceMotionEnabled {
      UIView.animateKeyframes(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) {
        UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) {
          self.circle.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        }
        UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) { self.circle.transform = .identity }
      }
    }
  }

}

/// The composer's text view: Paste takes images and files as attachments, and very long text as a file,
/// leaving ordinary text to the editor.
final class ComposerTextView: UITextView {
  var onPasteAttachments: (([NSItemProvider]) -> Void)?

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)) {
      let pasteboard = UIPasteboard.general
      return pasteboard.hasStrings || pasteboard.hasImages || pasteboard.hasURLs
        || AttachmentIntake.canAttach(pasteboard.itemProviders)
    }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    let pasteboard = UIPasteboard.general
    let providers = pasteboard.itemProviders
    if AttachmentIntake.canAttach(providers) {
      onPasteAttachments?(providers)
      return
    }
    if let text = pasteboard.string, AttachmentIntake.shouldPromotePastedText(text) {
      onPasteText?(text)
      return
    }
    super.paste(sender)
  }

  /// Text long enough to flood the composer, which goes as a file instead.
  var onPasteText: ((String) -> Void)?
}
