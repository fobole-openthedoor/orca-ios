import OrcaCore
import UIKit

/// The Automations tab (home/tabs/MobileHomeAutomationsTab.tsx): one desktop's scheduled agents, each with an
/// on/off switch, and + to schedule one.
final class AutomationsViewController: UIViewController {
  private let model = AppModel.shared
  private let hostButton = UIButton(configuration: .glass())
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let empty = UIStackView()
  private var hostId: PairedHost.ID?
  private var automations: [Automation] = []
  private var loadedFor: PairedHost.ID?
  /// Set when a desktop's ⋯ menu opened this page (`/h/<id>/automations`): that desktop only, no picker.
  private let pinnedHostId: PairedHost.ID?

  init(hostId: PairedHost.ID? = nil) {
    pinnedHostId = hostId
    self.hostId = hostId
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = hostId != nil
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = HomeTab.automations.title
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = pinnedHostId == nil ? .inline : .never
    let add = UIBarButtonItem(image: Lucide.plus.image(size: 20, strokeWidth: 2.2), style: .prominent, target: nil, action: nil)
    add.primaryAction = UIAction(image: Lucide.plus.image(size: 20, strokeWidth: 2.2)) { [weak self] _ in self?.edit(nil) }
    add.tintColor = Palette.createActionFill
    add.accessibilityLabel = String(localized: "home.automationsTab.newAutomation", defaultValue: "New automation")
    navigationItem.rightBarButtonItem = add

    hostButton.configuration?.cornerStyle = .capsule
    // MobileHomeHostPill.tsx: 32 pt tall, 12 pt before the dot and 10 after the name.
    hostButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: Spacing.md, bottom: 7, trailing: 10)
    hostButton.configuration?.baseForegroundColor = Palette.textPrimary
    hostButton.showsMenuAsPrimaryAction = true
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
    hostButton.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(hostButton)
    NSLayoutConstraint.activate([
      hostButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Spacing.lg),
      hostButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
    ])
    table.tableHeaderView = pinnedHostId == nil ? header : nil
    table.backgroundColor = Palette.bgBase
    table.dataSource = self
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "automation")
    table.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.load() })
    view.addSubview(table)
    table.pin(to: view)

    let icon = LucideView(.calendarClock, size: 34, strokeWidth: 1.6, color: Palette.textMuted)
    let title = TextLabel(
      String(localized: "home.automationsTab.noAutomations", defaultValue: "No automations"), size: 17, weight: .semibold,
      alignment: .center)
    let hint = TextLabel(
      String(localized: "home.automationsTab.createHint", defaultValue: "Tap + to schedule an agent."), size: 15,
      color: Palette.textSecondary, alignment: .center)
    for view in [icon, title, hint] as [UIView] { empty.addArrangedSubview(view) }
    empty.axis = .vertical
    empty.alignment = .center
    empty.spacing = 6
    empty.setCustomSpacing(Spacing.md, after: icon)
    empty.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(empty)
    NSLayoutConstraint.activate([
      empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      empty.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 160),
    ])
  }

  override func updateProperties() {
    super.updateProperties()
    let hosts = model.orderedHosts
    if pinnedHostId == nil, hostId == nil || !hosts.contains(where: { $0.id == hostId }) { hostId = hosts.first?.id }
    guard let hostId, let session = model.session(for: hostId) else { return }
    if pinnedHostId != nil {
      navigationItem.subtitle = session.name
      if session.connectionState == .connected, loadedFor != hostId { load() }
      return
    }
    let status = HostConnectionPresentation(session.connectionState)
    var title = AttributedString("● ", attributes: AttributeContainer([.foregroundColor: status.dot, .font: UIFont.systemFont(ofSize: 11)]))
    title += AttributedString(
      session.name, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14), .foregroundColor: Palette.textSecondary]))
    hostButton.configuration?.attributedTitle = title
    hostButton.menu = UIMenu(
      children: hosts.map { host in
        UIAction(title: model.session(for: host.id)?.name ?? host.name, state: host.id == hostId ? .on : .off) {
          [weak self] _ in
          self?.hostId = host.id
          self?.loadedFor = nil
          self?.setNeedsUpdateProperties()
        }
      })
    if session.connectionState == .connected, loadedFor != hostId { load() }
  }

  /// New (nil) or existing, on the host's Automations page as the official + opens it; a save reloads the list.
  private func edit(_ automation: Automation?) {
    guard let hostId, let session = model.session(for: hostId) else { return }
    let editor = AutomationEditorViewController(session: session, automation: automation) { [weak self] in self?.load() }
    navigationController?.pushViewController(editor, animated: true)
  }

  private func load() {
    guard let hostId, let session = model.session(for: hostId) else { return }
    loadedFor = hostId
    Task {
      automations = (try? await session.api.automations()) ?? []
      table.refreshControl?.endRefreshing()
      table.reloadData()
      empty.isHidden = !automations.isEmpty
    }
  }
}

extension AutomationsViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { automations.count }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    automations.isEmpty ? nil : String(localized: "home.automationsTab.scheduled", defaultValue: "Scheduled")
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let automation = automations[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "automation", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = automation.name
    content.textProperties.font = .systemFont(ofSize: 16)
    content.secondaryText =
      !automation.enabled
      ? String(localized: "home.automationsTab.paused", defaultValue: "Paused")
      : automation.lastRunAt.flatMap { RelativeTime.short($0) }.map {
        String(format: String(localized: "home.automationsTab.lastRun", defaultValue: "Last: %1$@"), $0)
      }
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.font = .systemFont(ofSize: 14)
    cell.contentConfiguration = content
    cell.backgroundColor = Palette.bgPanel
    let toggle = UISwitch()
    toggle.isOn = automation.enabled
    toggle.addAction(
      UIAction { [weak self] _ in
        guard let self, let hostId = self.hostId, let session = self.model.session(for: hostId) else { return }
        Task {
          do {
            try await session.api.setAutomation(automation, enabled: toggle.isOn)
            self.load()
          } catch {
            toggle.setOn(!toggle.isOn, animated: true)
          }
        }
      }, for: .valueChanged)
    cell.accessoryView = toggle
    return cell
  }
}

extension AutomationsViewController: HostScoped {
  func show(hostId: PairedHost.ID) {
    self.hostId = hostId
    loadedFor = nil
    setNeedsUpdateProperties()
  }
}

extension AutomationsViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    edit(automations[indexPath.row])
  }
}
