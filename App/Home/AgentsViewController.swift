import OrcaCore
import UIKit

/// The Agents tab groups related panes before placing them in Needs you, Working or Done.
final class AgentsViewController: UIViewController {
  struct Row: Hashable {
    let scope: String
    let worktreeId: String
    let paneKey: String
  }

  private struct Entry {
    let agent: Worktree.Agent
    let worktree: Worktree
    let session: HostSession
    let depth: Int

    var title: String { agent.listTitle.flatMap { $0.isEmpty ? nil : $0 } ?? agent.title }
    var state: String { agent.listState ?? agent.mainState ?? agent.state }
    var section: Section { Section.of(state) }
    var stamp: Double { agent.listSortAt ?? agent.updatedAt ?? 0 }
  }

  enum Section: Int, CaseIterable {
    case needsYou, working, done

    var title: String {
      switch self {
      case .needsYou: String(localized: "agents.sections.needsYou", defaultValue: "Needs you")
      case .working: String(localized: "agents.sections.working", defaultValue: "Working")
      case .done: String(localized: "agents.sections.done", defaultValue: "Done")
      }
    }

    static func of(_ state: String) -> Section {
      switch state {
      case "permission", "waiting", "blocked", "failed": .needsYou
      case "working", "monitoring": .working
      default: .done
      }
    }
  }

  private let model = AppModel.shared
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout())
  private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
  private let empty = TextLabel(
    String(localized: "agents.list.emptyTitle", defaultValue: "No agents running"), size: 15,
    color: Palette.textSecondary, alignment: .center)
  private let search = UISearchController(searchResultsController: nil)
  private var query = ""
  /// Rebuilt with each snapshot, so cells read the agent they were given.
  private var entries: [Row: Entry] = [:]
  var onNeedsYouChange: ((Int) -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = HomeTab.agents.title
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .inline
    search.searchBar.placeholder = String(localized: "agents.search.placeholder", defaultValue: "Search agents")
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    navigationItem.searchController = search
    navigationItem.preferredSearchBarPlacement = .integratedButton
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: Lucide.slidersHorizontal.image(size: 20, strokeWidth: 2), menu: optionsMenu())

    collection.backgroundColor = Palette.bgBase
    collection.delegate = self
    view.addSubview(collection)
    collection.pin(to: view)
    view.addSubview(empty)
    NSLayoutConstraint.activate([
      empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    configureDataSource()
  }

  override func updateProperties() {
    super.updateProperties()
    var grouped: [Section: [(rows: [Row], stamp: Double)]] = [:]
    entries = [:]
    var needsYou = 0
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    for session in model.workspaceSessions {
      var panes: [Worktree.Agent] = []
      var worktreesByPane: [String: Worktree] = [:]
      for worktree in session.worktrees where !worktree.isArchived {
        for agent in worktree.agents where agent.listed != false && worktreesByPane[agent.paneKey] == nil {
          panes.append(agent)
          worktreesByPane[agent.paneKey] = worktree
        }
      }
      func visibleRows(_ branch: AgentBranch<Worktree.Agent>, depth: Int) -> [(Row, Entry)] {
        let agent = branch.entry
        guard let worktree = worktreesByPane[agent.paneKey] else { return [] }
        let entry = Entry(agent: agent, worktree: worktree, session: session, depth: depth)
        let children = branch.children.flatMap { visibleRows($0, depth: depth + 1) }
        let text = [entry.title, agent.lastAssistantMessage ?? "", worktree.title, session.name].joined(separator: " ")
        guard query.isEmpty || text.localizedStandardContains(query) || !children.isEmpty else { return [] }
        return [(Row(scope: session.cacheNamespace, worktreeId: worktree.id, paneKey: agent.paneKey), entry)] + children
      }
      for branch in Worktree.Agent.lineage(panes, forAgentsTab: true) {
        let family = visibleRows(branch, depth: 0)
        guard let section = family.map({ $0.1.section }).min(by: { $0.rawValue < $1.rawValue }) else { continue }
        for (row, entry) in family {
          entries[row] = entry
          if entry.section == .needsYou { needsYou += 1 }
        }
        // Keep the family together even if the worker needs attention after its coordinator finishes.
        let stamp = family.lazy.map(\.1).filter { $0.section == section }.map(\.stamp).max() ?? 0
        grouped[section, default: []].append((family.map(\.0), stamp))
      }
    }
    var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
    for section in Section.allCases {
      guard let rows = grouped[section], !rows.isEmpty else { continue }
      snapshot.appendSections([section])
      snapshot.appendItems(rows.sorted { $0.stamp > $1.stamp }.flatMap(\.rows), toSection: section)
    }
    snapshot.reconfigureItems(snapshot.itemIdentifiers)
    dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    empty.isHidden = !snapshot.itemIdentifiers.isEmpty
    onNeedsYouChange?(needsYou)
  }

  private func layout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { _, environment in
      var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
      list.backgroundColor = Palette.bgBase
      list.headerMode = .supplementary
      list.separatorConfiguration.color = Palette.borderSubtle
      let section = NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
      section.contentInsets.leading = Spacing.lg
      section.contentInsets.trailing = Spacing.lg
      return section
    }
  }

  private func configureDataSource() {
    let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
      guard let self, let entry = self.entries[row] else { return }
      cell.contentConfiguration = AgentCardConfiguration(
        agent: entry.agent, title: entry.title, state: entry.state, stamp: entry.stamp,
        workspace: entry.worktree.title, depth: entry.depth, hostLabel: entry.session.remoteServer?.label)
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgPanel
      cell.backgroundConfiguration = background
    }
    let header = UICollectionView.SupplementaryRegistration<HomeSectionHeader>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] header, _, indexPath in
      guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
      let count = self.dataSource.snapshot().itemIdentifiers(inSection: section).count { self.entries[$0]?.section == section }
      header.label.runs = [(section.title, Palette.textPrimary), ("  \(count)", Palette.textMuted)]
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { collection, indexPath, row in
      collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
    }
    dataSource.supplementaryViewProvider = { collection, _, indexPath in
      collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
    }
  }

  private func optionsMenu() -> UIMenu {
    UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self else { return completion([]) }
        let unread = self.agentKeys { worktree, _ in worktree.unread }
        let finished = self.agentKeys { _, agent in Section.of(agent.listState ?? agent.mainState ?? agent.state) == .done }
        let markRead = UIAction(
          title: String(localized: "agents.options.markAllRead", defaultValue: "Mark all read"),
          image: Lucide.checkCheck.image(size: 18), attributes: unread.isEmpty ? .disabled : []
        ) { _ in
          Task { for (session, keys) in unread { try? await session.api.setAgentsRead(keys, read: true); await session.refresh() } }
        }
        let clear = UIAction(
          title: String(localized: "agents.options.clearFinished", defaultValue: "Clear finished"),
          image: Lucide.trash2.image(size: 18), attributes: finished.isEmpty ? [.disabled, .destructive] : .destructive
        ) { _ in
          Task { for (session, keys) in finished { try? await session.api.clearAgents(keys); await session.refresh() } }
        }
        completion([markRead, clear])
      }
    ])
  }

  /// Pane keys grouped by the connection that owns them.
  private func agentKeys(_ passes: (Worktree, Worktree.Agent) -> Bool) -> [(HostSession, [String])] {
    model.workspaceSessions.compactMap { session in
      guard session.connectionState == .connected else { return nil }
      let keys = session.worktrees.filter { !$0.isArchived }.flatMap { worktree in
        worktree.agents.filter { $0.listed != false && passes(worktree, $0) }.map(\.paneKey)
      }
      return keys.isEmpty ? nil : (session, keys)
    }
  }
}

extension AgentsViewController: UICollectionViewDelegate, UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text ?? ""
    setNeedsUpdateProperties()
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    Haptics.select()
    collectionView.deselectItem(at: indexPath, animated: true)
    guard let row = dataSource.itemIdentifier(for: indexPath), let entry = entries[row] else { return }
    let controller = SessionViewController(
      session: entry.session, worktreeId: row.worktreeId, sessionId: entry.agent.workspaceSessionId, paneKey: row.paneKey)
    navigationController?.pushViewController(controller, animated: true)
  }
}

/// An agent card (agents/MobileAgentListRows.tsx): dot, title and time; the latest words; mark and workspace.
struct AgentCardConfiguration: UIContentConfiguration {
  let agent: Worktree.Agent
  let title: String
  let state: String
  let stamp: Double
  let workspace: String
  let depth: Int
  var hostLabel: String? = nil

  func makeContentView() -> UIView & UIContentView { AgentCardView(configuration: self) }
  func updated(for state: UIConfigurationState) -> AgentCardConfiguration { self }
}

private final class AgentCardView: UIView, UIContentView {
  private let dot = AgentStatusDot()
  private let branch = LucideView(.cornerDownRight, size: 12, strokeWidth: 2, color: Palette.textMuted)
  // agents/MobileAgentListRows.tsx: title 15/20, time 12, preview 14/19, place 12 under a 13 pt mark.
  private let title = TextLabel(size: 15, lineHeight: 20)
  private let time = TextLabel(size: 12, color: Palette.textMuted, tabular: true)
  private let detail = TextLabel(size: 14, color: Palette.textSecondary, lineHeight: 19, lines: 2)
  private let mark = FilledIconView(size: 13)
  private let workspace = TextLabel(size: 12, color: Palette.textMuted)
  private lazy var dotInset = dot.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 6)
  private lazy var titleInset = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 24)

  var configuration: UIContentConfiguration { didSet { apply() } }

  init(configuration: AgentCardConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    let footer = UIStackView(arrangedSubviews: [mark, workspace])
    footer.axis = .horizontal
    footer.spacing = 6
    footer.alignment = .center
    footer.translatesAutoresizingMaskIntoConstraints = false
    for view in [branch, dot, title, time, detail, footer] as [UIView] { addSubview(view) }
    time.setContentCompressionResistancePriority(.required, for: .horizontal)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      branch.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -4),
      branch.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
      dotInset,
      dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      titleInset,
      title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      time.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: Spacing.sm),
      time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      time.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
      footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
      footer.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3),
      footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let configuration = configuration as? AgentCardConfiguration else { return }
    let agent = configuration.agent
    dot.set(status: configuration.state)
    let indent = CGFloat(min(configuration.depth, 3)) * 16
    dotInset.constant = Spacing.lg + 6 + indent
    titleInset.constant = Spacing.lg + 24 + indent
    branch.isHidden = configuration.depth == 0
    title.text = configuration.title
    time.text = RelativeTime.short(configuration.stamp)
    detail.text = agent.lastAssistantMessage.map(MarkdownPreview.plain)
    detail.isHidden = (agent.lastAssistantMessage ?? "").isEmpty
    mark.icon = AgentMark.icon(for: agent.agentType)
    mark.isHidden = mark.icon == nil
    let worker = configuration.depth > 0 || agent.listParentPaneKey != nil
    workspace.text = [worker ? WorkspaceAgentRole.worker.title : nil, configuration.workspace, configuration.hostLabel]
      .compactMap { $0 }.joined(separator: " · ")
    isAccessibilityElement = true
    accessibilityLabel = [configuration.title, detail.text, workspace.text].compactMap { $0 }.joined(separator: ", ")
  }
}
