import OrcaCore
import UIKit

/// One call of an opened activity line (MobileNativeChatToolLine.tsx): its name and argument on one line,
/// opening in place to the whole input (a command, a subagent's task, or the arguments) and the output's
/// first lines, with "Show full output" when there is more.
final class ToolCallView: UIView {
  var onShowFull: (() -> Void)?

  /// Output lines shown in place; the rest is one tap away.
  static let outputLines = 40

  private let icon = LucideView(.wrench, size: 13, strokeWidth: 2, color: Palette.textMuted)
  private let name = TextLabel(size: ChatProse.metaSize, weight: .medium, color: Palette.textSecondary, lines: 1)
  private let summary = TextLabel(size: ChatProse.metaSize, color: Palette.textMuted, lines: 1)
  private let chevron = LucideView(.chevronRight, size: 12, strokeWidth: 2, color: Palette.textMuted)
  private let body = UIStackView()
  private let input = DetailBlock()
  private let output = DetailBlock()
  private let facts = TextLabel(size: 12, color: Palette.textMuted, lines: 1)
  private let showFull = UIButton(configuration: .plain())

  init() {
    super.init(frame: .zero)
    let rule = UIView()
    rule.backgroundColor = Palette.borderSubtle
    rule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rule)
    summary.font = Typography.mono(ChatProse.metaSize - 1)
    summary.lineBreakMode = .byTruncatingTail
    summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    name.setContentCompressionResistancePriority(.required, for: .horizontal)
    let head = UIStackView(arrangedSubviews: [icon, name, summary, UIView(), chevron])
    head.spacing = 6
    head.alignment = .center
    head.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

    showFull.configuration?.title = String(localized: "session.nativeChatFullContent.showFullOutput", defaultValue: "Show full output")
    showFull.configuration?.baseForegroundColor = Palette.accentBlue
    showFull.configuration?.contentInsets = .init(top: 2, leading: 0, bottom: 2, trailing: 0)
    showFull.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = UIFont.systemFont(ofSize: 13, weight: .medium)
      return attributes
    }
    showFull.contentHorizontalAlignment = .leading
    showFull.addAction(UIAction { [weak self] _ in self?.onShowFull?() }, for: .primaryActionTriggered)

    body.axis = .vertical
    body.spacing = 6
    [input, output, facts, showFull].forEach { body.addArrangedSubview($0) }
    let column = UIStackView(arrangedSubviews: [head, body])
    column.axis = .vertical
    column.spacing = 4
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 7),
      rule.widthAnchor.constraint(equalToConstant: 1),
      rule.topAnchor.constraint(equalTo: topAnchor),
      rule.bottomAnchor.constraint(equalTo: bottomAnchor),
      column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 23),
      column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
    ])
    isAccessibilityElement = false
    head.isAccessibilityElement = true
    head.accessibilityTraits = .button
    self.head = head
  }

  private weak var head: UIStackView?

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ call: TranscriptItem.ToolCall, open: Bool) {
    let category = ToolCategory.of(call)
    icon.icon = category.icon
    icon.color = call.state == "failed" || (call.exitCode ?? 0) != 0 ? Palette.statusRed : Palette.textMuted
    name.text = call.name
    summary.text = call.summary.replacingOccurrences(of: "\n", with: " ")
    chevron.transform = open ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
    head?.accessibilityLabel = [call.name, call.summary].filter { !$0.isEmpty }.joined(separator: ", ")
    head?.accessibilityTraits = open ? [.button, .selected] : .button
    body.isHidden = !open
    guard open else { return }

    let inputText = Self.inputText(call)
    input.show(inputText)
    input.isHidden = inputText.isEmpty
    let text = call.output ?? ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    output.showTerminal(lines.prefix(Self.outputLines).joined(separator: "\n"))
    output.isHidden = text.isEmpty
    var parts: [String] = []
    if let exit = call.exitCode { parts.append("exit \(exit)") }
    if let ms = call.durationMs, ms > 0 { parts.append(ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", ms / 1000)) }
    facts.text = parts.joined(separator: " · ")
    facts.isHidden = parts.isEmpty
    showFull.isHidden = !(call.outputTruncated || lines.count > Self.outputLines)
  }

  /// What the call was given: a command as typed, a subagent's task and instructions, or each argument.
  static func inputText(_ call: TranscriptItem.ToolCall) -> String {
    if let command = call.input["command"]?.stringValue { return command }
    if let prompt = call.input["prompt"]?.stringValue {
      return [call.input["description"]?.stringValue, prompt].compactMap { $0 }.filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }
    if case .object(let fields) = call.input {
      return fields.keys.sorted().map { key in
        let value = fields[key]!
        return "\(key): \(value.stringValue ?? value.serialized())"
      }.joined(separator: "\n")
    }
    return call.input.stringValue ?? ""
  }
}

/// Monospaced text on the raised fill, wrapping, selectable by long press through its copy menu.
private final class DetailBlock: UIView {
  private let label = TextLabel(size: 12, color: Palette.textSecondary, lines: 0)

  init() {
    super.init(frame: .zero)
    backgroundColor = Palette.bgRaised
    layer.cornerRadius = Radius.control
    layer.cornerCurve = .continuous
    label.font = Typography.mono(12)
    label.lineBreakMode = .byCharWrapping
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
    addInteraction(UIContextMenuInteraction(delegate: self))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ text: String) {
    backgroundColor = Palette.bgRaised
    label.text = text
  }

  /// Output as a terminal shows it: its colours on the terminal's ground.
  func showTerminal(_ text: String) {
    backgroundColor = TerminalText.background
    label.attributedText = TerminalText.render(command: nil, output: text)
  }

  fileprivate var text: String { label.text ?? "" }
}

extension DetailBlock: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint)
    -> UIContextMenuConfiguration?
  {
    let text = self.text
    return UIContextMenuConfiguration(actionProvider: { _ in
      UIMenu(children: [
        UIAction(title: String(localized: "common.copy", defaultValue: "Copy"), image: Lucide.copy.image(size: 18)) { _ in
          UIPasteboard.general.string = text
        }
      ])
    })
  }
}

/// A call's whole output on its own page: read again from the host when the transcript only carried its
/// head (agentSession.item), monospaced and selectable.
final class ToolOutputViewController: UIViewController {
  private let call: TranscriptItem.ToolCall
  private let load: (() async -> TranscriptItem.ToolCall?)?
  private let text = UITextView()
  private let spinner = UIActivityIndicatorView(style: .medium)

  init(call: TranscriptItem.ToolCall, load: (() async -> TranscriptItem.ToolCall?)?) {
    self.call = call
    self.load = load
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func sheet(call: TranscriptItem.ToolCall, load: (() async -> TranscriptItem.ToolCall?)?) -> UIViewController {
    let navigation = UINavigationController(rootViewController: ToolOutputViewController(call: call, load: load))
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = call.name
    navigationItem.subtitle = call.summary.replacingOccurrences(of: "\n", with: " ")
    // A terminal's page: its colours, whatever the app's appearance.
    view.backgroundColor = TerminalText.background
    overrideUserInterfaceStyle = .dark
    navigationController?.overrideUserInterfaceStyle = .dark
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      image: Lucide.copy.image(size: 20), primaryAction: UIAction { [weak self] _ in
        UIPasteboard.general.string = self?.text.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      })
    navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "common.copy", defaultValue: "Copy")
    text.isEditable = false
    text.backgroundColor = .clear
    text.font = Typography.mono(12)
    text.textColor = Palette.textPrimary
    text.textContainerInset = UIEdgeInsets(top: Spacing.md, left: Spacing.md, bottom: Spacing.xl, right: Spacing.md)
    text.alwaysBounceVertical = true
    text.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(text)
    text.pin(to: view)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.xl),
    ])
    show(call)
    guard call.outputTruncated, let load else { return }
    spinner.startAnimating()
    Task { [weak self] in
      let full = await load()
      guard let self else { return }
      self.spinner.stopAnimating()
      if let full {
        self.show(full)
      } else {
        let alert = UIAlertController(
          title: String(localized: "session.nativeChatFullContent.loadOutputFailed", defaultValue: "Retry full output"),
          message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        self.present(alert, animated: true)
      }
    }
  }

  private func show(_ call: TranscriptItem.ToolCall) {
    let input = ToolCallView.inputText(call)
    text.attributedText = TerminalText.render(command: input, output: call.output ?? "")
  }
}
