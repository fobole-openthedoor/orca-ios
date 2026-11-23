import OrcaCore
import UIKit

/// A desktop's Accounts page (`/h/<id>/accounts`, accounts/MobileAccountsScreen.tsx): Claude's and Codex's
/// accounts as picker groups, System default first, each with its usage windows and a check on the selected one;
/// then every other agent's usage, and where to add accounts.
final class HostAccountsViewController: UIViewController {
  private let session: HostSession
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let stateView = AccountsStateView()
  private var snapshot: AccountsSnapshot?
  private var loadError: String?
  private var loading = false
  /// The row being switched to: an account id, or `<provider>:default`.
  private var switching: String?
  private var wasConnected = false
  private var refreshItem: UIBarButtonItem!
  private var clock: Timer?

  init(session: HostSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var connected: Bool { session.connectionState == .connected }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    title = String(localized: "accounts.screen.title", defaultValue: "Accounts")
    navigationItem.largeTitleDisplayMode = .never
    refreshItem = UIBarButtonItem(
      image: Lucide.refreshCw.image(size: 20, strokeWidth: 2), primaryAction: UIAction { [weak self] _ in self?.load() })
    refreshItem.accessibilityLabel = String(localized: "accounts.screen.refreshAccounts", defaultValue: "Refresh accounts")
    navigationItem.rightBarButtonItem = refreshItem
    NotificationCenter.default.addObserver(forName: UsagePercentageDisplay.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.render() }
    }

    scroll.alwaysBounceVertical = true
    view.addSubview(scroll)
    scroll.pin(to: view)
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    stateView.onAction = { [weak self] in self?.load() }
    view.addSubview(stateView)
    NSLayoutConstraint.activate([
      // mobile-accounts-screen-styles.ts scroll: 16 at the sides, 8 above, 24 below.
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.sm),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.xl),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.xl),
      stateView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
    ])
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Resets count down by the minute between the desktop's own pushes.
    clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.render() }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    clock?.invalidate()
  }

  override func updateProperties() {
    super.updateProperties()
    navigationItem.subtitle = session.name
    guard connected != wasConnected else { return }
    wasConnected = connected
    if connected { load() } else { render() }
  }

  // MARK: Loading and switching

  private func load() {
    guard connected, !loading else { return }
    loading = true
    render()
    let api = session.api
    Task {
      do {
        snapshot = try await api.accounts()
        loadError = nil
      } catch {
        loadError = (error as? RPCError)?.message ?? error.localizedDescription
      }
      loading = false
      render()
    }
  }

  private func select(_ provider: String, accountId: String?) {
    guard let snapshot, switching == nil else { return }
    Haptics.select()
    let accounts = provider == "claude" ? snapshot.claude : snapshot.codex
    switching = accountId ?? "\(provider):default"
    render()
    let api = session.api
    Task {
      do {
        try await api.selectAccount(provider: provider, accountId: accountId, in: accounts)
        self.snapshot = try await api.accounts()
      } catch {
        let alert = UIAlertController(
          title: String(localized: "accounts.screen.switchFailed", defaultValue: "Could not switch account"),
          message: (error as? RPCError)?.message ?? error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
      switching = nil
      render()
    }
  }

  // MARK: Drawing

  private func render() {
    guard isViewLoaded else { return }
    refreshItem.isEnabled = connected && !loading
    for view in stack.arrangedSubviews { view.removeFromSuperview() }
    // Accounts read before stay up while offline; a failed read on a live connection says so instead.
    guard let snapshot, !(connected && loadError != nil) else {
      scroll.isHidden = true
      stateView.isHidden = false
      if let loadError, connected {
        stateView.show(
          icon: .circleAlert, title: loadError, message: nil,
          action: String(localized: "common.retry", defaultValue: "Retry"))
      } else if case .authFailed = session.connectionState {
        stateView.show(
          icon: .circleAlert, title: String(localized: "components.hostCard.pairingInvalid", defaultValue: "Pairing invalid"),
          message: String(
            localized: "accounts.screen.pairingInvalidMessage",
            defaultValue: "Re-pair this phone with your desktop to see its accounts."))
      } else if case .disconnected = session.connectionState {
        offline()
      } else if case .reconnecting = session.connectionState {
        offline()
      } else if !connected {
        stateView.show(
          loading: true,
          title: String(
            format: String(localized: "accounts.screen.connectingTo", defaultValue: "Connecting to %1$@…"), session.name))
      } else {
        stateView.show(loading: true, title: String(localized: "accounts.screen.loadingAccounts", defaultValue: "Loading accounts…"))
      }
      return
    }
    scroll.isHidden = false
    stateView.isHidden = true
    let now = Date().timeIntervalSince1970 * 1000
    stack.addArrangedSubview(providerSection("claude", snapshot.claude, snapshot: snapshot, now: now))
    stack.addArrangedSubview(providerSection("codex", snapshot.codex, snapshot: snapshot, now: now))
    if !snapshot.others.isEmpty {
      stack.addArrangedSubview(
        AccountsSectionHeader(title: String(localized: "accounts.screen.otherAgents", defaultValue: "Other agents"), mark: nil))
      stack.addArrangedSubview(
        AccountsGroup(
          rows: snapshot.others.map { usage in
            AccountRow(
              title: Self.providerName(usage.provider), subtitle: nil, mark: AgentMark.icon(for: usage.provider),
              windows: UsageWindowsView(usage: usage, fetching: nil, showsEmpty: false, now: now),
              note: usage.error, selected: nil, busy: false, onPress: nil)
          }))
    }

    // Add or re-authenticate accounts from desktop Settings → Accounts.
    let hint = UIStackView(arrangedSubviews: [
      LucideView(.user, size: 14, color: Palette.textMuted),
      TextLabel(
        String(
          localized: "accounts.screen.manageAccountsHint",
          defaultValue: "Add or re-authenticate accounts from desktop Settings → Accounts."),
        size: Typography.metaSize, color: Palette.textMuted, lineHeight: 18, lines: 0),
    ])
    hint.alignment = .top
    hint.spacing = Spacing.sm
    hint.isLayoutMarginsRelativeArrangement = true
    hint.directionalLayoutMargins = .init(top: Spacing.md, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg)
    stack.addArrangedSubview(hint)
  }

  private func offline() {
    stateView.show(
      icon: .wifiOff,
      title: String(format: String(localized: "common.offline.waitingFor", defaultValue: "Waiting for %1$@"), session.name),
      message: String(localized: "common.offline.message", defaultValue: "Check that the host is awake and Orca is running."))
  }

  /// A provider's picker group: System default, then each saved account, the selected one checked.
  private func providerSection(_ provider: String, _ accounts: ProviderAccounts, snapshot: AccountsSnapshot, now: Double)
    -> UIView
  {
    let selectedId = accounts.selectedAccountId
    // Stored rows may name a selection the desktop has since changed, so switching waits for a live read.
    let blocked = switching != nil || !connected || loading
    // System default's reading: live while selected, else the one the host keeps for Claude's own login.
    let defaultUsage: (usage: ProviderUsage?, fetching: Bool) =
      selectedId == nil
      ? (accounts.usage, accounts.usage?.status == "fetching")
      : provider == "claude"
        ? accounts.inactiveUsage(AccountsSnapshot.claudeSystemDefaultUsageId).map { ($0.usage, $0.isFetching) } ?? (nil, false)
        : (nil, false)
    let showsDefaultUsage = defaultUsage.usage.map { $0.hasUsageData || $0.status == "ok" } ?? false
    var rows = [
      AccountRow(
        title: String(localized: "accounts.screen.default", defaultValue: "System default"),
        subtitle: String(localized: "accounts.screen.agentLogin", defaultValue: "Use the agent's own login"), mark: nil,
        windows: showsDefaultUsage
          ? UsageWindowsView(usage: defaultUsage.usage, fetching: defaultUsage.fetching, showsEmpty: true, now: now) : nil,
        note: nil, selected: selectedId == nil, busy: switching == "\(provider):default",
        onPress: blocked ? nil : { [weak self] in self?.select(provider, accountId: nil) })
    ]
    for account in accounts.accounts {
      let active = account.id == selectedId
      let inactive = active ? nil : accounts.inactiveUsage(account.id)
      let usage = active ? accounts.usage : inactive?.usage
      let fetching = active ? usage?.status == "fetching" : inactive?.isFetching == true
      let title = account.primaryLabel
      let detail = provider == "codex" ? Self.codexDetail(account, among: accounts.accounts) : nil
      let subtitle = [title == account.email ? nil : account.email, detail].compactMap { $0 }.joined(separator: " · ")
      rows.append(
        AccountRow(
          title: title, subtitle: subtitle.isEmpty ? nil : subtitle, mark: nil,
          windows: UsageWindowsView(usage: usage, fetching: fetching, showsEmpty: true, now: now),
          note: usage?.error, selected: active, busy: switching == account.id,
          onPress: blocked || active ? nil : { [weak self] in self?.select(provider, accountId: account.id) }))
    }
    let section = UIStackView(arrangedSubviews: [
      AccountsSectionHeader(
        title: Self.providerName(provider), mark: provider == "claude" ? AgentMark.claude : AgentMark.codex,
        first: provider == "claude"),
      AccountsGroup(rows: rows),
    ])
    section.axis = .vertical
    return section
  }

  /// Desktop's names for usage providers (usage-provider-windows.ts); a newer host's provider reads as its id.
  static func providerName(_ provider: String) -> String {
    [
      "claude": "Claude", "codex": "Codex", "gemini": "Gemini", "opencode-go": "OpenCode Go", "kimi": "Kimi",
      "antigravity": "Antigravity", "minimax": "MiniMax", "grok": "Grok", "zcode": "ZCode", "cursor": "Cursor", "muse": "Muse",
    ][provider] ?? provider
  }

  /// What tells Codex logins sharing an email apart: the workspace, else enough of the id (getCodexAccountDisplayDetail).
  static func codexDetail(_ account: AgentAccount, among accounts: [AgentAccount]) -> String? {
    func normalized(_ email: String) -> String { email.trimmingCharacters(in: .whitespaces).lowercased() }
    func label(_ account: AgentAccount) -> String? {
      let trimmed = account.workspaceLabel?.trimmingCharacters(in: .whitespaces) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }
    let workspace = label(account)
    let peers = accounts.filter { $0.id != account.id && normalized($0.email) == normalized(account.email) }
    let workspaces = [workspace] + peers.map(label)
    if peers.isEmpty || (workspaces.allSatisfy { $0 != nil } && Set(workspaces).count == workspaces.count) { return workspace }
    var length = min(8, account.id.count)
    while length < account.id.count, peers.contains(where: { $0.id.prefix(length) == account.id.prefix(length) }) { length += 1 }
    let identifier = String(account.id.prefix(length))
    return workspace.map { "\($0) · \(identifier)" } ?? identifier
  }
}

/// A section's label above a group (ListGroup.tsx SectionHeader): an optional 14 pt mark, then 13 pt medium
/// secondary text, 16 pt in, 16 above (4 for the first) and 6 below.
private final class AccountsSectionHeader: UIView {
  init(title: String, mark: FilledIcon?, first: Bool = false) {
    super.init(frame: .zero)
    let row = UIStackView()
    row.alignment = .center
    row.spacing = 6
    if let mark {
      let icon = FilledIconView(size: 14)
      icon.icon = mark
      row.addArrangedSubview(icon)
    }
    row.addArrangedSubview(TextLabel(title, size: 13, weight: .medium, color: Palette.textSecondary))
    addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.lg),
      row.topAnchor.constraint(equalTo: topAnchor, constant: first ? Spacing.xs : Spacing.lg),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Rows on one rounded panel with hairlines between them, 16 pt in (ListGroup).
private final class AccountsGroup: UIView {
  init(rows: [UIView]) {
    super.init(frame: .zero)
    backgroundColor = Palette.bgPanel
    layer.cornerRadius = Radius.surface
    layer.cornerCurve = .continuous
    clipsToBounds = true
    let column = UIStackView()
    column.axis = .vertical
    for (index, row) in rows.enumerated() {
      if index > 0 {
        let line = Hairline()
        let inset = UIView()
        inset.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: Spacing.lg),
          line.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
          line.topAnchor.constraint(equalTo: inset.topAnchor),
          line.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
        ])
        column.addArrangedSubview(inset)
      }
      column.addArrangedSubview(row)
    }
    addSubview(column)
    column.pin(to: self)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One account (ListGroup.tsx ListRow): the name, its email under it, the usage windows, then a spinner while
/// switching and a check on the selected one. A row that can't be picked drops its press without dimming.
private final class AccountRow: PressableControl {
  init(
    title: String, subtitle: String?, mark: FilledIcon?, windows: UIView?, note: String?, selected: Bool?, busy: Bool,
    onPress: (() -> Void)?
  ) {
    super.init(frame: .zero)
    let main = UIStackView()
    main.axis = .vertical
    main.spacing = 2
    // 15 pt, medium when a subtitle follows.
    main.addArrangedSubview(TextLabel(title, size: 15, weight: subtitle == nil ? .regular : .medium, lines: 1))
    if let subtitle { main.addArrangedSubview(TextLabel(subtitle, size: 13, color: Palette.textSecondary, lines: 2)) }
    if let windows {
      main.addArrangedSubview(windows)
      // ProviderUsageWindows: 4 pt more above the bars.
      main.setCustomSpacing(Spacing.xs + 2, after: main.arrangedSubviews[main.arrangedSubviews.count - 2])
    }
    if let note, !note.isEmpty {
      main.addArrangedSubview(TextLabel(note, size: Typography.metaSize, color: Palette.textMuted, lines: 3))
    }
    let row = UIStackView()
    row.alignment = .center
    row.spacing = Spacing.md
    row.isUserInteractionEnabled = false
    if let mark {
      let icon = FilledIconView(size: 16)
      icon.icon = mark
      let slot = UIView()
      slot.addSubview(icon)
      NSLayoutConstraint.activate([
        slot.widthAnchor.constraint(equalToConstant: 24),
        slot.heightAnchor.constraint(equalToConstant: 16),
        icon.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
        icon.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
      ])
      row.addArrangedSubview(slot)
    }
    row.addArrangedSubview(main)
    if busy {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.color = Palette.textSecondary
      spinner.startAnimating()
      row.addArrangedSubview(spinner)
    }
    if let selected {
      let check = LucideView(.check, size: 17, strokeWidth: 2.4, color: Palette.textPrimary)
      check.alpha = selected ? 1 : 0
      row.addArrangedSubview(check)
    }
    addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 48 : 60),
    ])
    self.onPress = onPress
    isUserInteractionEnabled = onPress != nil
    onPressedChange = { [weak self] pressed in self?.backgroundColor = pressed ? Palette.translucentFill : nil }
    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityTraits = selected == true ? [.button, .selected] : .button
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A provider's usage windows (ProviderUsageWindows.tsx): two to a line, a named pool on its own.
private final class UsageWindowsView: UIStackView {
  init(usage: ProviderUsage?, fetching: Bool?, showsEmpty: Bool, now: Double) {
    super.init(frame: .zero)
    axis = .vertical
    spacing = Spacing.sm
    // getUsageBarState: an idle or fetching reading still loads its empty windows.
    let loading = fetching ?? (usage?.status == "fetching" || usage?.status == "idle")
    var sections: [(label: String, window: UsageWindow?, wide: Bool)] = []
    if let usage, !usage.buckets.isEmpty {
      sections = usage.buckets.map { ($0.name, $0.window, true) }
      if let monthly = usage.monthly { sections.append((Self.length(monthly.windowMinutes), monthly, false)) }
      let weeklyRepeats =
        usage.weekly.map { weekly in
          usage.buckets.contains {
            $0.window.windowMinutes == 10_080 && $0.window.usedPercent == weekly.usedPercent && $0.window.resetsAt == weekly.resetsAt
          }
        } ?? false
      if !weeklyRepeats { sections.append((Self.length(usage.weekly?.windowMinutes ?? 10_080), usage.weekly, false)) }
    } else {
      sections = [
        (Self.length(usage?.session?.windowMinutes ?? 300), usage?.session, false),
        (Self.length(usage?.weekly?.windowMinutes ?? 10_080), usage?.weekly, false),
      ]
      if let fable = usage?.fableWeekly {
        sections.append(("FB", fable, false))
      }
      if let monthly = usage?.monthly {
        sections.append(
          (
            usage?.provider == "zcode"
              ? String(localized: "accounts.screen.mcpWindow", defaultValue: "MCP") : Self.length(monthly.windowMinutes),
            monthly, false
          ))
      }
    }
    if !showsEmpty { sections.removeAll { $0.window == nil } }

    // Two narrow windows share a line; a wide one, or the odd one out, takes a line to itself.
    var line: [UIView] = []
    func flush() {
      guard !line.isEmpty else { return }
      let row = UIStackView(arrangedSubviews: line)
      row.alignment = .top
      row.distribution = .fillEqually
      row.spacing = Spacing.md
      addArrangedSubview(row)
      line = []
    }
    for section in sections {
      let bar = UsageBarView(
        label: section.label, window: section.window, loading: loading && section.window == nil, wide: section.wide, now: now)
      if section.wide {
        flush()
        line = [bar]
        flush()
      } else {
        line.append(bar)
        if line.count == 2 { flush() }
      }
    }
    flush()
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 5h and 7d in this language; other lengths as desktop writes them (formatWindowLabel).
  private static func length(_ minutes: Int) -> String {
    switch minutes {
    case 300: return "5h"  // As the usage tab writes it, at the user's request.
    case 10_080: return "7d"
    case ..<60: return "\(minutes)m"
    case let value where value % 10_080 == 0: return "\(value / 10_080)wk"
    case let value where value % 1_440 == 0: return "\(value / 1_440)d"
    case let value where value % 60 == 0: return "\(value / 60)h"
    default: return "\(minutes)m"
    }
  }
}

/// One window (accounts/usage/UsageBar.tsx): the label, a 6 pt track filled by the shown percent in its
/// consumption colour, the value, and the reset countdown under the track.
private final class UsageBarView: UIView {
  init(label: String, window: UsageWindow?, loading: Bool, wide: Bool, now: Double) {
    super.init(frame: .zero)
    let display = UsagePercentageDisplay.current
    let used = window.map { min(100, max(0, $0.usedPercent.rounded())) }
    let shown = used.map { display == .used ? $0 : 100 - $0 }
    let name = TextLabel(label, size: Typography.metaSize, color: Palette.textMuted, lines: 1)
    let track = UIView()
    track.translatesAutoresizingMaskIntoConstraints = false
    track.backgroundColor = Palette.bgRaised
    track.layer.cornerRadius = 3
    track.clipsToBounds = true
    let fill = UIView()
    fill.translatesAutoresizingMaskIntoConstraints = false
    fill.layer.cornerRadius = 3
    // Green under 60, amber under 80, red from 80; the colour follows what is used either way.
    fill.backgroundColor =
      used.map { $0 >= 80 ? Palette.statusRed : $0 >= 60 ? Palette.statusAmber : Palette.statusGreen } ?? Palette.textMuted
    track.addSubview(fill)
    let value: UIView
    if loading {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.color = Palette.textSecondary
      spinner.startAnimating()
      spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
      value = spinner
    } else {
      let text =
        shown.map {
          display == .remaining
            ? String(format: String(localized: "accounts.usage.percentLeft", defaultValue: "%1$@%% left"), "\(Int($0))")
            : "\(Int($0))%"
        } ?? "—"
      value = TextLabel(text, size: Typography.metaSize, color: Palette.textSecondary, alignment: .right, tabular: true)
    }
    value.translatesAutoresizingMaskIntoConstraints = false
    let bar = UIView()
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(track)
    bar.addSubview(value)
    // The countdown in desktop's English (formatResetCountdown), as the official page shows it.
    let reset = window?.resetsAt.map { TextLabel(Self.countdown($0 - now), size: Typography.metaSize, color: Palette.textMuted) }
    for view in [name, bar] + (reset.map { [$0] } ?? []) as [UIView] { addSubview(view) }

    NSLayoutConstraint.activate([
      track.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      track.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      track.heightAnchor.constraint(equalToConstant: 6),
      track.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -Spacing.xs),
      value.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      value.topAnchor.constraint(equalTo: bar.topAnchor),
      value.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
      value.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
      fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
      fill.topAnchor.constraint(equalTo: track.topAnchor),
      fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
      fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.0001, (shown ?? 0) / 100)),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor),
      name.leadingAnchor.constraint(equalTo: leadingAnchor),
    ])
    if wide {
      // A long pool name sits on its own line above the track.
      NSLayoutConstraint.activate([
        name.topAnchor.constraint(equalTo: topAnchor),
        name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        bar.leadingAnchor.constraint(equalTo: leadingAnchor),
        bar.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
      ])
    } else {
      name.setContentHuggingPriority(.required, for: .horizontal)
      name.setContentCompressionResistancePriority(.required, for: .horizontal)
      NSLayoutConstraint.activate([
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        name.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        bar.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: Spacing.xs),
        bar.topAnchor.constraint(equalTo: topAnchor),
      ])
    }
    if let reset {
      NSLayoutConstraint.activate([
        reset.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
        reset.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        reset.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
        reset.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    } else {
      bar.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// "3 小时 54 分钟后重置", whole units rounded down, in the same words as the usage tab.
  private static func countdown(_ milliseconds: Double) -> String {
    let minutes = max(0, Int(milliseconds / 60_000))
    guard minutes >= 60 else {
      return String(format: String(localized: "orcaios.usage.resetsInMinutes", defaultValue: "Resets in %1$@m"), "\(minutes)")
    }
    guard minutes >= 24 * 60 else {
      return String(
        format: String(localized: "orcaios.usage.resetsInHours", defaultValue: "Resets in %1$@h %2$@m"), "\(minutes / 60)",
        "\(minutes % 60)")
    }
    return String(
      format: String(localized: "orcaios.usage.resetsInDays", defaultValue: "Resets in %1$@d %2$@h"), "\(minutes / (24 * 60))",
      "\(minutes / 60 % 24)")
  }
}

/// Accounts before its first read (MobileAccountsLoadState.tsx): connecting or loading with a spinner, offline,
/// re-pair, or a failed read with Retry.
private final class AccountsStateView: UIStackView {
  var onAction: (() -> Void)?
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let icon = LucideView(.circleAlert, size: 28, color: Palette.textMuted)
  private let title = TextLabel(size: 16, weight: .semibold, alignment: .center, lines: 0)
  private let message = TextLabel(size: Typography.bodySize, color: Palette.textSecondary, lineHeight: 20, alignment: .center, lines: 0)
  private let button = AutomationButton()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    axis = .vertical
    alignment = .center
    spacing = Spacing.sm
    spinner.color = Palette.textSecondary
    for view in [spinner, icon, title, message, button] as [UIView] { addArrangedSubview(view) }
    setCustomSpacing(Spacing.md, after: spinner)
    setCustomSpacing(Spacing.md, after: icon)
    setCustomSpacing(Spacing.lg, after: message)
    button.onPress = { [weak self] in self?.onAction?() }
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(loading: Bool = false, icon: Lucide? = nil, title: String, message: String? = nil, action: String? = nil) {
    spinner.isHidden = !loading
    if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    self.icon.isHidden = icon == nil
    if let icon { self.icon.icon = icon }
    self.title.text = title
    self.message.text = message
    self.message.isHidden = message == nil
    button.isHidden = action == nil
    button.label = action ?? ""
  }
}
