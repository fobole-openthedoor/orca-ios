import OrcaCore
import UIKit

/// The Agents tab (home/tabs/MobileHomeAgentsTab.tsx): every agent on every paired desktop, grouped
/// Needs you · Working · Done, newest first, each opening its workspace.
final class AgentsViewController: UIViewController {
  struct Row: Hashable {
    let hostId: UUID
    let worktreeId: String
    let paneKey: String
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
  private var entries: [Row: (Worktree.Agent, Worktree, HostSession)] = [:]
  var onNeedsYouChange: ((Int) -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = HomeTab.agents.title
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .always
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
    var grouped: [Section: [(Row, Double)]] = [:]
    entries = [:]
    var needsYou = 0
    for host in model.hosts {
      guard let session = model.session(for: host.id) else { continue }
      for worktree in session.worktrees where !worktree.isArchived {
        for agent in worktree.agents {
          let text = [agent.title, agent.lastAssistantMessage ?? "", worktree.displayName].joined(separator: " ").lowercased()
          if !query.isEmpty, !text.contains(query.lowercased()) { continue }
          let row = Row(hostId: host.id, worktreeId: worktree.id, paneKey: agent.paneKey)
          entries[row] = (agent, worktree, session)
          let section = Section.of(agent.state)
          if section == .needsYou { needsYou += 1 }
          grouped[section, default: []].append((row, agent.updatedAt ?? 0))
        }
      }
    }
    var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
    for section in Section.allCases {
      guard let rows = grouped[section], !rows.isEmpty else { continue }
      snapshot.appendSections([section])
      snapshot.appendItems(rows.sorted { $0.1 > $1.1 }.map(\.0), toSection: section)
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
      guard let self, let (agent, worktree, _) = self.entries[row] else { return }
      cell.contentConfiguration = AgentCardConfiguration(agent: agent, workspace: worktree.displayName)
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgPanel
      cell.backgroundConfiguration = background
    }
    let header = UICollectionView.SupplementaryRegistration<HomeSectionHeader>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] header, _, indexPath in
      guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
      let count = self.dataSource.snapshot().numberOfItems(inSection: section)
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
      UIAction(
        title: String(localized: "agents.options.markAllRead", defaultValue: "Mark all read"),
        image: Lucide.checkCheck.image(size: 18)) { _ in }
    ])
  }
}

extension AgentsViewController: UICollectionViewDelegate, UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text ?? ""
    setNeedsUpdateProperties()
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: true)
    guard let row = dataSource.itemIdentifier(for: indexPath), let (_, _, session) = entries[row] else { return }
    navigationController?.pushViewController(SessionViewController(session: session, worktreeId: row.worktreeId), animated: true)
  }
}

/// An agent card (agents/MobileAgentListRows.tsx): dot, title and time; the latest words; mark and workspace.
struct AgentCardConfiguration: UIContentConfiguration {
  let agent: Worktree.Agent
  let workspace: String

  func makeContentView() -> UIView & UIContentView { AgentCardView(configuration: self) }
  func updated(for state: UIConfigurationState) -> AgentCardConfiguration { self }
}

private final class AgentCardView: UIView, UIContentView {
  private let dot = AgentStatusDot()
  private let title = TextLabel(size: 16, lineHeight: 22)
  private let time = TextLabel(size: 14, color: Palette.textMuted, tabular: true)
  private let detail = TextLabel(size: 15, color: Palette.textSecondary, lineHeight: 20, lines: 2)
  private let mark = FilledIconView(size: 14)
  private let workspace = TextLabel(size: 14, color: Palette.textMuted)

  var configuration: UIContentConfiguration { didSet { apply() } }

  init(configuration: AgentCardConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    let footer = UIStackView(arrangedSubviews: [mark, workspace])
    footer.axis = .horizontal
    footer.spacing = 6
    footer.alignment = .center
    footer.translatesAutoresizingMaskIntoConstraints = false
    for view in [dot, title, time, detail, footer] as [UIView] { addSubview(view) }
    time.setContentCompressionResistancePriority(.required, for: .horizontal)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      dot.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 6),
      dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 24),
      title.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
      time.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: Spacing.sm),
      time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      time.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.lg),
      footer.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 4),
      footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
    ])
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let configuration = configuration as? AgentCardConfiguration else { return }
    let agent = configuration.agent
    dot.set(status: agent.state == "idle" ? "done" : agent.state)
    title.text = agent.title
    time.text = RelativeTime.short(agent.updatedAt)
    detail.text = agent.lastAssistantMessage?.replacingOccurrences(of: "\n", with: " ")
    detail.isHidden = (agent.lastAssistantMessage ?? "").isEmpty
    mark.icon = AgentMark.icon(for: agent.agentType)
    mark.isHidden = mark.icon == nil
    workspace.text = configuration.workspace
    isAccessibilityElement = true
    accessibilityLabel = [agent.title, detail.text, configuration.workspace].compactMap { $0 }.joined(separator: ", ")
  }
}
