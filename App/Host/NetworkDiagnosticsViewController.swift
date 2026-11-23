import OrcaCore
import UIKit

/// Host ⋯ › Network diagnostics (app/connection-log.tsx, diagnostics/connection-diagnostics-view.tsx): the
/// connection's state, what the recorded events suggest, and every step of dialing this desktop, copyable as a report.
final class NetworkDiagnosticsViewController: UIViewController {
  private let session: HostSession
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let stateLabel = TextLabel(size: 12, color: Palette.textSecondary)
  private let copyButton = UIButton(type: .system)
  private let causeLabel = TextLabel(size: 12, lineHeight: 18, lines: 0)
  private let nextLabel = TextLabel(size: 12, color: Palette.textSecondary, lineHeight: 18, lines: 0)
  private var logCard: UIView!
  private let logTitle = TextLabel(size: 12, color: Palette.textMuted, letterSpacing: 1)
  private let logRows = UIStackView()
  private let emptyLabel = TextLabel(size: 12, color: Palette.textMuted, lineHeight: 18, lines: 0)
  private var shownEntries: [ConnectionLogEntry] = []
  private var copied = false
  private var scrolledToEnd = false

  init(session: HostSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "diagnostics.connectionDiagnosticsView.title", defaultValue: "Network diagnostics")
    navigationItem.largeTitleDisplayMode = .never
    view.backgroundColor = Palette.bgBase

    scroll.alwaysBounceVertical = true
    view.addSubview(scroll)
    scroll.pin(to: view)
    stack.axis = .vertical
    stack.spacing = Spacing.md
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.sm),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
    ])

    // The state on the left, Copy report on the right.
    var copy = UIButton.Configuration.filled()
    copy.baseBackgroundColor = Palette.bgRaised
    copy.baseForegroundColor = Palette.textPrimary
    copy.background.cornerRadius = Radius.control
    copy.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Spacing.md, bottom: 6, trailing: Spacing.md)
    copy.imagePadding = 6
    copyButton.configuration = copy
    copyButton.addAction(UIAction { [weak self] _ in self?.copyReport() }, for: .primaryActionTriggered)
    copyButton.setContentHuggingPriority(.required, for: .horizontal)
    let statusRow = UIStackView(arrangedSubviews: [stateLabel, copyButton])
    statusRow.alignment = .center
    stack.addArrangedSubview(statusRow)

    let heading = TextLabel(
      String(localized: "diagnostics.connectionDiagnosticsView.diagnosisHeading", defaultValue: "What this suggests"), size: 12,
      weight: .semibold)
    let diagnosis = UIStackView(arrangedSubviews: [heading, causeLabel, nextLabel])
    diagnosis.axis = .vertical
    diagnosis.spacing = Spacing.xs
    stack.addArrangedSubview(card(diagnosis, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)))

    logTitle.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    logTitle.text = session.name.uppercased()
    logRows.axis = .vertical
    logRows.spacing = 6
    let log = UIStackView(arrangedSubviews: [logTitle, logRows])
    log.axis = .vertical
    log.spacing = Spacing.xs
    logCard = card(log, insets: UIEdgeInsets(top: Spacing.sm, left: Spacing.md, bottom: Spacing.sm, right: Spacing.md))
    stack.addArrangedSubview(logCard)

    emptyLabel.text = String(
      localized: "diagnostics.connectionDiagnosticsView.noEvents",
      defaultValue: "No connection events yet. Events appear as the app dials this host.")
    stack.addArrangedSubview(emptyLabel)
    renderCopy()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Open on the newest events, as the official log scrolls to its end.
    guard !scrolledToEnd, !shownEntries.isEmpty, scroll.contentSize.height > 0 else { return }
    scrolledToEnd = true
    scrollToEnd(animated: false)
  }

  override func updateProperties() {
    super.updateProperties()
    let state = session.connectionState
    let attempt = state.reconnectAttempt
    let label = Self.stateLabel(state)
    stateLabel.text =
      attempt > 0
      ? String(
        format: String(localized: "diagnostics.connectionDiagnosticsView.stateWithAttempt", defaultValue: "%1$@ · attempt %2$@"),
        label, "\(attempt)")
      : label
    let entries = session.connectionLog
    let diagnosis = ConnectionDiagnosis.diagnose(
      endpoint: session.host.endpoint, state: state, path: logPath, entries: entries)
    causeLabel.text = diagnosis.likelyCause
    nextLabel.text = diagnosis.nextStep
    guard entries != shownEntries else { return }
    let atEnd = scroll.contentOffset.y >= scroll.contentSize.height - scroll.bounds.height - 40
    shownEntries = entries
    renderLog()
    if atEnd, scrolledToEnd {
      view.layoutIfNeeded()
      scrollToEnd(animated: true)
    }
  }

  /// The path the open connection took, as the diagnosis names it.
  private var logPath: ConnectionLogEntry.Path? {
    guard session.connectionState == .connected, let path = session.path else { return nil }
    if path == .relay { return .relay }
    return HostEndpoint.isTailscale(session.host.endpoint) ? .tailscale : .lan
  }

  private func renderLog() {
    logRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    logCard.isHidden = shownEntries.isEmpty
    emptyLabel.isHidden = !shownEntries.isEmpty
    guard let base = shownEntries.first?.date else { return }
    for entry in shownEntries {
      logRows.addArrangedSubview(LogRow(entry: entry, base: base))
    }
  }

  private func scrollToEnd(animated: Bool) {
    let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
    guard bottom > -scroll.adjustedContentInset.top else { return }
    scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: animated)
  }

  private func copyReport() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    UIPasteboard.general.string = ConnectionReport.build(
      hostName: session.name, endpoint: session.host.endpoint, state: session.connectionState, path: logPath,
      lastConnectedAt: session.lastConnectedAt, appVersion: version, platform: "ios \(UIDevice.current.systemVersion)",
      desktopAppVersion: session.status?.appVersion, entries: session.connectionLog)
    Haptics.select()
    copied = true
    renderCopy()
    Task {
      try? await Task.sleep(for: .seconds(2))
      copied = false
      renderCopy()
    }
  }

  private func renderCopy() {
    var configuration = copyButton.configuration
    configuration?.image = (copied ? Lucide.check : Lucide.copy).image(size: 14, strokeWidth: 2)
    configuration?.imageColorTransformer = UIConfigurationColorTransformer { [copied] _ in
      copied ? Palette.statusGreen : Palette.textSecondary
    }
    configuration?.attributedTitle = AttributedString(
      copied
        ? String(localized: "common.copied", defaultValue: "Copied")
        : String(localized: "diagnostics.connectionDiagnosticsView.copyReport", defaultValue: "Copy report"),
      attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 12, weight: .semibold)]))
    copyButton.configuration = configuration
  }

  /// A panel card: the panel fill, a hairline border, the surface radius.
  private func card(_ content: UIView, insets: UIEdgeInsets) -> UIView {
    let card = UIView()
    card.backgroundColor = Palette.bgPanel
    card.layer.cornerRadius = Radius.surface
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1 / max(1, view.traitCollection.displayScale)
    card.layer.borderColor = Palette.borderSubtle.cgColor
    card.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: UIView, _: UITraitCollection) in
      card.layer.borderColor = Palette.borderSubtle.resolvedColor(with: card.traitCollection).cgColor
    }
    content.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(content)
    content.pin(to: card, insets: insets)
    return card
  }

  private static func stateLabel(_ state: ConnectionState) -> String {
    switch state {
    case .connecting: String(localized: "diagnostics.connectionDiagnosticsView.connecting", defaultValue: "connecting")
    case .handshaking: String(localized: "diagnostics.connectionDiagnosticsView.handshaking", defaultValue: "handshaking")
    case .connected: String(localized: "diagnostics.connectionDiagnosticsView.connected", defaultValue: "connected")
    case .disconnected: String(localized: "diagnostics.connectionDiagnosticsView.disconnected", defaultValue: "disconnected")
    case .reconnecting: String(localized: "diagnostics.connectionDiagnosticsView.reconnecting", defaultValue: "reconnecting")
    case .authFailed: String(localized: "diagnostics.connectionDiagnosticsView.authFailed", defaultValue: "auth-failed")
    }
  }
}

/// One event (ConnectionLog row): seconds since the first, the level's glyph, the message in its colour, the detail under it.
private final class LogRow: UIStackView {
  init(entry: ConnectionLogEntry, base: Date) {
    super.init(frame: .zero)
    let color: UIColor =
      switch entry.level {
      case .info: Palette.textSecondary
      case .success: Palette.statusGreen
      case .warn: Palette.statusAmber
      case .error: Palette.statusRed
      }
    let mono = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let time = TextLabel(entry.elapsedText(since: base), size: 12, color: Palette.textMuted)
    time.font = mono
    time.setContentHuggingPriority(.required, for: .horizontal)
    time.setContentCompressionResistancePriority(.required, for: .horizontal)
    time.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    let glyph = TextLabel(entry.glyph, size: 12, color: color, alignment: .center)
    glyph.font = mono
    glyph.widthAnchor.constraint(equalToConstant: 12).isActive = true
    let message = TextLabel(entry.message, size: 12, color: color, lineHeight: 16, lines: 0)
    message.font = mono
    let text = UIStackView(arrangedSubviews: [message])
    text.axis = .vertical
    text.spacing = 1
    if let detail = entry.detail {
      let label = TextLabel(detail, size: 11, color: Palette.textMuted, lineHeight: 14, lines: 2)
      label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      text.addArrangedSubview(label)
    }
    for view in [time, glyph, text] as [UIView] { addArrangedSubview(view) }
    spacing = Spacing.sm
    alignment = .top
    isAccessibilityElement = true
    accessibilityLabel = [entry.message, entry.detail].compactMap { $0 }.joined(separator: ", ")
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
