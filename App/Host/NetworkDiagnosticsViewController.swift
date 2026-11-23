import OrcaCore
import UIKit

/// Host ⋯ › Network diagnostics (app/connection-log.tsx, diagnostics/connection-diagnostics-view.tsx): the
/// connection's state, what the recorded events suggest, and every step of dialing this desktop, copyable as a report.
/// With more than one desktop paired, chips above switch between them; a Relay failure offers Send diagnostics.
final class NetworkDiagnosticsViewController: UIViewController {
  private enum Submission { case sending, sent, failed }

  private var session: HostSession
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let hostChips = UIStackView()
  private let privacyHint = TextLabel(size: 11, color: Palette.textMuted, lineHeight: 15, lines: 0)
  private let sendButton = UIButton(type: .system)
  /// Each reported incident's sending, by host and the failure's event id, so a new incident starts fresh.
  private var submissions: [String: Submission] = [:]
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

    // One chip per paired desktop, wrapping onto rows, when there is more than one to read.
    hostChips.axis = .vertical
    hostChips.alignment = .leading
    hostChips.spacing = Spacing.sm
    stack.addArrangedSubview(hostChips)
    stack.setCustomSpacing(Spacing.md, after: hostChips)

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
    privacyHint.text = String(
      localized: "diagnostics.connectionDiagnosticsView.privacyHint",
      defaultValue:
        "Sends a size-limited redacted report including host name, endpoint, versions, connection state, and events—never terminal contents or credentials."
    )
    var send = UIButton.Configuration.filled()
    send.baseBackgroundColor = Palette.bgRaised
    send.baseForegroundColor = Palette.textPrimary
    send.background.cornerRadius = Radius.control
    send.cornerStyle = .fixed
    send.contentInsets = NSDirectionalEdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md)
    send.imagePadding = Spacing.xs
    sendButton.configuration = send
    sendButton.addAction(UIAction { [weak self] _ in self?.sendDiagnostics() }, for: .primaryActionTriggered)
    let sendRow = UIStackView(arrangedSubviews: [sendButton, UIView()])
    let diagnosis = UIStackView(arrangedSubviews: [heading, causeLabel, nextLabel, privacyHint, sendRow])
    diagnosis.axis = .vertical
    diagnosis.spacing = Spacing.xs
    diagnosis.setCustomSpacing(Spacing.sm, after: nextLabel)
    diagnosis.setCustomSpacing(Spacing.md, after: privacyHint)
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

  private var chipsWidth: CGFloat = 0

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The chips wrap by the page's width, which is known only now.
    if view.bounds.width != chipsWidth {
      chipsWidth = view.bounds.width
      renderHostChips()
    }
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
    renderSend(incident: diagnosis.reportableIncidentId)
    renderHostChips()
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

  private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

  private func report() -> String {
    ConnectionReport.build(
      hostName: session.name, endpoint: session.host.endpoint, state: session.connectionState, path: logPath,
      lastConnectedAt: session.lastConnectedAt, appVersion: appVersion, platform: "ios \(UIDevice.current.systemVersion)",
      desktopAppVersion: session.status?.appVersion, entries: session.connectionLog)
  }

  // MARK: Hosts

  /// The paired desktops' chips; the one shown reads in the primary colour on the panel fill, outlined.
  private func renderHostChips() {
    let sessions = AppModel.shared.orderedHosts.compactMap { AppModel.shared.session(for: $0.id) }
    hostChips.arrangedSubviews.forEach { $0.removeFromSuperview() }
    hostChips.isHidden = sessions.count < 2
    guard sessions.count >= 2 else { return }
    // Rows filled to the page's width, as the official chips wrap.
    let available = max(view.bounds.width - 2 * Spacing.lg, 200)
    var row = chipRow()
    var used: CGFloat = 0
    for candidate in sessions {
      let chip = hostChip(candidate)
      let width = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
      if used > 0, used + Spacing.sm + width > available {
        hostChips.addArrangedSubview(row)
        row = chipRow()
        used = 0
      }
      row.addArrangedSubview(chip)
      used += (used > 0 ? Spacing.sm : 0) + width
    }
    hostChips.addArrangedSubview(row)
  }

  private func chipRow() -> UIStackView {
    let row = UIStackView()
    row.spacing = Spacing.sm
    return row
  }

  private func hostChip(_ candidate: HostSession) -> UIButton {
    let selected = candidate === session
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = selected ? Palette.bgPanel : Palette.bgRaised
    configuration.baseForegroundColor = selected ? Palette.textPrimary : Palette.textSecondary
    configuration.cornerStyle = .capsule
    configuration.background.strokeColor = selected ? Palette.borderSubtle : nil
    configuration.background.strokeWidth = selected ? 1 : 0
    configuration.contentInsets = NSDirectionalEdgeInsets(top: Spacing.xs + 2, leading: Spacing.md, bottom: Spacing.xs + 2, trailing: Spacing.md)
    configuration.titleLineBreakMode = .byTruncatingTail
    configuration.attributedTitle = AttributedString(
      candidate.name, attributes: AttributeContainer([.font: Typography.font(Typography.metaSize, selected ? .semibold : .regular)]))
    let chip = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.show(candidate) })
    chip.widthAnchor.constraint(lessThanOrEqualToConstant: 160 + 2 * Spacing.md).isActive = true
    chip.accessibilityTraits.insert(selected ? .selected : [])
    return chip
  }

  /// Reads another desktop's history in place.
  private func show(_ next: HostSession) {
    guard next !== session else { return }
    Haptics.select()
    session = next
    logTitle.text = next.name.uppercased()
    shownEntries = []
    scrolledToEnd = false
    copied = false
    renderCopy()
    setNeedsUpdateProperties()
    scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
  }

  // MARK: Send diagnostics

  private func submissionKey(_ incident: String?) -> String? {
    incident.map { "\(session.host.id.uuidString):\($0)" }
  }

  /// Offered only while the failure is Orca Relay's to look into (reportability `orca-relay`).
  private func renderSend(incident: String?) {
    let key = submissionKey(incident)
    privacyHint.isHidden = key == nil
    sendButton.superview?.isHidden = key == nil
    guard let key else { return }
    let state = submissions[key]
    var configuration = sendButton.configuration
    configuration?.image = (state == .sent ? Lucide.check : Lucide.send).image(size: 14, strokeWidth: 2)
    configuration?.imageColorTransformer = UIConfigurationColorTransformer { _ in
      state == .sent ? Palette.statusGreen : Palette.textPrimary
    }
    let title =
      switch state {
      case .sending: String(localized: "diagnostics.connectionDiagnosticsView.sending", defaultValue: "Sending…")
      case .sent: String(localized: "diagnostics.connectionDiagnosticsView.sent", defaultValue: "Diagnostics sent")
      case .failed: String(localized: "diagnostics.connectionDiagnosticsView.retrySending", defaultValue: "Retry sending")
      case nil: String(localized: "diagnostics.connectionDiagnosticsView.sendDiagnostics", defaultValue: "Send diagnostics")
      }
    configuration?.attributedTitle = AttributedString(
      title, attributes: AttributeContainer([.font: Typography.font(Typography.metaSize, .semibold)]))
    sendButton.configuration = configuration
    sendButton.isEnabled = state != .sending
  }

  /// Sends the redacted report for this incident after the tap; a report whose incident changed meanwhile isn't sent.
  private func sendDiagnostics() {
    let incident = ConnectionDiagnosis.diagnose(
      endpoint: session.host.endpoint, state: session.connectionState, path: logPath, entries: session.connectionLog
    ).reportableIncidentId
    guard let key = submissionKey(incident), submissions[key] != .sending else { return }
    submissions[key] = .sending
    setNeedsUpdateProperties()
    let report = report()
    let version = appVersion
    Task { [weak self] in
      let error = await ConnectionDiagnosticsSubmission.submit(report: report, appVersion: version, platform: "ios")
      guard let self else { return }
      self.submissions[key] = error == nil ? .sent : .failed
      self.setNeedsUpdateProperties()
    }
  }

  private func copyReport() {
    UIPasteboard.general.string = report()
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
