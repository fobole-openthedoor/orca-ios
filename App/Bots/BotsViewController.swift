import OrcaCore
import UIKit

struct BotKey: Hashable {
  let hostId: UUID
  let botId: String
}

/// Every bot on every paired desktop, newest activity first, with the desktop it runs on.
@MainActor
enum BotDirectory {
  static func all(_ model: AppModel) -> [(key: BotKey, bot: Bot, session: HostSession)] {
    var rows: [(BotKey, Bot, HostSession, Double)] = []
    for host in model.hosts {
      guard let session = model.session(for: host.id) else { continue }
      for bot in session.bots.bots {
        let updated = session.worktree(id: bot.homeWorktreeId)?.agents.compactMap(\.updatedAt).max() ?? bot.createdAt ?? 0
        rows.append((BotKey(hostId: host.id, botId: bot.id), bot, session, updated))
      }
    }
    return rows.sorted { $0.3 > $1.3 }.map { ($0.0, $0.1, $0.2) }
  }

  static func open(_ bot: Bot, in session: HostSession, from navigation: UINavigationController?) {
    navigation?.pushViewController(SessionViewController(session: session, worktreeId: bot.homeWorktreeId), animated: true)
  }
}

/// The Bots tab (home/tabs/MobileHomeBotsTab.tsx).
final class BotsViewController: UIViewController, UICollectionViewDelegate {
  private let model = AppModel.shared
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
  private var dataSource: UICollectionViewDiffableDataSource<Int, BotKey>!
  private var rows: [BotKey: (Bot, HostSession)] = [:]
  private let empty = TextLabel(
    String(localized: "bots.list.noBotsYet", defaultValue: "No bots yet"), size: 15, color: Palette.textSecondary)

  /// New bot on the one desktop there is; with several, a menu asks which runs it.
  private func newBot() {
    let sessions = model.orderedHosts.compactMap { model.session(for: $0.id) }.filter {
      $0.connectionState == .connected
    }
    guard let first = sessions.first else { return }
    func present(_ session: HostSession) {
      self.present(
        NewBotViewController.sheet(session: session) { [weak self] bot in
          BotDirectory.open(bot, in: session, from: self?.navigationController)
        }, animated: true)
    }
    guard sessions.count > 1 else { return present(first) }
    let sheet = UIAlertController(
      title: String(localized: "bots.new.runsOn", defaultValue: "Runs on"), message: nil, preferredStyle: .actionSheet)
    for session in sessions {
      sheet.addAction(UIAlertAction(title: session.name, style: .default) { _ in present(session) })
    }
    sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceItem = navigationItem.rightBarButtonItem
    self.present(sheet, animated: true)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = HomeTab.bots.title
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .always
    let add = UIBarButtonItem(
      image: Lucide.plus.image(size: 20, strokeWidth: 2),
      primaryAction: UIAction { [weak self] _ in self?.newBot() })
    add.accessibilityLabel = String(localized: "bots.new.title", defaultValue: "New bot")
    navigationItem.rightBarButtonItem = add
    collection.backgroundColor = Palette.bgBase
    collection.delegate = self
    view.addSubview(collection)
    collection.pin(to: view)
    view.addSubview(empty)
    NSLayoutConstraint.activate([
      empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
      empty.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
    ])
    let cell = UICollectionView.CellRegistration<UICollectionViewListCell, BotKey> { [weak self] cell, _, key in
      guard let self, let (bot, session) = self.rows[key] else { return }
      cell.contentConfiguration = BotRowConfiguration.make(bot: bot, session: session, showHost: true)
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = Palette.bgBase
      cell.backgroundConfiguration = background
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { collection, indexPath, key in
      collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: key)
    }
  }

  override func updateProperties() {
    super.updateProperties()
    let all = BotDirectory.all(model)
    rows = Dictionary(uniqueKeysWithValues: all.map { ($0.key, ($0.bot, $0.session)) })
    var snapshot = NSDiffableDataSourceSnapshot<Int, BotKey>()
    snapshot.appendSections([0])
    snapshot.appendItems(all.map(\.key))
    snapshot.reconfigureItems(all.map(\.key))
    dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    empty.isHidden = !all.isEmpty
  }

  private static func layout() -> UICollectionViewLayout {
    var list = UICollectionLayoutListConfiguration(appearance: .plain)
    list.showsSeparators = false
    list.backgroundColor = Palette.bgBase
    return UICollectionViewCompositionalLayout.list(using: list)
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: true)
    guard let key = dataSource.itemIdentifier(for: indexPath), let (bot, session) = rows[key] else { return }
    BotDirectory.open(bot, in: session, from: navigationController)
  }
}
