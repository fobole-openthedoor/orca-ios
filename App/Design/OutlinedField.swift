import UIKit

/// A form field with the official edge (composer-input-styles.ts `field` / FieldTextInput): composerSurface, a
/// 1 pt inputBorder and a 12 pt radius, turning into a 2 pt accent ring while it has focus. One line, or a
/// box that opens `minHeight` tall for longer text.
final class OutlinedField: UIView, UITextFieldDelegate, UITextViewDelegate {
  let textField = UITextField()
  let textView = UITextView()
  var onChange: ((String) -> Void)?
  var onReturn: (() -> Void)?
  private let multiline: Bool
  private let placeholderLabel = UILabel()
  private let row = UIStackView()

  var text: String {
    get { multiline ? textView.text : textField.text ?? "" }
    set {
      if multiline { textView.text = newValue } else { textField.text = newValue }
      placeholderLabel.isHidden = !newValue.isEmpty
    }
  }

  var placeholder: String? {
    didSet {
      placeholderLabel.text = placeholder
      textField.attributedPlaceholder = placeholder.map {
        NSAttributedString(string: $0, attributes: [.foregroundColor: Palette.textMuted])
      }
      textField.accessibilityLabel = textField.accessibilityLabel ?? placeholder
    }
  }

  var isEnabled = true {
    didSet {
      textField.isEnabled = isEnabled
      textView.isEditable = isEnabled
      alpha = isEnabled ? 1 : Feedback.disabledOpacity
    }
  }

  /// A control after the text, such as Paste.
  var trailing: UIView? {
    didSet {
      oldValue?.removeFromSuperview()
      if let trailing { row.addArrangedSubview(trailing) }
    }
  }

  init(multiline: Bool = false, monospace: Bool = false, fontSize: CGFloat = 16, minHeight: CGFloat = 44) {
    self.multiline = multiline
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = Palette.composerSurface
    layer.cornerRadius = 12
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = Palette.inputBorder.cgColor
    let font = monospace ? Typography.mono(fontSize) : .systemFont(ofSize: fontSize)
    if monospace { typeAsWritten() }
    textField.autocapitalizationType = .none
    textView.autocapitalizationType = .none
    row.axis = .horizontal
    row.alignment = multiline ? .top : .center
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    if multiline {
      textView.font = font
      textView.textColor = Palette.textPrimary
      textView.backgroundColor = .clear
      textView.tintColor = Palette.accentBlue
      textView.textContainerInset = .zero
      textView.textContainer.lineFragmentPadding = 0
      textView.delegate = self
      row.addArrangedSubview(textView)
      placeholderLabel.font = font
      placeholderLabel.textColor = Palette.textMuted
      placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
      textView.addSubview(placeholderLabel)
      NSLayoutConstraint.activate([
        placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
        placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor),
        row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      ])
    } else {
      textField.font = font
      textField.textColor = Palette.textPrimary
      textField.tintColor = Palette.accentBlue
      textField.delegate = self
      textField.addAction(UIAction { [weak self] _ in self?.onChange?(self?.textField.text ?? "") }, for: .editingChanged)
      row.addArrangedSubview(textField)
      NSLayoutConstraint.activate([
        row.topAnchor.constraint(equalTo: topAnchor),
        row.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
    ])
    textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus)))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    showFocus(multiline ? textView.isFirstResponder : textField.isFirstResponder)
  }

  /// No corrections, smart punctuation or spell checking: for links, commands and times.
  func typeAsWritten() {
    textField.autocorrectionType = .no
    textField.spellCheckingType = .no
    textField.smartDashesType = .no
    textField.smartQuotesType = .no
    textView.autocorrectionType = .no
    textView.spellCheckingType = .no
    textView.smartDashesType = .no
    textView.smartQuotesType = .no
  }

  @objc func focus() {
    if multiline { textView.becomeFirstResponder() } else { textField.becomeFirstResponder() }
  }

  private func showFocus(_ focused: Bool) {
    layer.borderWidth = focused ? 2 : 1
    layer.borderColor = (focused ? Palette.accentBlue : Palette.inputBorder).resolvedColor(with: traitCollection).cgColor
  }

  func textFieldDidBeginEditing(_ textField: UITextField) { showFocus(true) }
  func textFieldDidEndEditing(_ textField: UITextField) { showFocus(false) }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if let onReturn {
      onReturn()
    } else {
      textField.resignFirstResponder()
    }
    return true
  }

  func textViewDidBeginEditing(_ textView: UITextView) { showFocus(true) }
  func textViewDidEndEditing(_ textView: UITextView) { showFocus(false) }

  func textViewDidChange(_ textView: UITextView) {
    placeholderLabel.isHidden = !textView.text.isEmpty
    onChange?(textView.text)
  }
}
