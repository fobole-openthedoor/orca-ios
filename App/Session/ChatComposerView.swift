import UIKit

/// The chat composer: the official card's layout (text, then + · model · … · mic · send) on a Liquid Glass
/// surface, with a send button that changes with the chat's state.
final class ChatComposerView: UIView, UITextViewDelegate {
  enum Action: Equatable {
    case send, stop, loading, dictate
  }

  var onSend: ((String) -> Void)?
  var onStop: (() -> Void)?
  var onAttach: (() -> Void)?
  var onHeightChange: (() -> Void)?

  let textView = UITextView()
  private let placeholder = TextLabel(size: 16, color: Palette.textMuted, lines: 1)
  private let container = UIVisualEffectView(effect: UIGlassContainerEffect())
  private let surface = UIVisualEffectView()
  private let attach = UIButton(configuration: .glass())
  let modelChip = UIButton(configuration: .glass())
  private let mic = UIButton(configuration: .plain())
  private let sendButton = SendButton()
  private var textHeight: NSLayoutConstraint!
  private var working = false

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    (container.effect as? UIGlassContainerEffect)?.spacing = 8
    container.translatesAutoresizingMaskIntoConstraints = false
    let glass = UIGlassEffect(style: .regular)
    glass.isInteractive = true
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
    attach.accessibilityLabel = String(localized: "chat.composer.attach", defaultValue: "Attach")
    attach.addAction(UIAction { [weak self] _ in self?.onAttach?() }, for: .primaryActionTriggered)

    modelChip.configuration?.cornerStyle = .capsule
    modelChip.configuration?.baseForegroundColor = Palette.textPrimary
    modelChip.configuration?.imagePadding = 6
    modelChip.configuration?.image = Lucide.shieldAlert.image(size: 15, strokeWidth: 2).withTintColor(Palette.statusAmber, renderingMode: .alwaysOriginal)
    modelChip.configuration?.contentInsets = .init(top: 10, leading: 12, bottom: 10, trailing: 14)
    modelChip.showsMenuAsPrimaryAction = true
    modelChip.isHidden = true

    mic.configuration?.image = Lucide.mic.image(size: 20, strokeWidth: 2)
    mic.configuration?.baseForegroundColor = Palette.textSecondary
    mic.accessibilityLabel = String(localized: "chat.composer.dictate", defaultValue: "Dictate")

    sendButton.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .touchUpInside)

    let row = UIStackView(arrangedSubviews: [attach, modelChip, UIView(), mic, sendButton])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = Spacing.sm
    row.translatesAutoresizingMaskIntoConstraints = false
    for view in [textView, placeholder, row] as [UIView] { surface.contentView.addSubview(view) }

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
      textView.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: Spacing.md + 2),
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
    let action: Action = !currentText.isEmpty ? .send : working ? .stop : .dictate
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
      guard !currentText.isEmpty else { return }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      textView.text = ""
      refresh()
      onSend?(text)
    case .stop:
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      sendButton.set(.loading)
      onStop?()
    case .dictate:
      textView.becomeFirstResponder()
    case .loading:
      break
    }
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
      case .send: String(localized: "chat.composer.send", defaultValue: "Send")
      case .stop: String(localized: "chat.composer.stop", defaultValue: "Stop")
      case .loading: String(localized: "chat.composer.sending", defaultValue: "Sending")
      case .dictate: String(localized: "chat.composer.send", defaultValue: "Send")
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
