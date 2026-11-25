import CryptoKit
import Foundation
import Observation

/// One paired desktop while the app is using it: its connection, status and workspace list.
/// Screens observe it; nothing here touches UIKit.
@MainActor
@Observable
public final class HostSession {
  public private(set) var host: PairedHost
  public let api: HostAPI
  public let cacheNamespace: String
  public private(set) var installationId: String?
  public private(set) var remoteServers: [HostSession] = []
  public private(set) var workspaceProjects = WorkspaceProjectCatalog()
  public private(set) var remoteServer: RemoteOrcaServer?
  @ObservationIgnored private weak var desktop: HostSession?
  @ObservationIgnored private let onInstallationId: (@Sendable (String) -> Void)?

  public private(set) var connectionState: ConnectionState = .disconnected
  public private(set) var status: HostStatus?
  public private(set) var worktrees: [Worktree] = []
  /// A catalog read succeeded on the current connection. Disk and previous connection data don't qualify.
  public private(set) var hasLiveWorktrees = false
  public private(set) var repos: [Repo] = []
  /// The host's bots; empty on a host without them.
  public private(set) var bots = BotsListing()
  /// True until the first workspace list arrives.
  public private(set) var isLoading = true
  public private(set) var loadError: String?
  /// The newest steps of dialing this desktop, oldest first, for Network diagnostics: kept across launches.
  public private(set) var connectionLog: [ConnectionLogEntry] = []
  @ObservationIgnored private let logStore: PersistedConnectionLog?
  /// When the connection last came up, for the diagnostics report.
  public private(set) var lastConnectedAt: Date?

  @ObservationIgnored private var catalog = WorktreeCatalog()
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshQueued = false
  @ObservationIgnored private var remoteRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var remoteRefreshQueued = false
  @ObservationIgnored private var statusFetchedAt: Date?

  /// How often the list is read again even when no event asked for it.
  static let pollInterval: Duration = .seconds(20)

  public private(set) var path: ConnectionPath?

  /// `onRelayUpdate` receives relay assignments and credentials to save with the host.
  public init(
    host: PairedHost, clientId: String, dialer: any WebSocketDialer = URLSessionWebSocketDialer(),
    logStore: PersistedConnectionLog? = .shared,
    onInstallationId: (@Sendable (String) -> Void)? = nil,
    onRelayUpdate: (@Sendable (RelayEndpoint, RelayCredentialBundle) -> Void)? = nil
  ) {
    self.host = host
    self.logStore = logStore
    self.onInstallationId = onInstallationId
    installationId = host.installationId
    cacheNamespace = host.id.uuidString
    connectionLog = PersistedConnectionLog.merge(stored: logStore?.load(hostId: host.id.uuidString) ?? [], live: [])
    var configuration = host.connectionConfiguration
    configuration.clientCapabilities = ClientCapability.all
    configuration.onRelayUpdate = onRelayUpdate
    api = HostAPI(connection: OrcaConnection(configuration: configuration, dialer: dialer), clientId: clientId)
    restoreFromCache()
  }

  private init(desktop: HostSession, server: RemoteOrcaServer) {
    self.desktop = desktop
    remoteServer = server
    installationId = server.installationId
    onInstallationId = nil
    let host = desktop.host
    self.host = host
    logStore = nil
    let key = [host.id.uuidString, server.id, server.route.installationId ?? ""].joined(separator: "\u{0}")
    cacheNamespace = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    api = HostAPI(
      connection: desktop.api.connection.transport, clientId: desktop.api.clientId, server: server, remoteCacheNamespace: cacheNamespace)
  }

  // MARK: Cache

  /// The lists as last read, kept on disk: a desktop's workspaces and bots show at once, before it answers.
  @ObservationIgnored private lazy var cache = FrameCache(name: "host-" + host.id.uuidString, maxBytes: 8 * 1024 * 1024)

  private func restoreFromCache() {
    guard let saved = cache.load().last else { return }
    if let rows = saved["worktrees"]?.arrayValue, let restored = WorktreeCatalog.restored(rows: rows) {
      catalog = restored
      worktrees = restored.worktrees
      // A list is on screen; the desktop's answer refreshes it rather than replacing a spinner.
      isLoading = false
    }
    // Kept as read, so a save before the desktop answers again doesn't drop them.
    if let repos = saved["repos"] {
      savedRepos = repos
      self.repos = (repos["repos"]?.arrayValue ?? []).compactMap(Repo.init)
    }
    if let bots = saved["bots"] {
      savedBots = bots
      self.bots = BotsListing(bots)
    }
  }

  @ObservationIgnored private var savedRepos: JSONValue?
  @ObservationIgnored private var savedBots: JSONValue?

  private func saveToCache() {
    var saved: [String: JSONValue] = ["worktrees": .array(catalog.rawRows.filter { $0 != .null })]
    if let savedRepos { saved["repos"] = savedRepos }
    if let savedBots { saved["bots"] = savedBots }
    cache.record(.object(saved), isSnapshot: true)
  }

  public func start() {
    guard desktop == nil, remoteServer == nil, tasks.isEmpty else {
      return
    }
    let connection = api.connection.transport
    tasks.append(Task { [weak self] in
      for await entry in await connection.logEvents() {
        guard let self else {
          return
        }
        self.connectionLog = PersistedConnectionLog.trimmed(self.connectionLog + [entry.redacted()])
        self.logStore?.save(hostId: self.host.id.uuidString, entries: self.connectionLog)
      }
    })
    tasks.append(Task { [weak self] in
      await connection.start()
      for await state in await connection.states() {
        guard let self else {
          return
        }
        let wasConnected = self.connectionState == .connected
        self.connectionState = state
        if state != .connected {
          self.hasLiveWorktrees = false
          for server in self.remoteServers { server.applyRemoteConnection(state) }
        }
        self.path = await connection.path
        if state == .connected, !wasConnected {
          self.lastConnectedAt = Date()
          self.scheduleRefresh()
          self.scheduleRemoteRefresh()
        }
      }
    })
    let api = api
    tasks.append(Task { [weak self] in
      // The connection replays this stream on each reconnect.
      let events = await api.clientEvents()
      do {
        for try await event in events.events {
          switch event["type"]?.stringValue {
          case "ready", "worktreesChanged", "reposChanged", "worktreeRowsChanged", "agentListChanged", "workspaceMetadataSet",
            "botsChanged":
            self?.scheduleRefresh()
          case "relayHostsChanged":
            self?.scheduleRemoteRefresh()
          default:
            break
          }
        }
      } catch {
        // The poll keeps the lists fresh on a host without this stream.
      }
    })
    tasks.append(Task { [weak self] in
      while (try? await Task.sleep(for: Self.pollInterval)) != nil {
        self?.scheduleRefresh()
        self?.scheduleRemoteRefresh()
      }
    })
  }

  public func stop() {
    for task in tasks {
      task.cancel()
    }
    tasks = []
    refreshTask?.cancel()
    remoteRefreshTask?.cancel()
    for server in remoteServers { server.applyRemoteConnection(.disconnected) }
    let connection = api.connection
    Task { await connection.close() }
  }

  /// The app came forward or the network changed.
  public func nudge() {
    if let desktop {
      desktop.nudge()
      return
    }
    let connection = api.connection.transport
    Task { await connection.nudge() }
    scheduleRefresh()
    scheduleRemoteRefresh()
  }

  /// Reads the workspace list now. Calls made while one read is running fold into a single follow-up.
  public func refresh() async {
    if let desktop {
      desktop.scheduleRemoteRefresh()
      await desktop.remoteRefreshTask?.value
      return
    }
    scheduleRefresh()
    scheduleRemoteRefresh()
    await refreshTask?.value
    await remoteRefreshTask?.value
  }

  public func worktree(id: String) -> Worktree? {
    worktrees.first { $0.id == id }
  }

  public func repo(id: String) -> Repo? {
    repos.first { $0.id == id }
  }

  /// Directly paired stores own their rows. For a store reached only through relays, prefer the route
  /// that has read a live workspace list, keeping the caller's order when routes are equally usable.
  public static func visibleRemoteServers(_ candidates: [HostSession], paired: [HostSession]) -> [HostSession] {
    let pairedIds = Set(paired.compactMap(\.installationId))
    func availability(_ server: HostSession) -> Int {
      if server.hasLiveWorktrees { return 2 }
      return server.connectionState == .connected ? 1 : 0
    }
    var selected: [String: HostSession] = [:]
    for server in candidates {
      guard let id = server.installationId, !pairedIds.contains(id) else { continue }
      if let prior = selected[id], availability(prior) >= availability(server) { continue }
      selected[id] = server
    }
    return candidates.filter { server in
      guard let id = server.installationId else { return true }
      return selected[id] === server
    }
  }

  /// The name this phone gave the desktop, else the one it reports.
  public var name: String {
    remoteServer?.label ?? host.personalName ?? status?.machineName ?? host.name
  }

  /// Edit host saved this host: a new address redials on it.
  public func update(_ host: PairedHost) {
    let endpointChanged = host.endpoint != self.host.endpoint
    self.host = host
    guard endpointChanged else {
      return
    }
    let connection = api.connection.transport
    Task { await connection.updateEndpoint(host.endpoint) }
  }

  private func scheduleRefresh() {
    guard connectionState == .connected else {
      return
    }
    if refreshTask != nil {
      refreshQueued = true
      return
    }
    refreshTask = Task { [weak self] in
      repeat {
        self?.refreshQueued = false
        await self?.load()
      } while self?.refreshQueued == true && !Task.isCancelled
      self?.refreshTask = nil
    }
  }

  private func load() async {
    // Also when a reply from a dropped connection is thrown away below.
    defer { isLoading = false }
    var catalog = catalog
    let connectedAt = lastConnectedAt
    do {
      async let repos = api.reposReply()
      async let bots = api.botsReply()
      try await api.refresh(&catalog)
      guard connectionState == .connected, lastConnectedAt == connectedAt, !Task.isCancelled else { return }
      self.catalog = catalog
      if !hasLiveWorktrees { hasLiveWorktrees = true }
      if worktrees != catalog.worktrees {
        worktrees = catalog.worktrees
      }
      // An old host without `repo.list` still has a usable workspace list.
      if let repos = try? await repos {
        savedRepos = repos.raw
        if repos.repos != self.repos { self.repos = repos.repos }
      }
      // A host from before bots answers with an unknown method; it simply has none.
      if let bots = try? await bots {
        savedBots = bots.raw
        if bots.bots != self.bots { self.bots = bots.bots }
      }
      loadError = nil
      saveToCache()
    } catch {
      guard connectionState == .connected, lastConnectedAt == connectedAt, !Task.isCancelled else { return }
      hasLiveWorktrees = false
      loadError = Self.describe(error)
    }
  }

  private func isCurrent(_ connectedAt: Date?) -> Bool {
    connectionState == .connected && lastConnectedAt == connectedAt && !Task.isCancelled
  }

  private func scheduleRemoteRefresh() {
    guard connectionState == .connected,
      statusFetchedAt != lastConnectedAt || status?.supports(HostCapability.desktopRelay) == true
    else { return }
    if remoteRefreshTask != nil {
      remoteRefreshQueued = true
      return
    }
    remoteRefreshTask = Task { [weak self] in
      repeat {
        self?.remoteRefreshQueued = false
        await self?.loadRemoteServers()
      } while self?.remoteRefreshQueued == true && !Task.isCancelled
      self?.remoteRefreshTask = nil
    }
  }

  private func loadRemoteServers() async {
    let connectedAt = lastConnectedAt
    guard isCurrent(connectedAt) else { return }
    if statusFetchedAt != connectedAt {
      guard let status = try? await api.status(), isCurrent(connectedAt) else { return }
      statusFetchedAt = connectedAt
      self.status = status
      if let id = status.installationId, id != installationId {
        installationId = id
        onInstallationId?(id)
      }
    }
    guard status?.supports(HostCapability.desktopRelay) == true else {
      remoteServers = []
      workspaceProjects = WorkspaceProjectCatalog()
      return
    }
    guard let listed = try? await api.remoteServers(), isCurrent(connectedAt) else { return }
    let previous = Dictionary(uniqueKeysWithValues: remoteServers.compactMap { session in
      session.remoteServer.map { ($0.route, session) }
    })
    let next = listed.map { server in
      let session = previous[server.route] ?? HostSession(desktop: self, server: server)
      if session.remoteServer != server { session.remoteServer = server }
      let state: ConnectionState = server.availability == .ready ? .connected
        : (server.availability == .unavailable && ["available", "connecting", "provisioning", "waking"].contains(server.health)
           ? .connecting : .disconnected)
      session.applyRemoteConnection(state)
      return session
    }
    let routes = Set(listed.map(\.route))
    for (route, session) in previous where !routes.contains(route) { session.applyRemoteConnection(.disconnected) }
    if remoteServers.map(\.remoteServer?.route) != next.map(\.remoteServer?.route) { remoteServers = next }

    async let projects = try? api.workspaceProjects()

    // The desktop can return its last catalog even while a server is offline.
    let api = api
    await withTaskGroup(of: (Int, [Worktree]?).self) { group in
      for (index, server) in listed.enumerated() {
        group.addTask { (index, try? await api.remoteWorktrees(server: server)) }
      }
      for await (index, rows) in group where isCurrent(connectedAt) {
        let session = next[index]
        session.isLoading = false
        if let rows, session.worktrees != rows { session.worktrees = rows }
        session.hasLiveWorktrees = rows != nil && session.connectionState == .connected
      }
    }
    if let projects = await projects, isCurrent(connectedAt), projects != workspaceProjects {
      workspaceProjects = projects
    }
  }

  private func applyRemoteConnection(_ state: ConnectionState) {
    guard state != connectionState else { return }
    connectionState = state
    hasLiveWorktrees = false
    guard state == .connected else { return }
    lastConnectedAt = Date()
    let connectedAt = lastConnectedAt
    let api = api
    Task { [weak self] in
      async let repos = try? api.repos()
      async let bots = try? api.botsReply()
      let hostStatus = try? await api.status()
      if let self, self.isCurrent(connectedAt) { self.status = hostStatus }
      let (hostRepos, hostBots) = await (repos, bots)
      guard let self, self.isCurrent(connectedAt) else { return }
      self.repos = hostRepos ?? self.repos
      self.bots = hostBots?.bots ?? self.bots
    }
  }

  static func describe(_ error: Error) -> String {
    switch error {
    case let error as RPCError:
      return error.message.isEmpty ? error.code : error.message
    case ConnectionError.timedOut:
      return "The desktop did not answer in time."
    case ConnectionError.authenticationRejected:
      return "This phone is no longer paired with the desktop."
    case is ConnectionError:
      return "The connection to the desktop was interrupted."
    default:
      return error.localizedDescription
    }
  }
}
