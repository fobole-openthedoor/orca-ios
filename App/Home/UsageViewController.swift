import OrcaCore
import UIKit

/// The Usage tab (home/tabs/MobileHomeUsageTab.tsx): one desktop at a time, its stats, then each agent's
/// account with its 5-hour and 7-day limits.
final class UsageViewController: UIViewController {
  private let model = AppModel.shared
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let hostButton = UIButton(configuration: .glass())
  private var hostId: PairedHost.ID?
  private var stats: StatsSummary?
  private var accounts: AccountsSnapshot?
  private var loadedAt: Date?
  private var loading = false
  private var refresh: UIBarButtonItem!

  override func viewDidLoad() {
    super.viewDidLoad()
    title = HomeTab.usage.title
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .always
    refresh = UIBarButtonItem(
      image: Lucide.refreshCw.image(size: 20, strokeWidth: 2), primaryAction: UIAction { [weak self] _ in self?.load() })
    refresh.accessibilityLabel = String(localized: "home.usage.refresh", defaultValue: "Refresh usage")
    navigationItem.rightBarButtonItem = refresh

    scroll.alwaysBounceVertical = true
    scroll.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.load() })
    view.addSubview(scroll)
    scroll.pin(to: view)
    stack.axis = .vertical
    stack.spacing = 0
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.xs),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
    ])
    hostButton.configuration?.cornerStyle = .capsule
    hostButton.configuration?.baseForegroundColor = Palette.textPrimary
    hostButton.showsMenuAsPrimaryAction = true
    hostButton.contentHorizontalAlignment = .leading
  }

  override func updateProperties() {
    super.updateProperties()
    let hosts = model.orderedHosts
    if hostId == nil || !hosts.contains(where: { $0.id == hostId }) {
      hostId = hosts.first?.id
      stats = nil
      accounts = nil
    }
    // Read once the chosen desktop is connected, and again whenever it reconnects.
    let connected = session?.connectionState == .connected
    if connected, stats == nil, accounts == nil, !loading { load() }
    render()
  }

  private var session: HostSession? { hostId.flatMap(model.session(for:)) }

  private func load() {
    guard let session, session.connectionState == .connected else {
      scroll.refreshControl?.endRefreshing()
      return
    }
    let api = session.api
    loading = true
    Task {
      async let stats = api.stats()
      async let accounts = api.accounts()
      do { self.stats = try await stats } catch { print("[usage] stats.summary failed:", error) }
      do { self.accounts = try await accounts } catch { print("[usage] accounts.list failed:", error) }
      loading = false
      loadedAt = Date()
      scroll.refreshControl?.endRefreshing()
      render()
    }
  }

  private func render() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard let session else { return }

    // The desktop picker: a glass pill with the connection dot, choosing between paired desktops.
    let status = HostConnectionPresentation(session.connectionState)
    var title = AttributedString("● ", attributes: AttributeContainer([.foregroundColor: status.dot, .font: UIFont.systemFont(ofSize: 11)]))
    title += AttributedString(session.name, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16)]))
    hostButton.configuration?.attributedTitle = title
    hostButton.menu = UIMenu(
      children: model.orderedHosts.map { host in
        UIAction(title: model.session(for: host.id)?.name ?? host.name, state: host.id == hostId ? .on : .off) {
          [weak self] _ in
          self?.hostId = host.id
          self?.stats = nil
          self?.accounts = nil
          self?.load()
          self?.render()
        }
      })
    let hostRow = UIView()
    hostRow.addSubview(hostButton)
    hostButton.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostButton.leadingAnchor.constraint(equalTo: hostRow.leadingAnchor),
      hostButton.topAnchor.constraint(equalTo: hostRow.topAnchor),
      hostButton.bottomAnchor.constraint(equalTo: hostRow.bottomAnchor),
    ])
    stack.addArrangedSubview(hostRow)

    stack.addArrangedSubview(heading(String(localized: "home.stats.heading", defaultValue: "Your stats"), aside: nil, top: 20))
    stack.addArrangedSubview(StatsCard(stats: stats))

    for (provider, label, mark) in [("claude", "Claude Code", AgentMark.claude), ("codex", "Codex", AgentMark.codex)] {
      // A provider shows once the desktop has limits for it (home-usage-cards.ts).
      guard let accounts, let entry = provider == "claude" ? accounts.claude : accounts.codex as ProviderAccounts?,
        entry.usage?.session != nil || entry.usage?.weekly != nil
      else { continue }
      let aside = entry.usage?.updatedAt.map { updated -> String in
        let seconds = Date().timeIntervalSince1970 - updated / 1000
        guard seconds >= 60 else { return String(localized: "home.usage.updatedJustNow", defaultValue: "Updated just now") }
        return String(
          format: String(localized: "home.usage.updatedAgo", defaultValue: "Updated %1$@ ago"), RelativeTime.short(updated) ?? "")
      }
      stack.addArrangedSubview(heading(label, aside: aside, top: 28))
      stack.addArrangedSubview(AccountCard(provider: entry, mark: mark))
    }
  }

  private func heading(_ text: String, aside: String?, top: CGFloat) -> UIView {
    let row = UIView()
    let label = TextLabel(text, size: 16, weight: .semibold)
    row.addSubview(label)
    var constraints = [
      label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Spacing.xs),
      label.topAnchor.constraint(equalTo: row.topAnchor, constant: top),
      label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Spacing.sm),
    ]
    if let aside {
      let note = TextLabel(aside, size: 14, color: Palette.textMuted)
      row.addSubview(note)
      constraints += [
        note.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Spacing.xs),
        note.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
      ]
    }
    NSLayoutConstraint.activate(constraints)
    return row
  }
}

/// Agents spawned · Agent time · PRs created, in three cells with hairlines between.
private final class StatsCard: UIView {
  init(stats: StatsSummary?) {
    super.init(frame: .zero)
    backgroundColor = Palette.bgPanel
    layer.cornerRadius = Radius.surface
    // home/MobileHomeStats.tsx: minutes, then hours, then days.
    let minutes = Int((stats?.agentTimeMs ?? 0) / 60_000)
    let time: String =
      minutes >= 24 * 60
      ? String(format: String(localized: "home.stats.days", defaultValue: "%1$@ d"), "\(minutes / (24 * 60))")
      : minutes >= 60
        ? String(format: String(localized: "home.stats.hours", defaultValue: "%1$@ h"), "\(minutes / 60)")
        : String(format: String(localized: "home.stats.minutes", defaultValue: "%1$@ min"), "\(minutes)")
    let cells: [(String, String)] = [
      (stats.map { "\($0.agentsSpawned)" } ?? "–", String(localized: "home.stats.agentsSpawned", defaultValue: "Agents spawned")),
      (stats == nil ? "–" : time, String(localized: "home.stats.agentTime", defaultValue: "Agent time")),
      (stats.map { "\($0.prsCreated)" } ?? "–", String(localized: "home.stats.prsCreated", defaultValue: "PRs created")),
    ]
    let row = UIStackView()
    row.distribution = .fillEqually
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    row.pin(to: self)
    for (index, (value, label)) in cells.enumerated() {
      let cell = UIView()
      let number = TextLabel(value, size: 22, weight: .bold, alignment: .center, tabular: true)
      let caption = TextLabel(label, size: 14, color: Palette.textSecondary, alignment: .center)
      cell.addSubview(number)
      cell.addSubview(caption)
      NSLayoutConstraint.activate([
        number.topAnchor.constraint(equalTo: cell.topAnchor, constant: 14),
        number.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
        caption.topAnchor.constraint(equalTo: number.bottomAnchor, constant: 4),
        caption.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
        caption.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -14),
      ])
      if index > 0 {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = Palette.borderSubtle
        cell.addSubview(line)
        NSLayoutConstraint.activate([
          line.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
          line.topAnchor.constraint(equalTo: cell.topAnchor),
          line.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
          line.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
      }
      row.addArrangedSubview(cell)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// An agent's account card: who it signs in as, In use, and a bar per limit window.
private final class AccountCard: UIView {
  init(provider: ProviderAccounts, mark: FilledIcon) {
    super.init(frame: .zero)
    backgroundColor = Palette.bgPanel
    layer.cornerRadius = Radius.surface
    let column = UIStackView()
    column.axis = .vertical
    column.spacing = Spacing.sm
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    column.pin(to: self, insets: UIEdgeInsets(top: Spacing.lg, left: Spacing.lg, bottom: Spacing.lg, right: Spacing.lg))

    // The active account; none set means the agent's own login.
    let active = provider.accounts.first { $0.id == provider.activeAccountId }
    let tile = UIView()
    tile.translatesAutoresizingMaskIntoConstraints = false
    tile.backgroundColor = Palette.bgRaised
    tile.layer.cornerRadius = Radius.tile
    let icon = FilledIconView(size: 18)
    icon.icon = mark
    tile.addSubview(icon)
    let name = TextLabel(
      active?.displayName ?? active?.email ?? String(localized: "accounts.screen.default", defaultValue: "System default"),
      size: 16, lineHeight: 20)
    let detail = TextLabel(
      active == nil ? String(localized: "accounts.screen.agentLogin", defaultValue: "Uses the agent's own login") : active!.email,
      size: 14, color: Palette.textSecondary, lineHeight: 18)
    let names = UIStackView(arrangedSubviews: [name, detail])
    names.axis = .vertical
    names.spacing = 1
    let pill = PaddedLabel(String(localized: "home.usage.active", defaultValue: "In use"))
    let header = UIStackView(arrangedSubviews: [tile, names, UIView(), pill])
    header.alignment = .center
    header.spacing = Spacing.md
    NSLayoutConstraint.activate([
      tile.widthAnchor.constraint(equalToConstant: 30), tile.heightAnchor.constraint(equalToConstant: 30),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
    ])
    column.addArrangedSubview(header)
    column.setCustomSpacing(Spacing.md, after: header)

    for (window, label) in [
      (provider.usage?.session, String(localized: "accounts.screen.sessionWindow", defaultValue: "5h")),
      (provider.usage?.weekly, String(localized: "accounts.screen.weeklyWindow", defaultValue: "7d")),
    ] {
      guard let window else { continue }
      column.addArrangedSubview(UsageBarRow(label: label, window: window))
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A limit window (accounts/usage/UsageBar.tsx): its name, the bar coloured by how much is used, the percent,
/// and when it resets.
private final class UsageBarRow: UIView {
  init(label: String, window: UsageWindow) {
    super.init(frame: .zero)
    let name = TextLabel(label, size: 15, color: Palette.textSecondary, lines: 2)
    let track = UIView()
    track.translatesAutoresizingMaskIntoConstraints = false
    track.backgroundColor = Palette.bgRaised
    track.layer.cornerRadius = 4
    let fill = UIView()
    fill.translatesAutoresizingMaskIntoConstraints = false
    fill.layer.cornerRadius = 4
    // UsageBar.tsx: rounded and clamped first, then green under 60, amber under 80, red from 80.
    let used = min(100, max(0, window.usedPercent.rounded()))
    fill.backgroundColor = used >= 80 ? Palette.statusRed : used >= 60 ? Palette.statusAmber : Palette.statusGreen
    track.addSubview(fill)
    let percent = TextLabel("\(Int(window.usedPercent.rounded()))%", size: 15, alignment: .right, tabular: true)
    let reset = TextLabel(Self.resetText(window), size: 14, color: Palette.textMuted)
    for view in [name, track, percent, reset] as [UIView] { addSubview(view) }
    NSLayoutConstraint.activate([
      name.leadingAnchor.constraint(equalTo: leadingAnchor),
      name.topAnchor.constraint(equalTo: topAnchor),
      name.widthAnchor.constraint(equalToConstant: 36),
      track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
      track.centerYAnchor.constraint(equalTo: percent.centerYAnchor),
      track.heightAnchor.constraint(equalToConstant: 8),
      track.trailingAnchor.constraint(equalTo: percent.leadingAnchor, constant: -Spacing.lg),
      percent.trailingAnchor.constraint(equalTo: trailingAnchor),
      percent.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      percent.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
      fill.topAnchor.constraint(equalTo: track.topAnchor),
      fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
      fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.001, window.usedPercent / 100)),
      reset.leadingAnchor.constraint(equalTo: track.leadingAnchor),
      reset.topAnchor.constraint(equalTo: percent.bottomAnchor, constant: 6),
      reset.bottomAnchor.constraint(equalTo: bottomAnchor),
      name.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private static func resetText(_ window: UsageWindow) -> String {
    // The countdown from resetsAt, as the official bar reads; the host's own wording only without it.
    guard let resetsAt = window.resetsAt else { return window.resetDescription ?? "" }
    let minutes = max(0, Int((resetsAt / 1000 - Date().timeIntervalSince1970) / 60))
    guard minutes >= 60 else {
      return String(format: String(localized: "orcaios.usage.resetsInMinutes", defaultValue: "Resets in %1$@m"), "\(minutes)")
    }
    return String(
      format: String(localized: "orcaios.usage.resetsInHours", defaultValue: "Resets in %1$@h %2$@m"), "\(minutes / 60)",
      "\(minutes % 60)")
  }
}

/// A small tinted label pill, as the official In use tag.
final class PaddedLabel: UIView {
  init(_ text: String, color: UIColor = Palette.accentBlue) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = color.withAlphaComponent(0.16)
    layer.cornerRadius = 11
    let label = TextLabel(text, size: 14, weight: .medium, color: color)
    addSubview(label)
    label.pin(to: self, insets: UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10))
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension UsageViewController: HostScoped {
  func show(hostId: PairedHost.ID) {
    guard self.hostId != hostId else { return }
    self.hostId = hostId
    stats = nil
    accounts = nil
    setNeedsUpdateProperties()
  }
}
