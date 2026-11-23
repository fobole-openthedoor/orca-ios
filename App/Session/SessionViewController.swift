import OrcaCore
import UIKit

/// A workspace's session (session/MobileSessionRouteScreen.tsx): the system navigation bar with the branch
/// as subtitle, the official tab strip, and the active tab's content (a chat for agent sessions).
final class SessionViewController: UIViewController {
  private let session: HostSession
  private let worktreeId: String
  private let strip = SessionTabStrip()
  private let content = UIView()
  private var tabs = SessionTabs()
  private var tabsTask: Task<Void, Never>?
  private var shownTabId: String?
  private var chats: [String: ChatViewController] = [:]
  private var current: UIViewController?
  private var resolvingPath = false
  /// The host has answered with its tabs, so none means none rather than not yet.
  private var tabsLoaded = false

  /// The chat to bring to the front once the tabs arrive, as an item or a past session asked.
  private var focusSessionId: String?

  init(session: HostSession, worktreeId: String, sessionId: String? = nil) {
    self.session = session
    self.worktreeId = worktreeId
    focusSessionId = sessionId
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { tabsTask?.cancel() }

  private var selector: String { "id:\(worktreeId)" }

  /// The bot whose home this workspace is, if any.
  private var bot: Bot? { session.bots.bots.first { $0.homeWorktreeId == worktreeId } }
  private lazy var botTitle = BotTitleView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .never
    let more = UIBarButtonItem(image: Lucide.ellipsis.image(size: 20, strokeWidth: 2), menu: moreMenu())
    if bot != nil {
      // A bot's home: its items instead of source control, and its face beside its name.
      let items = UIBarButtonItem(
        image: Lucide.listChecks.image(size: 20, strokeWidth: 2), primaryAction: UIAction { [weak self] _ in self?.openItems() })
      items.accessibilityLabel = String(localized: "session.header.items", defaultValue: "Items")
      navigationItem.rightBarButtonItems = [more, items]
      navigationItem.titleView = botTitle
    } else {
      let branch = UIBarButtonItem(
        image: Lucide.gitBranch.image(size: 20, strokeWidth: 2), primaryAction: UIAction { [weak self] _ in self?.openSourceControl() })
      branch.accessibilityLabel = String(localized: "session.header.sourceControl", defaultValue: "Source control")
      navigationItem.rightBarButtonItems = [more, branch]
    }

    strip.onSelect = { [weak self] tab in
      guard let self else { return }
      self.show(tab)
      self.updateStrip()
      let api = self.session.api
      let selector = self.selector
      Task { await api.activateTab(tab.id, worktree: selector) }
    }
    strip.onClose = { [weak self] tab in
      guard let self else { return }
      let api = self.session.api
      let selector = self.selector
      self.run { try await api.closeTab(tab.id, worktree: selector) }
    }
    strip.newTabMenu = { [weak self] in self?.newTabMenu() ?? UIMenu() }
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)
    view.addSubview(strip)
    NSLayoutConstraint.activate([
      strip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.topAnchor.constraint(equalTo: strip.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    let api = session.api
    let selector = selector
    Task { await api.activate(worktree: selector) }
    tabsTask = Task { [weak self] in
      let subscription = await api.tabs(worktree: selector)
      do {
        for try await frame in subscription.events {
          self?.apply(SessionTabs(frame))
        }
      } catch {}
    }
  }

  override func updateProperties() {
    super.updateProperties()
    let worktree = session.worktree(id: worktreeId)
    title = worktree?.displayName
    let status = HostConnectionPresentation(session.connectionState)
    // "● 正在工作 · main": what the agent is doing in words, then the branch; offline, the connection's state.
    let state = worktree?.displayStatus ?? "idle"
    let word: String =
      switch state {
      case "working", "monitoring": String(localized: "sidebar.cardSlot.working", defaultValue: "Working")
      case "permission", "waiting", "blocked": String(localized: "workspace.activity.permission", defaultValue: "Needs permission")
      default: String(localized: "bots.row.idle", defaultValue: "Idle")
      }
    let branch = (worktree?.branch ?? "").replacingOccurrences(of: "refs/heads/", with: "")
    let line = status.connected ? ([word] + (branch.isEmpty ? [] : [branch])).joined(separator: " · ") : status.label
    let subtitle = NSMutableAttributedString(
      string: "● ",
      attributes: [
        .foregroundColor: status.connected ? AgentStatusDot.color(for: state == "idle" ? "done" : state) : status.dot,
        .font: UIFont.systemFont(ofSize: 11),
      ])
    subtitle.append(NSAttributedString(string: line, attributes: [.foregroundColor: Palette.textSecondary]))
    navigationItem.attributedSubtitle = AttributedString(subtitle)
    if let bot {
      // The title view carries the bot's own line; the branch is the bot's business.
      navigationItem.attributedSubtitle = nil
      botTitle.show(bot: bot, status: BotRowConfiguration.statusWord(bot, home: worktree), dot: status.dot)
    }
    updateStrip()
  }

  private func apply(_ next: SessionTabs) {
    tabs = next
    tabsLoaded = true
    if next.removed {
      navigationController?.popViewController(animated: true)
      return
    }
    if let focus = focusSessionId,
      let tab = next.tabs.first(where: { if case .agentSession(let id, _) = $0.kind { id == focus } else { false } })
    {
      focusSessionId = nil
      show(tab)
      updateStrip()
      let api = session.api
      let selector = selector
      Task { await api.activateTab(tab.id, worktree: selector) }
      return
    }
    let active = next.tabs.first { $0.id == next.activeTabId } ?? next.tabs.first
    show(active)
    updateStrip()
  }

  private func updateStrip() {
    let active = tabs.tabs.first { $0.id == shownTabId }
    let agentState = session.worktree(id: worktreeId)?.agents.first?.state
    strip.show(tabs: tabs.tabs, shownId: active?.id, agentState: agentState, botHome: bot != nil)
  }

  private func show(_ tab: SessionTab?) {
    guard tab?.id != shownTabId || (tab == nil && tabsLoaded && !(current is NoTabsViewController)) else { return }
    shownTabId = tab?.id
    let next: UIViewController
    switch tab?.kind {
    case .agentSession(let sessionId, _):
      if let existing = chats[sessionId] {
        next = existing
      } else {
        let worktree = session.worktree(id: worktreeId)
        let model = ChatSessionModel(
          api: session.api, sessionId: sessionId, capabilities: session.status?.capabilities ?? [],
          connectionId: worktree.flatMap { session.repo(id: $0.repoId)?.connectionId })
        let chat = ChatViewController(model: model)
        chat.imageLoader = ChatImageLoader(api: session.api, worktreeId: worktreeId)
        chat.isBotChat = bot != nil
        let api = session.api
        let searchIn = worktreeId
        chat.searchFiles = { query in (try? await api.searchPaths(worktreeId: searchIn, query: query)) ?? [] }
        let agentType: String? = { if case .agentSession(_, let agent) = tab?.kind { return agent } else { return nil } }()
        chat.onActivity = { [weak self] working, detail in
          guard let self, let worktree = self.session.worktree(id: self.worktreeId) else { return }
          AgentActivityCenter.shared.reportChat(
            hostId: self.session.host.id, hostName: self.session.name, worktree: worktree, agentType: agentType,
            working: working, detail: detail)
        }
        chat.onOpenPath = { [weak self] path in self?.openPath(path) }
        // Fork from a response: a new chat with the same agent, holding this one through that answer.
        chat.onFork = { [weak self] itemId in
          guard let self else { return }
          let api = self.session.api
          let selector = self.selector
          self.run { try await api.createChat(agent: agentType ?? "claude", worktree: selector, forkFrom: (sessionId, itemId)) }
        }
        chats[sessionId] = chat
        next = chat
      }
    case .terminal(let handle?):
      next = TerminalTabController(
        api: session.api, handle: handle,
        sendsQueryReplies: session.status?.supports(HostCapability.terminalQueryReply) ?? false,
        colors: tab?.terminalColors)
    case .markdown(let path), .file(let path, _):
      // A note or file tab reads as its preview: Markdown rendered, code highlighted.
      next = FilePreviewViewController(session: session, worktreeId: worktreeId, path: path)
    case nil where tabsLoaded:
      let api = session.api
      let selector = selector
      next = NoTabsViewController { [weak self] in self?.run { try await api.createTerminalTab(worktree: selector) } }
    default:
      next = UnsupportedTabViewController(tab: tab)
    }
    (current as? WorkspaceContent)?.close()
    if let current {
      current.willMove(toParent: nil)
      current.view.removeFromSuperview()
      current.removeFromParent()
    }
    addChild(next)
    content.addSubview(next.view)
    next.view.pin(to: content)
    next.didMove(toParent: self)
    current = next
  }

  // MARK: Panels

  /// A path from a chat, resolved by the desktop as the official file tap does: relative, absolute or `~/…`,
  /// in this workspace, a sibling one, or anywhere the desktop grants a read.
  private func openPath(_ path: String) {
    // One lookup at a time: taps while it runs (or a tap reaching here twice) are dropped.
    guard !resolvingPath else { return }
    resolvingPath = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let api = session.api
    let worktreeId = worktreeId
    // The chat on screen, whose agent wrote the path.
    let shown = tabs.tabs.first { $0.id == shownTabId }
    let chat: (tabId: String, sessionId: String)? = shown.flatMap { tab in
      if case .agentSession(let sessionId, _) = tab.kind { return (tab.id, sessionId) }
      return nil
    }
    let candidates = chat.flatMap { chats[$0.sessionId]?.candidatePaths(for: path) } ?? []
    let others = session.worktrees.filter { $0.id != worktreeId && !$0.isArchived }.map(\.id)
    let relative = !path.hasPrefix("/") && !path.hasPrefix("~")
    Task { [weak self] in
      defer { self?.resolvingPath = false }
      var failure: Error?
      var found: ResolvedPath?
      do {
        found = try await api.resolvePath(worktreeId: worktreeId, pathText: path, chat: chat)
      } catch {
        failure = error
      }
      // Not in this workspace: where the agent was working (its commands and files say), then the desktop's
      // other workspaces. All asked at once; the likeliest answer wins.
      if found == nil, relative {
        found = await withTaskGroup(of: (Int, ResolvedPath?).self) { group in
          for (rank, candidate) in candidates.enumerated() {
            group.addTask { (rank, try? await api.resolvePath(worktreeId: worktreeId, pathText: candidate, chat: chat)) }
          }
          for (index, other) in others.enumerated() {
            group.addTask { (candidates.count + index, try? await api.resolvePath(worktreeId: other, pathText: path)) }
          }
          var best: (Int, ResolvedPath)?
          for await (rank, hit) in group {
            if let hit, best == nil || rank < best!.0 { best = (rank, hit) }
          }
          return best?.1
        }
      }
      guard let self else { return }
      // A desktop that can't resolve paths: a relative path is read in this workspace as written.
      if found == nil, let failure {
        guard relative else {
          let message = (failure as? RPCError).map { $0.message.isEmpty ? $0.code : $0.message } ?? failure.localizedDescription
          self.sayOnce(title: path, message: message)
          return
        }
        found = .worktree(worktreeId: worktreeId, relativePath: self.relativeToWorkspace(path), isDirectory: false)
      }
      switch found {
      case .worktree(let id, let relative, false):
        self.navigationController?.pushViewController(
          FilePreviewViewController(session: self.session, worktreeId: id, path: relative), animated: true)
      case .worktree(let id, _, true):
        self.navigationController?.pushViewController(
          FileExplorerViewController(session: self.session, worktreeId: id), animated: true)
      case .absolute(let grant):
        self.navigationController?.pushViewController(
          FilePreviewViewController(session: self.session, worktreeId: worktreeId, path: grant.absolutePath, artifact: grant),
          animated: true)
      case nil:
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        self.sayOnce(title: String(localized: "files.filePreviewResponse.fileNotFound", defaultValue: "File not found"), message: path)
      }
    }
  }

  /// An alert, unless one is already up.
  private func sayOnce(title: String, message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  private func relativeToWorkspace(_ path: String) -> String {
    guard let root = session.worktree(id: worktreeId)?.path, !root.isEmpty, path.hasPrefix(root) else { return path }
    return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func openSourceControl() {
    navigationController?.pushViewController(SourceControlViewController(session: session, worktreeId: worktreeId), animated: true)
  }

  private func openFiles() {
    navigationController?.pushViewController(FileExplorerViewController(session: session, worktreeId: worktreeId), animated: true)
  }

  /// Past agent sessions here; one with a chat opens it in this workspace.
  private func openHistory() {
    let history = AgentHistoryViewController(session: session, worktreeId: worktreeId)
    let session = session
    history.onOpenChat = { [weak self] worktreeId, sessionId in
      guard let self else { return }
      if worktreeId == self.worktreeId {
        self.focusSessionId = sessionId
        self.navigationController?.popToViewController(self, animated: true)
        self.apply(self.tabs)
      } else {
        self.navigationController?.pushViewController(
          SessionViewController(session: session, worktreeId: worktreeId, sessionId: sessionId), animated: true)
      }
    }
    navigationController?.pushViewController(history, animated: true)
  }

  /// A bot's items; an item's chat opens here, in its home.
  private func openItems() {
    guard let bot else { return }
    let items = BotItemsViewController(session: session, botId: bot.id)
    items.onOpenChat = { [weak self] sessionId in
      guard let self else { return }
      self.focusSessionId = sessionId
      self.navigationController?.popToViewController(self, animated: true)
      self.apply(self.tabs)
    }
    navigationController?.pushViewController(items, animated: true)
  }

  /// A terminal, or a chat with an agent.
  private func newTabMenu() -> UIMenu {
    let api = session.api
    let selector = selector
    return UIMenu(
      title: String(localized: "session.tabStrip.newTab", defaultValue: "New tab"),
      children: [
        UIAction(
          title: String(localized: "session.header.terminalTitle", defaultValue: "Terminal"),
          image: Lucide.squareTerminal.image(size: 18)
        ) { [weak self] _ in self?.run { try await api.createTerminalTab(worktree: selector) } },
        UIAction(title: "Claude", image: AgentMark.claude.image(size: 18)) { [weak self] _ in
          self?.run { try await api.createChat(agent: "claude", worktree: selector) }
        },
        UIAction(title: "Codex", image: AgentMark.codex.image(size: 18)) { [weak self] _ in
          self?.run { try await api.createChat(agent: "codex", worktree: selector) }
        },
        UIMenu(
          options: .displayInline,
          children: [
            UIAction(
              title: String(localized: "session.sheets.markdownNote", defaultValue: "Markdown Note"),
              image: Lucide.fileText.image(size: 18)
            ) { [weak self] _ in self?.run { try await api.createMarkdownNote(worktree: selector) } },
          ]),
      ])
  }

  private static func icon(for tab: SessionTab) -> UIImage? {
    switch tab.kind {
    case .agentSession(_, let agent): return AgentMark.icon(for: agent)?.image(size: 18)
    case .browser: return Lucide.globe.image(size: 18)
    case .file, .markdown: return Lucide.fileText.image(size: 18)
    default: return Lucide.squareTerminal.image(size: 18)
    }
  }

  /// A tab write; the tabs subscription shows its result, and a refusal is said.
  private func run(_ write: @escaping () async throws -> Void) {
    Task {
      do {
        try await write()
      } catch {
        let message = (error as? RPCError)?.message ?? error.localizedDescription
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
    }
  }

  // While this workspace is on screen, its own pushes don't alert (Settings › Notifications › Suppress while
  // focused).
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    PushCenter.viewing = (hostKey: session.host.id.uuidString, worktreeId: worktreeId, executionHost: nil)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if PushCenter.viewing?.worktreeId == worktreeId { PushCenter.viewing = nil }
  }

  /// Text size for what is on screen: the terminal's font in a terminal tab, the chat's text otherwise.
  private func openTextSize() {
    guard current is TerminalTabController else {
      present(ChatTextSettingsController.sheet(), animated: true)
      return
    }
    let navigation = UINavigationController(rootViewController: TerminalSettingsViewController())
    navigation.topViewController?.title = String(localized: "session.textSizeSheet.terminalTitle", defaultValue: "Terminal text")
    navigation.topViewController?.navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .done, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(navigation, animated: true)
  }

  private func moreMenu() -> UIMenu {
    UIMenu(children: [
      UIAction(
        title: String(localized: "session.header.fileExplorer", defaultValue: "File explorer"),
        image: Lucide.folderTree.image(size: 18)) { [weak self] _ in self?.openFiles() },
      UIAction(
        title: String(localized: "session.headerMoreActionsSheet.agentHistory", defaultValue: "Agent History"),
        image: Lucide.history.image(size: 18)) { [weak self] _ in self?.openHistory() },
      UIAction(
        title: String(localized: "session.header.textSize", defaultValue: "Text size"),
        image: Lucide.aLargeSmall.image(size: 18)) { [weak self] _ in self?.openTextSize() },
    ])
  }
}

/// A tab this client cannot open yet.
private final class UnsupportedTabViewController: UIViewController {
  private let sessionTab: SessionTab?

  init(tab: SessionTab?) {
    sessionTab = tab
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    let label = TextLabel(
      sessionTab == nil
        ? String(localized: "session.openingWorkspace", defaultValue: "Opening workspace")
        : String(localized: "orcaios.session.tabUnsupported", defaultValue: "This tab can't be opened on the phone yet"),
      size: Typography.bodySize, color: Palette.textSecondary, alignment: .center, lines: 0)
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Spacing.xl),
    ])
  }
}

/// A bot home's title: its face beside its name, then its state under them (MobileSessionTitleBlock.tsx).
private final class BotTitleView: UIView {
  private let avatar = BotAvatarView(size: 20)
  private let name = TextLabel(size: 17, weight: .semibold)
  private let status = UILabel()

  init() {
    super.init(frame: .zero)
    let top = UIStackView(arrangedSubviews: [avatar, name])
    top.spacing = 6
    top.alignment = .center
    let column = UIStackView(arrangedSubviews: [top, status])
    column.axis = .vertical
    column.alignment = .center
    column.spacing = 1
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    column.pin(to: self)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(bot: Bot, status word: String, dot: UIColor) {
    avatar.show(bot)
    name.text = bot.name
    let line = NSMutableAttributedString(
      string: "●  ", attributes: [.foregroundColor: dot, .font: UIFont.systemFont(ofSize: 11)])
    line.append(NSAttributedString(string: word, attributes: [.foregroundColor: Palette.textSecondary, .font: UIFont.systemFont(ofSize: 13)]))
    status.attributedText = line
    accessibilityLabel = "\(bot.name), \(word)"
    isAccessibilityElement = true
  }
}

/// A workspace with no tabs (MobileSessionContentState.tsx): says so, and makes one.
private final class NoTabsViewController: UIViewController {
  private let onCreate: () -> Void

  init(onCreate: @escaping () -> Void) {
    self.onCreate = onCreate
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    let icon = LucideView(.squareTerminal, size: 34, strokeWidth: 1.6, color: Palette.textMuted)
    let title = TextLabel(
      String(localized: "session.activeContent.noTabs", defaultValue: "No tabs in this session"), size: 17,
      weight: .semibold, alignment: .center)
    var configuration = UIButton.Configuration.prominentGlass()
    configuration.title = String(localized: "session.activeContent.createTab", defaultValue: "Create Tab")
    configuration.baseBackgroundColor = Palette.accentBlue
    let create = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onCreate() })
    let stack = UIStackView(arrangedSubviews: [icon, title, create])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = Spacing.md
    stack.setCustomSpacing(Spacing.lg, after: title)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }
}
