import Foundation
import Observation

/// One paired desktop while the app is using it: its connection, status and workspace list.
/// Screens observe it; nothing here touches UIKit.
@MainActor
@Observable
public final class HostSession {
  public let host: PairedHost
  public let api: HostAPI

  public private(set) var connectionState: ConnectionState = .disconnected
  public private(set) var status: HostStatus?
  public private(set) var worktrees: [Worktree] = []
  public private(set) var repos: [Repo] = []
  /// The host's bots; empty on a host without them.
  public private(set) var bots = BotsListing()
  /// True until the first workspace list arrives.
  public private(set) var isLoading = true
  public private(set) var loadError: String?

  @ObservationIgnored private var catalog = WorktreeCatalog()
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshQueued = false

  /// How often the list is read again even when no event asked for it.
  static let pollInterval: Duration = .seconds(20)

  public private(set) var path: ConnectionPath?

  /// `onRelayUpdate` receives relay assignments and credentials to save with the host.
  public init(
    host: PairedHost, clientId: String, dialer: any WebSocketDialer = URLSessionWebSocketDialer(),
    onRelayUpdate: (@Sendable (RelayEndpoint, RelayCredentialBundle) -> Void)? = nil
  ) {
    self.host = host
    var configuration = host.connectionConfiguration
    configuration.clientCapabilities = ClientCapability.all
    configuration.onRelayUpdate = onRelayUpdate
    api = HostAPI(connection: OrcaConnection(configuration: configuration, dialer: dialer), clientId: clientId)
    restoreFromCache()
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
    guard tasks.isEmpty else {
      return
    }
    let connection = api.connection
    tasks.append(Task { [weak self] in
      await connection.start()
      for await state in await connection.states() {
        guard let self else {
          return
        }
        let wasConnected = self.connectionState == .connected
        self.connectionState = state
        self.path = await connection.path
        if state == .connected, !wasConnected {
          self.connected()
        }
      }
    })
    tasks.append(Task { [weak self] in
      while (try? await Task.sleep(for: Self.pollInterval)) != nil {
        self?.scheduleRefresh()
      }
    })
  }

  public func stop() {
    for task in tasks {
      task.cancel()
    }
    tasks = []
    refreshTask?.cancel()
    let connection = api.connection
    Task { await connection.close() }
  }

  /// The app came forward or the network changed.
  public func nudge() {
    let connection = api.connection
    Task { await connection.nudge() }
    scheduleRefresh()
  }

  /// Reads the workspace list now. Calls made while one read is running fold into a single follow-up.
  public func refresh() async {
    scheduleRefresh()
    await refreshTask?.value
  }

  public func worktree(id: String) -> Worktree? {
    worktrees.first { $0.id == id }
  }

  public func repo(id: String) -> Repo? {
    repos.first { $0.id == id }
  }

  public var name: String {
    status?.machineName ?? host.name
  }

  private func connected() {
    let api = api
    tasks.append(Task { [weak self] in
      if let status = try? await api.status() {
        self?.status = status
      }
    })
    tasks.append(Task { [weak self] in
      // Events are hints, never data. A second `ready` means the stream reconnected and some were missed.
      let events = await api.clientEvents()
      do {
        for try await event in events.events {
          switch event["type"]?.stringValue {
          case "ready", "worktreesChanged", "reposChanged", "worktreeRowsChanged", "agentListChanged", "workspaceMetadataSet",
            "botsChanged":
            self?.scheduleRefresh()
          default:
            break
          }
        }
      } catch {
        // The poll keeps the list fresh on a host without this stream.
      }
    })
    scheduleRefresh()
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
    var catalog = catalog
    do {
      async let repos = api.reposReply()
      async let bots = api.botsReply()
      try await api.refresh(&catalog)
      self.catalog = catalog
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
      loadError = Self.describe(error)
    }
    isLoading = false
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
