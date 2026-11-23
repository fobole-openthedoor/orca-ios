import OrcaCore
import UIKit

/// Feed (home/tabs/MobileHomeFeedTab.tsx): the Desktops group with Pair desktop, and Tasks.
/// The pairing guide replaces the list until a desktop is paired.
final class FeedViewController: UIViewController {
  private enum Section: Hashable { case bots, desktops, tasks }
  private enum Item: Hashable {
    case bot(BotKey)
    case host(PairedHost.ID)
    case pair
    case tasks
  }

  private let model = AppModel.shared
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
  private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
  private let empty = HomeEmptyStateView()
  private var botRows: [BotKey: (Bot, HostSession)] = [:]

  override func viewDidLoad() {
    super.viewDidLoad()
    title = HomeTab.feed.title
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .always
    let settings = UIBarButtonItem(
      image: Lucide.settings.image(size: 22, strokeWidth: 2),
      primaryAction: UIAction { [weak self] _ in
        self?.navigationController?.pushViewController(SettingsViewController(), animated: true)
      })
    settings.accessibilityLabel = String(localized: "common.settings", defaultValue: "Settings")
    navigationItem.rightBarButtonItem = settings

    collection.backgroundColor = Palette.bgBase
    collection.delegate = self
    view.addSubview(collection)
    collection.pin(to: view)
    view.addSubview(empty)
    empty.pin(to: view)
    empty.onPairDesktop = { [weak self] in self?.pairDesktop() }
    configureDataSource()
  }

  // UIKit tracks the @Observable reads made here and calls it again when they change.
  override func updateProperties() {
    super.updateProperties()
    let hosts = model.orderedHosts
    empty.isHidden = !model.loaded || !hosts.isEmpty
    collection.isHidden = hosts.isEmpty
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    let bots = BotDirectory.all(model)
    botRows = Dictionary(uniqueKeysWithValues: bots.map { ($0.key, ($0.bot, $0.session)) })
    if !bots.isEmpty {
      snapshot.appendSections([.bots])
      snapshot.appendItems(bots.map { .bot($0.key) }, toSection: .bots)
    }
    snapshot.appendSections([.desktops, .tasks])
    snapshot.appendItems(hosts.map { .host($0.id) } + [.pair], toSection: .desktops)
    snapshot.appendItems([.tasks], toSection: .tasks)
    for host in hosts {
      // Read what each row shows, so a change to any of it reconfigures that row.
      if let session = model.session(for: host.id) {
        _ = (session.connectionState, session.status, session.worktrees, session.isLoading)
      }
    }
    snapshot.reconfigureItems(hosts.map { .host($0.id) } + bots.map { .bot($0.key) } + [.tasks])
    dataSource.apply(snapshot, animatingDifferences: view.window != nil)
  }

  private static func layout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { index, environment in
      var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
      list.backgroundColor = Palette.bgBase
      list.headerMode = .supplementary
      list.separatorConfiguration.color = Palette.borderSubtle
      // Separators start where a tile row's text does (home-list-styles tileSeparator).
      list.itemSeparatorHandler = { _, configuration in
        var configuration = configuration
        configuration.color = Palette.borderSubtle
        configuration.bottomSeparatorInsets.leading = Spacing.lg + 30 + 11
        return configuration
      }
      let section = NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
      section.contentInsets.leading = Spacing.lg
      section.contentInsets.trailing = Spacing.lg
      return section
    }
  }

  private func configureDataSource() {
    let hostCell = UICollectionView.CellRegistration<UICollectionViewListCell, PairedHost.ID> { [weak self] cell, _, id in
      guard let self, let host = self.model.hosts.first(where: { $0.id == id }) else { return }
      cell.contentConfiguration = TileRowConfiguration.host(host, session: self.model.session(for: id))
      cell.accessories = [.disclosureIndicator(options: .init(tintColor: Palette.textMuted))]
      cell.backgroundConfiguration = Self.rowBackground()
    }
    let pairCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
      var content = UIListContentConfiguration.cell()
      content.text = String(localized: "home.desktops.pairDesktop", defaultValue: "Pair a desktop")
      content.textProperties.color = Palette.accentBlue
      content.textProperties.font = .systemFont(ofSize: 16)
      content.image = Lucide.plus.image(size: 18, strokeWidth: 2)
      content.imageProperties.tintColor = Palette.accentBlue
      content.imageToTextPadding = 10
      cell.contentConfiguration = content
      cell.backgroundConfiguration = Self.rowBackground()
    }
    let tasksCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
      let connected = self?.model.sessions.values.contains { $0.connectionState == .connected } ?? false
      cell.contentConfiguration = TileRowConfiguration(
        icon: .listTodo, title: String(localized: "home.sections.tasks", defaultValue: "Tasks"),
        subtitle: [
          (String(localized: "home.sections.tasksSubtitle", defaultValue: "Browse your issues and reviews"), Palette.textSecondary)
        ], dot: nil, enabled: connected)
      cell.accessories = [.disclosureIndicator(options: .init(tintColor: Palette.textMuted))]
      cell.backgroundConfiguration = Self.rowBackground()
      cell.isUserInteractionEnabled = connected
    }
    let header = UICollectionView.SupplementaryRegistration<HomeSectionHeader>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] header, _, indexPath in
      guard let self else { return }
      switch self.dataSource.sectionIdentifier(for: indexPath.section) {
      case .bots:
        header.label.runs = [
          (String(localized: "bots.section.title", defaultValue: "Bots"), Palette.textPrimary),
          ("  \(self.botRows.count)", Palette.textMuted),
        ]
        header.isHidden = false
      case .desktops:
        header.label.text = String(localized: "home.listHeader.desktopsHeading", defaultValue: "Desktops")
        header.isHidden = false
      default:
        header.label.text = nil
        header.isHidden = true
      }
    }
    let botCell = UICollectionView.CellRegistration<UICollectionViewListCell, BotKey> { [weak self] cell, _, key in
      guard let self, let (bot, session) = self.botRows[key] else { return }
      cell.contentConfiguration = BotRowConfiguration.make(bot: bot, session: session, showHost: true)
      cell.backgroundConfiguration = Self.rowBackground()
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { collection, indexPath, item in
      switch item {
      case .bot(let key): collection.dequeueConfiguredReusableCell(using: botCell, for: indexPath, item: key)
      case .host(let id): collection.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: id)
      case .pair: collection.dequeueConfiguredReusableCell(using: pairCell, for: indexPath, item: item)
      case .tasks: collection.dequeueConfiguredReusableCell(using: tasksCell, for: indexPath, item: item)
      }
    }
    dataSource.supplementaryViewProvider = { collection, kind, indexPath in
      collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
    }
  }

  private static func rowBackground() -> UIBackgroundConfiguration {
    var background = UIBackgroundConfiguration.listCell()
    background.backgroundColor = Palette.bgPanel
    background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in Palette.bgPanel }
    return background
  }

  private func pairDesktop() {
    let pairing = PairingViewController()
    present(UINavigationController(rootViewController: pairing), animated: true)
  }

  private func openHost(_ id: PairedHost.ID) {
    guard let session = model.session(for: id) else { return }
    navigationController?.pushViewController(HostViewController(session: session), animated: true)
  }
}

extension FeedViewController: UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    Haptics.select()
    collectionView.deselectItem(at: indexPath, animated: true)
    switch dataSource.itemIdentifier(for: indexPath) {
    case .bot(let key):
      if let (bot, session) = botRows[key] { BotDirectory.open(bot, in: session, from: navigationController) }
    case .host(let id): openHost(id)
    case .pair: pairDesktop()
    case .tasks:
      let tasks = TasksViewController(session: nil)
      tasks.onOpenWorkspace = { [weak self] session, worktreeId in
        self?.navigationController?.pushViewController(SessionViewController(session: session, worktreeId: worktreeId), animated: true)
      }
      navigationController?.pushViewController(tasks, animated: true)
    case .none: break
    }
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first, case .host(let id) = dataSource.itemIdentifier(for: indexPath),
      let host = model.hosts.first(where: { $0.id == id })
    else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      let reconnect = UIAction(
        title: String(localized: "hostScreen.hostListActionSheetActions.reconnect", defaultValue: "Reconnect"),
        image: UIImage(systemName: "arrow.clockwise")
      ) { _ in self?.model.session(for: id)?.nudge() }
      let remove = UIAction(
        title: String(localized: "common.remove", defaultValue: "Remove"),
        image: UIImage(systemName: "trash"), attributes: .destructive
      ) { _ in self?.confirmRemove(host) }
      return UIMenu(children: [reconnect, remove])
    }
  }

  private func confirmRemove(_ host: PairedHost) {
    let name = model.session(for: host.id)?.name ?? host.name
    let alert = UIAlertController(
      title: String(
        format: String(localized: "home.screen.removeHostMessage", defaultValue: "Remove \"%1$@\"? You can re-pair later."),
        name),
      message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "common.remove", defaultValue: "Remove"), style: .destructive) {
        [weak self] _ in
        Task { try? await self?.model.remove(host.id) }
      })
    present(alert, animated: true)
  }
}

/// A Home list row with a 30 pt tile in the status column (home/home-list-styles.ts): desktops, with the
/// connection dot on the tile's corner (home/MobileHomeDesktopRow.tsx), and Tasks.
struct TileRowConfiguration: UIContentConfiguration {
  var icon: Lucide
  var title: String
  var subtitle: [(String, UIColor)]
  var dot: UIColor?
  var needsYou = 0
  var enabled = true

  func makeContentView() -> UIView & UIContentView { TileRowView(configuration: self) }
  func updated(for state: UIConfigurationState) -> TileRowConfiguration { self }
}

extension TileRowConfiguration {
  @MainActor static func host(_ host: PairedHost, session: HostSession?) -> TileRowConfiguration {
    let status = HostConnectionPresentation(session?.connectionState ?? .disconnected)
    let summary = session.flatMap { status.connected ? HostWorktreeSummary.text(for: $0) : nil }
    var subtitle: [(String, UIColor)] = [(summary ?? status.label, status.connected ? Palette.textSecondary : status.labelColor)]
    if let machine = session?.status?.machineLine { subtitle.append((" · \(machine)", Palette.textSecondary)) }
    let icon: Lucide =
      switch session?.status?.hostKind {
      case "laptop": .laptop
      case "server": .server
      default: .monitor
      }
    return TileRowConfiguration(
      icon: icon, title: session?.name ?? host.name, subtitle: subtitle, dot: status.dot,
      needsYou: session.map { status.connected ? HostWorktreeSummary.needsYou(in: $0) : 0 } ?? 0)
  }
}

private final class TileRowView: UIView, UIContentView {
  private static let leading: CGFloat = Spacing.lg
  private let tile = UIView()
  private let glyph = LucideView(.monitor, size: 17, strokeWidth: 1.8)
  private let dot = UIView()
  private let titleLabel = TextLabel(size: 16, lineHeight: 20)
  private let subtitleLabel = TextLabel(size: 14, color: Palette.textSecondary, lineHeight: 18)
  private let countPill = UIView()
  private let countLabel = TextLabel(size: 12, weight: .bold, color: .black, alignment: .center, tabular: true)

  var configuration: UIContentConfiguration {
    didSet { apply() }
  }

  init(configuration: TileRowConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    tile.translatesAutoresizingMaskIntoConstraints = false
    tile.backgroundColor = Palette.bgRaised
    tile.layer.cornerRadius = Radius.tile
    dot.translatesAutoresizingMaskIntoConstraints = false
    // A 10 pt dot ringed 2 pt in the group's colour, hanging 3 pt off the tile's corner.
    dot.layer.cornerRadius = 7
    dot.layer.borderWidth = 2
    countPill.translatesAutoresizingMaskIntoConstraints = false
    countPill.backgroundColor = Palette.statusAmber
    countPill.layer.cornerRadius = 10
    countPill.addSubview(countLabel)
    for view in [tile, titleLabel, subtitleLabel, countPill] as [UIView] { addSubview(view) }
    tile.addSubview(glyph)
    tile.addSubview(dot)
    NSLayoutConstraint.activate([
      tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading),
      tile.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      tile.widthAnchor.constraint(equalToConstant: 30),
      tile.heightAnchor.constraint(equalToConstant: 30),
      glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 14),
      dot.heightAnchor.constraint(equalToConstant: 14),
      dot.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 5),
      dot.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: 5),
      titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 11),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countPill.leadingAnchor, constant: -10),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
      subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countPill.leadingAnchor, constant: -10),
      subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
      countPill.trailingAnchor.constraint(equalTo: trailingAnchor),
      countPill.centerYAnchor.constraint(equalTo: centerYAnchor),
      countPill.heightAnchor.constraint(equalToConstant: 20),
      countPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
      countLabel.leadingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: 6),
      countLabel.trailingAnchor.constraint(equalTo: countPill.trailingAnchor, constant: -6),
      countLabel.centerYAnchor.constraint(equalTo: countPill.centerYAnchor),
    ])
    apply()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func apply() {
    guard let configuration = configuration as? TileRowConfiguration else { return }
    glyph.icon = configuration.icon
    titleLabel.text = configuration.title
    subtitleLabel.runs = configuration.subtitle
    dot.isHidden = configuration.dot == nil
    dot.backgroundColor = configuration.dot
    dot.layer.borderColor = Palette.bgPanel.resolvedColor(with: traitCollection).cgColor
    countPill.isHidden = configuration.needsYou == 0
    countLabel.text = "\(configuration.needsYou)"
    alpha = configuration.enabled ? 1 : 0.45
    isAccessibilityElement = true
    accessibilityLabel = ([configuration.title] + configuration.subtitle.map(\.0)).joined(separator: ", ")
  }
}

/// A Home section heading (home/MobileHomeSectionHeading.tsx): 15 pt semibold, 4 pt in from the group.
final class HomeSectionHeader: UICollectionReusableView {
  let label = TextLabel(size: 15, weight: .semibold)

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xs),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.xs),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
    ])
    label.accessibilityTraits = .header
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
