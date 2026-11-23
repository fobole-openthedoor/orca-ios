import UIKit

/// One piece of PR text to write in a sheet: the title, the description, a comment or a thread reply
/// (MobilePrTabSheets.tsx edit sheet, PRCommentComposer.tsx). Submit stays off while the text is empty or
/// unchanged; the sheet closes once the host took it, and keeps the text when it didn't.
final class PullRequestTextSheet: UIViewController, UITextViewDelegate {
  private let initial: String
  private let placeholderText: String
  private let singleLine: Bool
  private let allowsEmpty: Bool
  private let submitTitle: String
  private let onSubmit: (String) async -> String?
  private let textView = UITextView()
  private let placeholder = UILabel()
  private let errorLabel = TextLabel(size: Typography.metaSize, color: Palette.statusRed, lines: 0)
  private var submitting = false

  init(
    title: String, initial: String = "", placeholder: String = "", submitTitle: String, singleLine: Bool = false,
    allowsEmpty: Bool = false, onSubmit: @escaping (String) async -> String?
  ) {
    self.initial = initial
    placeholderText = placeholder
    self.singleLine = singleLine
    self.allowsEmpty = allowsEmpty
    self.submitTitle = submitTitle
    self.onSubmit = onSubmit
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The sheet in its own navigation bar, at medium and large heights.
  func presented() -> UINavigationController {
    let navigation = UINavigationController(rootViewController: self)
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = singleLine ? [.medium()] : [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.sheetSurface
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: submitTitle, style: .prominent, target: self, action: #selector(submit))
    textView.text = initial
    textView.font = Typography.font(16)
    textView.textColor = Palette.textPrimary
    textView.backgroundColor = Palette.sheetGroup
    textView.layer.cornerRadius = Radius.control
    textView.textContainerInset = UIEdgeInsets(top: Spacing.md, left: Spacing.sm, bottom: Spacing.md, right: Spacing.sm)
    textView.delegate = self
    textView.returnKeyType = singleLine ? .done : .default
    textView.isScrollEnabled = !singleLine
    placeholder.text = placeholderText
    placeholder.font = textView.font
    placeholder.textColor = Palette.textMuted
    placeholder.numberOfLines = 0
    errorLabel.isHidden = true
    for part in [textView, placeholder, errorLabel] as [UIView] {
      part.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(part)
    }
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: guide.topAnchor, constant: Spacing.md),
      textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Spacing.lg),
      textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Spacing.lg),
      errorLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: Spacing.sm),
      errorLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      errorLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
      singleLine
        ? textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        : errorLabel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.md),
      placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: Spacing.md),
      placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: Spacing.sm + 5),
      placeholder.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -Spacing.sm),
    ])
    update()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    textView.becomeFirstResponder()
  }

  private var text: String { textView.text.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func update() {
    placeholder.isHidden = !textView.text.isEmpty
    navigationItem.rightBarButtonItem?.isEnabled =
      !submitting && (allowsEmpty || !text.isEmpty) && textView.text != initial
    isModalInPresentation = textView.text != initial
  }

  func textViewDidChange(_ textView: UITextView) { update() }

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    guard singleLine, text == "\n" else { return true }
    submit()
    return false
  }

  @objc private func submit() {
    guard !submitting, allowsEmpty || !text.isEmpty, textView.text != initial else { return }
    submitting = true
    textView.isEditable = false
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.startAnimating()
    let item = navigationItem.rightBarButtonItem
    navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    let value = singleLine ? text : textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    Task { [weak self] in
      guard let self else { return }
      let failure = await onSubmit(value)
      submitting = false
      errorLabel.text = failure
      errorLabel.isHidden = failure == nil
      if failure == nil {
        dismiss(animated: true)
      } else {
        textView.isEditable = true
        navigationItem.rightBarButtonItem = item
        update()
      }
    }
  }
}
