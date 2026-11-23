import OrcaCore
import UIKit

enum HomeTab: String, CaseIterable {
  case feed, bots, agents, usage, automations

  var title: String {
    switch self {
    case .feed: String(localized: "home.tabs.feed", defaultValue: "Feed")
    case .bots: String(localized: "home.tabs.bots", defaultValue: "Bots")
    case .agents: String(localized: "home.tabs.agents", defaultValue: "Agents")
    case .usage: String(localized: "home.tabs.usage", defaultValue: "Usage")
    case .automations: String(localized: "home.tabs.automations", defaultValue: "Automations")
    }
  }

  static let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: UIFont.systemFont(ofSize: 22, weight: .bold), .kern: -0.4, .foregroundColor: Palette.textPrimary,
  ]

  /// Settings › Orca iOS can hide a tab the person doesn't use; Feed, the way in to everything, always stays.
  var canHide: Bool { self != .feed }

  static let hiddenChanged = Notification.Name("orca.tabs.hiddenChanged")

  static var hidden: Set<HomeTab> {
    get { Set((UserDefaults.standard.stringArray(forKey: "orca.tabs.hidden") ?? []).compactMap(HomeTab.init).filter(\.canHide)) }
    set {
      UserDefaults.standard.set(newValue.filter(\.canHide).map(\.rawValue), forKey: "orca.tabs.hidden")
      NotificationCenter.default.post(name: hiddenChanged, object: nil)
    }
  }

  /// The official app's glyph for each tab (home/tabs/MobileHomeTabBar.tsx).
  var icon: Lucide {
    switch self {
    case .feed: .layoutList
    case .bots: .bot
    case .agents: .squareTerminal
    case .usage: .gauge
    case .automations: .calendarClock
    }
  }
}

/// Home (home/MobileHomeScreen.tsx) on the system tab bar: five tabs, each with its own navigation stack,
/// loaded on first visit. Agents and Bots carry needs-you badges.
final class HomeTabController: UITabBarController {
  private var tabsByID: [HomeTab: UITab] = [:]
  /// Every tab, hidden or not; the bar shows the ones Settings leaves on.
  private var allTabs: [UITab] = []

  init() {
    super.init(nibName: nil, bundle: nil)
    allTabs = HomeTab.allCases.map { homeTab in
      let tab = UITab(
        title: homeTab.title, image: homeTab.icon.image(size: 24, strokeWidth: 2), identifier: homeTab.rawValue
      ) { [weak self] _ in
        let navigation = UINavigationController(rootViewController: self?.root(for: homeTab) ?? UIViewController())
        navigation.navigationBar.prefersLargeTitles = true
        // A tab's title shares the row with its buttons (home/tabs/MobileHomeTabHeader.tsx): 22 pt bold, -0.4 pt
        // tracking, never iOS's 34 pt large title.
        navigation.navigationBar.largeTitleTextAttributes = HomeTab.titleAttributes
        return navigation
      }
      tabsByID[homeTab] = tab
      return tab
    }
    applyHidden()
    NotificationCenter.default.addObserver(forName: HomeTab.hiddenChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyHidden() }
    }
    tabBarMinimizeBehavior = .onScrollDown
    // The official bar marks the selected tab in the primary text colour, not the accent.
    tabBar.tintColor = Palette.textPrimary
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Hides the tabs Settings hides; one on screen as it goes hands over to Feed first.
  private func applyHidden() {
    let hidden = HomeTab.hidden
    if let selected = selectedTab, let current = HomeTab(rawValue: selected.identifier), hidden.contains(current) {
      selectedTab = tabsByID[.feed]
    }
    let shown = allTabs.filter { HomeTab(rawValue: $0.identifier).map { !hidden.contains($0) } ?? true }
    if shown.map(\.identifier) != tabs.map(\.identifier) { setTabs(shown, animated: view.window != nil) }
  }

  /// Switches to a tab, back at its root, and lets it show one desktop. A hidden tab's page opens over the
  /// tab on screen instead.
  func open(_ homeTab: HomeTab, hostId: PairedHost.ID? = nil) {
    if HomeTab.hidden.contains(homeTab) {
      let page = root(for: homeTab)
      if let hostId, let scoped = page as? HostScoped { scoped.show(hostId: hostId) }
      (selectedTab?.viewController as? UINavigationController)?.pushViewController(page, animated: true)
      return
    }
    guard let tab = tabsByID[homeTab] else { return }
    selectedTab = tab
    let navigation = tab.viewController as? UINavigationController
    navigation?.popToRootViewController(animated: false)
    if let hostId, let root = navigation?.viewControllers.first as? HostScoped { root.show(hostId: hostId) }
  }

  func setBadge(_ count: Int, on homeTab: HomeTab) {
    tabsByID[homeTab]?.badgeValue = count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
  }

  private func root(for tab: HomeTab) -> UIViewController {
    switch tab {
    case .feed: return FeedViewController()
    case .bots: return BotsViewController()
    case .usage: return UsageViewController()
    case .automations: return AutomationsViewController()
    case .agents:
      let agents = AgentsViewController()
      agents.onNeedsYouChange = { [weak self] count in self?.setBadge(count, on: .agents) }
      return agents
    default: return PlaceholderTabViewController(tab: tab)
    }
  }
}

final class PlaceholderTabViewController: UIViewController {
  private let homeTab: HomeTab

  init(tab: HomeTab) {
    homeTab = tab
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = homeTab.title
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .inline
  }
}

/// A tab that shows one desktop at a time and can be pointed at another.
@MainActor
protocol HostScoped: AnyObject {
  func show(hostId: PairedHost.ID)
}
