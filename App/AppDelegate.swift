import TipKit
import OrcaCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ScrollEdges.install()
    try? Tips.configure()
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    PushCenter.shared.didRegister(deviceToken: deviceToken)
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    // No push entitlement in this signature, or no network: the app still updates while it runs.
    NSLog("APNs registration failed: %@", error.localizedDescription)
    PushCenter.shared.didFailToRegister(error)
  }

  func application(
    _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = HomeTabController()
    window.backgroundColor = Palette.bgBase
    window.tintColor = Palette.accentBlue
    window.makeKeyAndVisible()
    self.window = window
    // First launch: who makes this app, notifications, and its license, before anything else.
    if !WelcomeViewController.seen {
      let welcome = WelcomeViewController()
      welcome.modalPresentationStyle = .fullScreen
      welcome.onFinish = { [weak welcome] in welcome?.dismiss(animated: true) }
      DispatchQueue.main.async { window.rootViewController?.present(welcome, animated: false) }
    }
    AppearanceViewController.Theme.apply()
    let urls = connectionOptions.urlContexts.map(\.url)
    NotificationCenter.default.addObserver(forName: .orcaOpenURL, object: nil, queue: .main) { [weak self] note in
      guard let url = note.object as? URL else { return }
      MainActor.assumeIsolated { self?.open(url) }
    }
    Task {
      await AppModel.shared.load()
      AgentActivityCenter.shared.start(model: AppModel.shared)
      AgentActivityCenter.shared.startSampleIfRequested()
      PushCenter.shared.start(model: AppModel.shared)
      for url in urls { open(url) }
    }
  }

  private var background: UIBackgroundTaskIdentifier = .invalid

  /// Keeps the connections a little after leaving, so Live Activities get the agent's next steps.
  func sceneDidEnterBackground(_ scene: UIScene) {
    background = UIApplication.shared.beginBackgroundTask(withName: "orca.liveActivities") { [weak self] in
      guard let self else { return }
      UIApplication.shared.endBackgroundTask(self.background)
      self.background = .invalid
    }
  }

  func sceneWillResignActive(_ scene: UIScene) {
    PiPCenter.shared.appWillResignActive()
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    PiPCenter.shared.appBecameActive()
    if background != .invalid {
      UIApplication.shared.endBackgroundTask(background)
      background = .invalid
    }
  }

  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    for context in contexts { open(context.url) }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    PiPCenter.shared.appBecameActive()
    AppModel.shared.nudgeAll()
  }

  /// orca://pair?code=… pairs straight away, as the official deep link does; orca://open?host=&worktree=
  /// (a tapped Live Activity) opens that workspace's session.
  private func open(_ url: URL) {
    if url.host == "open" {
      openWorkspace(url)
      return
    }
    guard let offer = PairingCode.parse(url.absoluteString), let root = window?.rootViewController else { return }
    let pairing = PairingViewController(offer: offer)
    let presenter = root.presentedViewController ?? root
    presenter.present(UINavigationController(rootViewController: pairing), animated: true)
  }

  private func openWorkspace(_ url: URL) {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let hostText = items.first(where: { $0.name == "host" })?.value, let hostId = UUID(uuidString: hostText),
      let worktreeId = items.first(where: { $0.name == "worktree" })?.value,
      let session = AppModel.shared.session(for: hostId),
      let tabs = window?.rootViewController as? HomeTabController
    else { return }
    tabs.presentedViewController?.dismiss(animated: false)
    tabs.selectedTab = tabs.tabs.first
    guard let navigation = tabs.selectedViewController as? UINavigationController else { return }
    navigation.popToRootViewController(animated: false)
    navigation.pushViewController(HostViewController(session: session), animated: false)
    navigation.pushViewController(SessionViewController(session: session, worktreeId: worktreeId), animated: true)
  }
}
