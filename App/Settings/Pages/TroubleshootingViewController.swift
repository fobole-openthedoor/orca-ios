import OrcaCore
import UIKit
import UserNotifications

/// Settings › Troubleshooting (app/troubleshoot.tsx): run the official checks (paired desktops, internet, each
/// desktop, platform) plus this phone's push state, read the common fixes, and reset pairing.
final class TroubleshootingViewController: SettingsPageViewController {
  private struct Check {
    enum Status { case pass, warn, fail }
    let label: String
    let status: Status
    let detail: String
  }

  private struct Issue {
    let icon: Lucide
    let title: String
    let steps: [String]
  }

  private enum RunState { case idle, running, done }

  private let model = AppModel.shared
  private var state = RunState.idle
  private var checks: [Check] = []
  private var expanded: String?
  private var run: Task<Void, Never>?
  private let runCell = RunDiagnosticsCell()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "diagnostics.troubleshootView.title", defaultValue: "Troubleshooting")
    runCell.onRun = { [weak self] in self?.runDiagnostics() }
    rebuild()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent { run?.cancel() }
  }

  private func rebuild() {
    let runTitle =
      switch state {
      case .idle: String(localized: "diagnostics.troubleshootView.runDiagnostics", defaultValue: "Run diagnostics")
      case .running: String(localized: "diagnostics.troubleshootView.running", defaultValue: "Running…")
      case .done: String(localized: "diagnostics.troubleshootView.runAgain", defaultValue: "Run again")
      }
    runCell.show(title: runTitle, running: state == .running)
    var sections = [Section(rows: [.custom(runCell)])]
    if !checks.isEmpty {
      sections.append(
        Section(
          rows: checks.map { check in
            let (icon, color): (Lucide, UIColor) =
              switch check.status {
              case .pass: (.circleCheck, Palette.statusGreen)
              case .warn: (.triangleAlert, Palette.textMuted)
              case .fail: (.circleX, Palette.statusRed)
              }
            return .status(
              icon: icon, color: color, title: check.label, detail: check.detail,
              detailColor: check.status == .fail ? Palette.statusRed : nil)
          }))
    }
    var issueRows: [Row] = []
    for issue in Self.commonIssues(ports: ports()) {
      let open = expanded == issue.title
      issueRows.append(
        .value(icon: issue.icon, title: issue.title) { [weak self] in
          self?.expanded = open ? nil : issue.title
          self?.rebuild()
        })
      if open {
        issueRows.append(.value(title: issue.steps.map { "•  \($0)" }.joined(separator: "\n")))
      }
    }
    sections.append(
      Section(header: String(localized: "diagnostics.troubleshootView.commonIssues", defaultValue: "Common issues"), rows: issueRows))
    sections.append(
      Section(rows: [
        .button(
          title: String(localized: "orcaios.troubleshoot.resetPairing", defaultValue: "Remove all paired desktops"),
          destructive: true, enabled: !model.hosts.isEmpty
        ) { [weak self] in self?.confirmReset() }
      ]))
    self.sections = sections
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = super.tableView(tableView, cellForRowAt: indexPath)
    guard case .value(_, let title, _, _, _, _, _) = sections[indexPath.section].rows[indexPath.row] else { return cell }
    if title.hasPrefix("•"), var content = cell.contentConfiguration as? UIListContentConfiguration {
      // The expanded steps wrap over several lines.
      content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
      content.textProperties.color = Palette.textSecondary
      content.textProperties.numberOfLines = 0
      cell.contentConfiguration = content
    } else if indexPath.section == sections.count - 2 {
      // A common issue: a chevron that says whether its steps are showing.
      let chevron = UIImageView(image: (expanded == title ? Lucide.chevronUp : Lucide.chevronDown).image(size: 16))
      chevron.tintColor = Palette.textMuted
      cell.accessoryView = chevron
    }
    return cell
  }

  // MARK: Checks

  private func runDiagnostics() {
    guard state != .running else { return }
    state = .running
    checks = []
    rebuild()
    run = Task { [weak self] in
      guard let self else { return }
      let hosts = model.orderedHosts
      append(
        hosts.isEmpty
          ? Check(
            label: String(localized: "diagnostics.useTroubleshootDiagnostics.pairedHosts", defaultValue: "Paired hosts"),
            status: .fail,
            detail: String(localized: "diagnostics.useTroubleshootDiagnostics.noPairedHosts", defaultValue: "None — scan a QR to pair"))
          : Check(
            label: String(localized: "diagnostics.useTroubleshootDiagnostics.pairedHosts", defaultValue: "Paired hosts"),
            status: .pass,
            detail: String(localized: "diagnostics.useTroubleshootDiagnostics.pairedCount", defaultValue: "\(hosts.count) paired")))
      append(await internetCheck())
      guard !Task.isCancelled else { return }
      for host in hosts {
        guard let session = model.session(for: host.id) else { continue }
        append(await hostCheck(session))
        guard !Task.isCancelled else { return }
      }
      append(await pushCheck())
      append(
        Check(
          label: String(localized: "diagnostics.useTroubleshootDiagnostics.platform", defaultValue: "Platform"),
          status: .pass, detail: "iOS \(UIDevice.current.systemVersion)"))
      state = .done
      rebuild()
    }
  }

  private func append(_ check: Check) {
    checks.append(check)
    rebuild()
  }

  private func internetCheck() async -> Check {
    let label = String(localized: "diagnostics.useTroubleshootDiagnostics.internet", defaultValue: "Internet")
    var request = URLRequest(url: URL(string: "https://dns.google/resolve?name=example.com&type=A")!)
    request.timeoutInterval = 5
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
      return ok
        ? Check(label: label, status: .pass, detail: String(localized: "diagnostics.useTroubleshootDiagnostics.connected", defaultValue: "Connected"))
        : Check(
          label: label, status: .warn,
          detail: String(localized: "diagnostics.useTroubleshootDiagnostics.unexpectedResponse", defaultValue: "Unexpected response"))
    } catch {
      return Check(label: label, status: .fail, detail: String(localized: "diagnostics.useTroubleshootDiagnostics.noConnection", defaultValue: "No connection"))
    }
  }

  /// A connected desktop must also answer `status.get`; otherwise its connection state is the finding.
  private func hostCheck(_ session: HostSession) async -> Check {
    let presentation = HostConnectionPresentation(session.connectionState)
    let endpoint = URL(string: session.host.endpoint).flatMap { url in url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } }
      ?? session.host.endpoint
    guard session.connectionState == .connected else {
      return Check(label: session.name, status: .fail, detail: "\(presentation.label) · \(endpoint)")
    }
    do {
      _ = try await session.api.status()
      return Check(
        label: session.name, status: .pass,
        detail: String(
          format: String(localized: "diagnostics.useTroubleshootDiagnostics.reachable", defaultValue: "Reachable at %1$@"),
          endpoint))
    } catch {
      return Check(
        label: session.name, status: .warn,
        detail: String(localized: "common.loadError.unreachable", defaultValue: "Couldn't reach the desktop. Try again."))
    }
  }

  private func pushCheck() async -> Check {
    let label = String(localized: "diagnostics.troubleshootCommonIssues.notificationsTitle", defaultValue: "Push Notifications")
    guard PushCenter.Settings.current.enabled else {
      return Check(
        label: label, status: .warn,
        detail: String(
          localized: "settings.notificationDisplayTest.disabled",
          defaultValue: "Notifications are turned off in Orca. Enable notifications and try again."))
    }
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .denied:
      return Check(
        label: label, status: .fail,
        detail: String(
          localized: "settings.notificationDisplayTest.osDisabled",
          defaultValue: "Notifications are turned off in system settings. Allow notifications and try again."))
    case .notDetermined:
      return Check(label: label, status: .warn, detail: String(localized: "orcaios.troubleshoot.pushNotAsked", defaultValue: "Not asked yet"))
    default:
      guard UIApplication.shared.isRegisteredForRemoteNotifications else {
        return Check(
          label: label, status: .warn,
          detail: String(localized: "orcaios.troubleshoot.pushNoToken", defaultValue: "Allowed, no push token yet"))
      }
      // The token alone isn't delivery: a desktop has to take the registration too.
      guard PushCenter.shared.registeredDesktops > 0 else {
        return Check(
          label: label, status: .warn,
          detail: String(
            localized: "settings.notificationDisplayTest.registrationPending",
            defaultValue: "Push registration for this desktop is not ready yet. Try again shortly."))
      }
      return Check(
        label: label, status: .pass,
        detail: String(localized: "orcaios.troubleshoot.pushReady", defaultValue: "Allowed, push token received"))
    }
  }

  // MARK: Reset

  private func confirmReset() {
    let alert = UIAlertController(
      title: String(localized: "orcaios.troubleshoot.resetPairing", defaultValue: "Remove all paired desktops"),
      message: String(
        localized: "orcaios.troubleshoot.resetPairingMessage",
        defaultValue: "Every paired desktop and its saved credentials are removed from this phone. You can pair again later."),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(
        title: String(localized: "orcaios.troubleshoot.resetPairingConfirm", defaultValue: "Remove all"), style: .destructive
      ) { [weak self] _ in self?.resetPairing() })
    present(alert, animated: true)
  }

  private func resetPairing() {
    Task {
      do {
        for host in model.hosts { try await model.remove(host.id) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        showAlert(
          title: String(localized: "home.screen.removeHostFailed", defaultValue: "Could not remove host"),
          message: error.localizedDescription)
      }
      checks = []
      state = .idle
      rebuild()
    }
  }

  // MARK: Common issues

  /// The desktops' ports, for the firewall advice; 6768 when none can be read.
  private func ports() -> [String] {
    var ports: [String] = []
    for host in model.orderedHosts {
      let url = URL(string: host.endpoint)
      let port = url?.port.map(String.init) ?? (url?.scheme == "wss" ? "443" : url?.scheme == "ws" ? "80" : "6768")
      if !ports.contains(port) { ports.append(port) }
    }
    return ports.isEmpty ? ["6768"] : ports
  }

  private static func commonIssues(ports: [String]) -> [Issue] {
    var issues = [
      Issue(
        icon: .bell,
        title: String(localized: "diagnostics.troubleshootCommonIssues.notificationsTitle", defaultValue: "Push Notifications"),
        steps: [
          String(
            localized: "diagnostics.troubleshootCommonIssues.allowNotifications",
            defaultValue: "Check that system settings allow Orca notifications and that Focus or Do Not Disturb is off."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.notificationNetwork",
            defaultValue:
              "Try cellular or another Wi-Fi network. If alerts arrive after switching, your network may be delaying delivery."),
        ]),
      Issue(
        icon: .wifiOff,
        title: String(localized: "diagnostics.troubleshootCommonIssues.wifiTitle", defaultValue: "Different WiFi Networks"),
        steps: [
          String(
            localized: "diagnostics.troubleshootCommonIssues.sameNetwork",
            defaultValue: "Both devices must be on the same LAN (unless connected through Tailscale)."),
          String(localized: "diagnostics.troubleshootCommonIssues.sameSubnet", defaultValue: "Ethernet and WiFi must share the same subnet."),
          String(localized: "diagnostics.troubleshootCommonIssues.reconnectWifi", defaultValue: "Try reconnecting WiFi on both devices."),
        ]),
    ]
    for port in ports {
      issues.append(
        Issue(
          icon: .shield,
          title: String(
            format: String(localized: "diagnostics.troubleshootCommonIssues.firewallTitle", defaultValue: "Firewall Blocking Port %1$@"),
            port),
          steps: [
            String(
              localized: "diagnostics.troubleshootCommonIssues.macosFirewall",
              defaultValue: "macOS: System Settings → Network → Firewall — allow Orca."),
            String(
              localized: "diagnostics.troubleshootCommonIssues.windowsFirewall",
              defaultValue: "Windows: Defender Firewall → Allow app — enable Orca for Private networks."),
            String(
              format: String(localized: "diagnostics.troubleshootCommonIssues.linuxFirewall", defaultValue: "Linux: sudo ufw allow %1$@"),
              port),
            String(
              localized: "diagnostics.troubleshootCommonIssues.restrictedNetwork",
              defaultValue: "Corporate/school networks may block P2P — try a personal hotspot."),
          ]))
    }
    issues += [
      Issue(
        icon: .monitor,
        title: String(localized: "diagnostics.troubleshootCommonIssues.desktopTitle", defaultValue: "Desktop App Not Running"),
        steps: [
          String(
            localized: "diagnostics.troubleshootCommonIssues.openDesktop",
            defaultValue: "Orca must be open on your desktop to accept connections."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.restartDesktop",
            defaultValue: "Try restarting Orca — the companion server starts on launch."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.pairAfterUpdate",
            defaultValue: "After an update, you may need to re-pair via QR code."),
        ]),
      Issue(
        icon: .clock,
        title: String(localized: "diagnostics.troubleshootCommonIssues.timeoutTitle", defaultValue: "Connection Timeout"),
        steps: [
          String(localized: "diagnostics.troubleshootCommonIssues.wifiSignal", defaultValue: "Check WiFi signal strength on your phone."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.retryHost", defaultValue: "Go back to the host list and tap your host to retry."),
          String(localized: "diagnostics.troubleshootCommonIssues.restartBothApps", defaultValue: "Restart both apps if timeouts persist."),
        ]),
      Issue(
        icon: .globe,
        title: String(localized: "diagnostics.troubleshootCommonIssues.tailscaleTitle", defaultValue: "Tailscale Host Unreachable"),
        steps: [
          String(
            localized: "diagnostics.troubleshootCommonIssues.keepTailscaleOn",
            defaultValue: "Host addresses like 100.x.x.x or *.ts.net connect through Tailscale — keep it ON."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.restartTailscale",
            defaultValue: "iOS/Android can silently wedge the tunnel: toggle Tailscale off and back on in the Tailscale app."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.checkTailnet",
            defaultValue: "Check the desktop is awake and shows as connected in your tailnet."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.updateTailscale",
            defaultValue: "Update the Tailscale app — recent releases fix reconnect bugs."),
        ]),
      Issue(
        icon: .shield,
        title: String(localized: "diagnostics.troubleshootCommonIssues.vpnTitle", defaultValue: "Other VPN Interference"),
        steps: [
          String(
            localized: "diagnostics.troubleshootCommonIssues.vpnRouting",
            defaultValue: "Non-Tailscale VPNs can route local traffic through a remote server."),
          String(
            localized: "diagnostics.troubleshootCommonIssues.disableVpn", defaultValue: "Disable that VPN or enable split tunneling / \"Allow LAN\"."),
        ]),
    ]
    return issues
  }
}

/// The official "Run diagnostics" button: centred on the raised fill, the Activity icon or a spinner before
/// its label, faded while it runs.
private final class RunDiagnosticsCell: UITableViewCell {
  var onRun: (() -> Void)?
  private let button = UIButton(type: .system)

  init() {
    super.init(style: .default, reuseIdentifier: nil)
    backgroundColor = Palette.bgRaised
    selectionStyle = .none
    var configuration = UIButton.Configuration.plain()
    configuration.image = Lucide.activity.image(size: 16).withRenderingMode(.alwaysTemplate)
    configuration.imagePadding = Spacing.sm
    configuration.baseForegroundColor = Palette.textPrimary
    configuration.contentInsets = NSDirectionalEdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg)
    button.configuration = configuration
    button.addAction(UIAction { [weak self] _ in self?.onRun?() }, for: .primaryActionTriggered)
    button.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: contentView.topAnchor),
      button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(title: String, running: Bool) {
    guard var configuration = button.configuration else { return }
    configuration.attributedTitle = AttributedString(
      title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: Typography.bodySize, weight: .semibold)]))
    configuration.showsActivityIndicator = running
    button.configuration = configuration
    // Not disabled: a disabled button greys its label, and the official one only fades.
    button.isUserInteractionEnabled = !running
    contentView.alpha = running ? Feedback.disabledOpacity : 1
    button.accessibilityTraits = running ? [.button, .notEnabled] : .button
  }
}
