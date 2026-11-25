import Testing

@testable import OrcaCore

@MainActor
@Suite struct RemoteOrcaServerTests {
  nonisolated private static let serverId: JSONValue = "runtime:server"
  nonisolated private static let server: JSONValue = [
    "hostId": serverId, "label": "Build server", "health": "available", "relay": "ready", "installationId": "server-store",
  ]

  @Test func prefersAnExplicitPairingAndOtherwiseChoosesOneLiveRelayPerInstallation() async throws {
    let relay = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "status.get":
        socket.succeed(request, ["capabilities": [.string(HostCapability.desktopRelay)]])
      case "mobileRelay.hosts.list":
        socket.succeed(request, ["hosts": [
          ["hostId": "runtime:offline", "label": "Build server", "relay": "unavailable", "installationId": "server-store"],
          Self.server,
          ["hostId": "runtime:other", "label": "Build server", "relay": "ready", "installationId": "another-store"],
          ["hostId": "runtime:unknown", "label": "Build server", "relay": "ready", "installationId": ""],
        ]])
      case "mobileRelay.hosts.worktrees":
        let host = request["params"]?["hostId"] ?? .null
        socket.succeed(request, ["worktrees": host == "runtime:offline" ? .null : [
          ["hostId": host, "worktreeId": "same-id", "repoId": "repo"],
        ]])
      default:
        socket.succeed(request, [:])
      }
    }
    let direct = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "status.get":
        socket.succeed(request, ["hostDescriptor": ["installationId": "server-store"]])
      default:
        socket.succeed(request, [:])
      }
    }
    func pairing(_ host: FakeHost) -> PairedHost {
      PairedHost(name: "Build server", offer: PairingOffer(
        endpoint: "ws://host.test:6768", deviceToken: "token", publicKeyB64: host.publicKeyB64))
    }
    let a = HostSession(host: pairing(relay), clientId: "phone", dialer: relay, logStore: nil)
    let learned = LockedBox<String?>(nil)
    let b = HostSession(host: pairing(direct), clientId: "phone", dialer: direct, logStore: nil, onInstallationId: {
      learned.set($0)
    })
    a.start()
    defer { a.stop(); b.stop() }
    await eventually("relayed workspace catalogs") {
      a.remoteServers.count == 4 && a.remoteServers.filter(\.hasLiveWorktrees).count == 3
    }
    let candidates = a.remoteServers
    func visible(with paired: [HostSession]) -> [String] {
      HostSession.visibleRemoteServers(candidates, paired: paired).compactMap { $0.remoteServer?.id }
    }
    #expect(visible(with: [a, b]) == ["runtime:server", "runtime:other", "runtime:unknown"])
    b.start()
    await eventually("the directly paired installation identity") { learned.get() == "server-store" }
    #expect(visible(with: [a, b]) == ["runtime:other", "runtime:unknown"])
    #expect(visible(with: [a]) == ["runtime:server", "runtime:other", "runtime:unknown"])

    var saved = b.host
    saved.installationId = try #require(learned.get())
    let offline = HostSession(host: saved, clientId: "phone", logStore: nil)
    #expect(visible(with: [a, offline]) == ["runtime:other", "runtime:unknown"])
    #expect(a.remoteServers.count == 4)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func discoversServerWorkspacesAndRoutesTabsTerminalAndCleanupThroughDesktop(useCloudRelay: Bool) async throws {
    let serverOnline = LockedBox(true)
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "status.get" where request["executionHost"] == nil:
        socket.succeed(request, ["capabilities": [.string(HostCapability.desktopRelay)]])
      case "status.get":
        socket.succeed(request, ["machineName": "Server runtime"])
      case "worktree.ps":
        socket.succeed(request, ["worktrees": [["worktreeId": "same-id", "repoId": "local", "displayName": "Local workspace"]]])
      case "mobileRelay.hosts.list":
        let unavailable: JSONValue = ["hostId": Self.serverId, "label": "Build server", "health": "disconnected",
                                      "relay": "unavailable", "installationId": "server-store"]
        socket.succeed(request, ["hosts": [serverOnline.get() ? Self.server : unavailable]])
      case "mobileRelay.hosts.worktrees":
        socket.succeed(request, ["worktrees": serverOnline.get() ? [
          ["hostId": Self.serverId, "worktreeId": "same-id", "repoId": "remote", "displayName": "Remote workspace"],
          ["hostId": "runtime:other", "worktreeId": "foreign", "repoId": "foreign"],
        ] : .null])
      case "mobileRelay.projectSections":
        socket.succeed(request, ["catalog": [
          "repos": [["id": "local", "displayName": "Desktop"], ["id": "remote", "displayName": "Server", "executionHostId": Self.serverId]],
          "projects": [["id": "shared", "displayName": "Shared"]],
          "setups": [["repoId": "local", "hostId": "local", "projectId": "shared"],
                     ["repoId": "remote", "hostId": Self.serverId, "projectId": "shared"]],
        ]])
      case "session.tabs.subscribe":
        socket.stream(request, ["type": "ready"])
        socket.stream(request, ["type": "snapshot", "tabs": [], "publicationEpoch": "none:client-navigation"])
        socket.stream(request, ["type": "snapshot", "tabs": []])
      case "session.tabs.list":
        socket.succeed(request, [
          "activeTabId": "desktop-tab",
          "tabs": [
            ["id": "structured", "type": "agent-session", "agent": "codex", "sessionId": "agent-id"],
            ["id": "desktop-tab::left", "type": "terminal", "parentTabId": "desktop-tab", "leafId": "left", "terminal": "shell-left"],
            ["id": "desktop-tab::right", "type": "terminal", "parentTabId": "desktop-tab", "leafId": "right",
             "terminal": "shell-right", "isActive": true],
            ["id": "split:tab", "type": "terminal", "terminal": "shell"],
          ],
        ])
      case "agentSession.reveal":
        socket.succeed(request, ["ok": true, "sessionId": "agent-id", "workspaceId": "same-id"])
      case "session.tabs.activate":
        socket.succeed(request, ["tabs": [["id": "desktop-tab::right", "type": "terminal", "terminal": "shell-right"]]])
      case "agentSession.subscribe":
        socket.stream(request, ["type": "snapshot", "items": []])
      case "terminal.subscribe":
        socket.stream(request, ["type": "subscribed", "streamId": 17])
        socket.binary([1, 2, 3])
      default:
        socket.succeed(request, [:])
      }
    }
    let offer = PairingOffer(endpoint: "ws://host.test:6768", deviceToken: "token", publicKeyB64: host.publicKeyB64)
    var paired = PairedHost(name: "Desktop", offer: offer)
    if useCloudRelay {
      host.directReachable = false
      paired.relay = RelayTests.endpoint
      paired.relayCredentials = RelayTests.bundle()
    }
    let desktop = HostSession(host: paired, clientId: "phone", dialer: host, logStore: nil)
    desktop.start()
    defer { desktop.stop() }

    await eventually("both workspace catalogs") {
      desktop.worktrees.count == 1 && desktop.remoteServers.first?.worktrees.count == 1
    }
    let server = try #require(desktop.remoteServers.first)
    #expect(desktop.path == (useCloudRelay ? .relay : .direct))
    #expect(desktop.worktree(id: "same-id")?.displayName == "Local workspace")
    #expect(server.worktree(id: "same-id")?.displayName == "Remote workspace")
    await eventually("the desktop project catalog") {
      desktop.workspaceProjects.project(hostId: "runtime:server", repoId: "remote", fallbackName: "Server").id == "project:shared"
    }
    #expect(server.cacheNamespace != desktop.cacheNamespace)
    #expect(try await server.api.status().machineName == "Server runtime")

    let tabs = await server.api.tabs(worktree: "id:same-id")
    var tabEvents = tabs.events.makeAsyncIterator()
    let ready = try #require(try await tabEvents.next())
    #expect(!hasSessionTabsSnapshot(ready))
    let unpublished = try #require(try await tabEvents.next())
    #expect(!hasSessionTabsSnapshot(unpublished))
    let snapshot = try #require(try await tabEvents.next())
    #expect(hasSessionTabsSnapshot(snapshot))
    await server.api.connection.unsubscribe(tabs.requestId)

    let replay = try await server.api.tabsSnapshot(worktree: "id:same-id")
    let inventory = SessionTabs(replay)
    #expect(inventory.agentTab(sessionId: "orca_session_id:agent-id", paneKey: "other")?.id == "structured")
    #expect(inventory.agentTab(
      sessionId: nil, paneKey: "structured-agent-session-agent-id:b1003ddd-4777-4bf5-a4c8-400bc21a330a")?.id == "structured")
    #expect(SessionTabs.structuredSessionID(forPaneKey: "structured-agent-session-agent-id:b1003ddd-4777-4bf5-a4c8-400bc21a330b") == nil)
    #expect(inventory.agentTab(sessionId: nil, paneKey: "desktop-tab:left")?.terminalHandle == "shell-left")
    #expect(inventory.agentTab(sessionId: nil, paneKey: "desktop-tab:right")?.terminalHandle == "shell-right")
    #expect(inventory.agentTab(sessionId: nil, paneKey: "desktop-tab:missing") == nil)
    #expect(inventory.activeTab?.terminalHandle == "shell-right")
    let activated = try await server.api.activateTab("desktop-tab::right", worktree: "id:same-id")
    #expect(SessionTabs(activated).activeTab?.terminalHandle == "shell-right")
    #expect(inventory.agentTab(sessionId: nil, paneKey: "split:tab:leaf")?.id == "split:tab")
    #expect(inventory.agentTab(sessionId: nil, paneKey: "split:tab")?.id == "split:tab")
    #expect(try await server.api.revealChat(sessionId: "agent-id", in: "same-id"))
    #expect(try await server.api.revealChat(sessionId: "agent-id", in: "other-workspace") == false)
    let chat = await server.api.chat(sessionId: "agent-id", resumingFrom: nil)
    var chatEvents = chat.events.makeAsyncIterator()
    #expect(try await chatEvents.next()?["type"] == "snapshot")
    await server.api.connection.unsubscribe(chat.requestId)

    let terminal = await server.api.terminal(handle: "shell", cols: 80, rows: 24)
    var terminalFrames = terminal.frames.makeAsyncIterator()
    #expect(try await terminalFrames.next() == .reply(["type": "subscribed", "streamId": 17]))
    #expect(try await terminalFrames.next() == .binary([1, 2, 3]))
    try await server.api.sendTerminalInput("pwd\n", handle: "shell")
    await server.api.connection.unsubscribe(terminal.requestId)

    let requests = host.seenRequests
    let routedMethods = ["session.tabs.subscribe", "session.tabs.unsubscribe", "session.tabs.list", "session.tabs.activate", "agentSession.reveal",
                         "agentSession.subscribe", "agentSession.unsubscribe", "terminal.subscribe", "terminal.send", "terminal.unsubscribe"]
    for method in routedMethods {
      #expect(requests.first { $0["method"]?.stringValue == method }?["executionHost"] == Self.serverId)
    }
    let activation = try #require(requests.first { $0["method"] == "session.tabs.activate" })
    #expect(activation["params"]?["navigation"] == "caller")
    #expect(activation["params"]?["notifyClients"] == false)
    let catalogCall = try #require(requests.first { $0["method"] == "mobileRelay.hosts.worktrees" })
    #expect(catalogCall["params"] == ["hostId": Self.serverId])
    #expect(catalogCall["executionHost"] == nil)

    serverOnline.set(false)
    await desktop.refresh()
    #expect(server.connectionState == .disconnected)
    #expect(server.worktree(id: "same-id")?.displayName == "Remote workspace")
    #expect(!server.hasLiveWorktrees)
    await #expect(throws: RPCError.self) { try await server.api.sendTerminalInput("a", handle: "shell") }

    serverOnline.set(true)
    await desktop.refresh()
    #expect(desktop.remoteServers.first === server)
    #expect(server.connectionState == .connected)
    #expect(server.hasLiveWorktrees)
  }

  @Test(.timeLimit(.minutes(1))) func onlyReplaysStreamsAfterTheNewSocketVerifiesRelayAndServerIdentity() async throws {
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "status.get":
        socket.succeed(request, ["capabilities": socket.serial == 2 ? [] : [.string(HostCapability.desktopRelay)]])
      case "mobileRelay.hosts.list":
        socket.succeed(request, ["hosts": [Self.server]])
      case "session.tabs.subscribe":
        socket.stream(request, ["type": "snapshot", "socket": .number(Double(socket.serial))])
      default:
        socket.succeed(request, [:])
      }
    }
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    let desktop = HostAPI(connection: connection, clientId: "phone")
    await connection.start()
    _ = try await desktop.status()
    let catalog = try await desktop.remoteServers()
    let server = try #require(catalog?.first)
    let api = HostAPI(connection: connection, clientId: "phone", server: server, remoteCacheNamespace: nil)
    let subscription = await api.tabs(worktree: "id:workspace")
    var events = subscription.events.makeAsyncIterator()
    #expect(try await events.next()?["socket"] == 1)

    host.lastSocket?.drop()
    await eventually("a replacement desktop socket") { host.dialCount == 2 }
    #expect(try await desktop.status().supports(HostCapability.desktopRelay) == false)
    await #expect(throws: RPCError.self) { try await api.sendTerminalInput("a", handle: "terminal") }
    #expect(host.seenRequests.filter { $0["executionHost"] != nil }.count == 1)

    host.lastSocket?.drop()
    await eventually("a relay-capable desktop socket") { host.dialCount == 3 }
    #expect(try await desktop.status().supports(HostCapability.desktopRelay))
    #expect(host.seenRequests.filter { $0["executionHost"] != nil }.count == 1)
    _ = try await desktop.remoteServers()
    #expect(try await events.next()?["socket"] == 3)
    #expect(host.seenRequests.filter { $0["executionHost"] == Self.serverId }.count == 2)
    await connection.close()
  }

  @Test(.timeLimit(.minutes(1))) func retriesAStreamWhenTheServerLinkDropsWhileTheDesktopStaysConnected() async throws {
    let restored = LockedBox(false)
    let host = FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "status.get":
        socket.succeed(request, ["capabilities": [.string(HostCapability.desktopRelay)]])
      case "mobileRelay.hosts.list":
        socket.succeed(request, ["hosts": [Self.server]])
      case "session.tabs.subscribe" where !restored.get():
        socket.reply(["id": request["id"] ?? .null, "ok": false, "error": ["code": "remote_runtime_unavailable"]])
      case "session.tabs.subscribe":
        socket.stream(request, ["type": "snapshot"])
      default:
        socket.succeed(request, [:])
      }
    }
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    let desktop = HostAPI(connection: connection, clientId: "phone")
    await connection.start()
    _ = try await desktop.status()
    let catalog = try await desktop.remoteServers()
    let server = try #require(catalog?.first)
    let api = HostAPI(connection: connection, clientId: "phone", server: server, remoteCacheNamespace: nil)
    let subscription = await api.tabs(worktree: "id:workspace")
    var events = subscription.events.makeAsyncIterator()
    _ = try await connection.request("flush")

    restored.set(true)
    _ = try await desktop.remoteServers()
    #expect(try await events.next()?["type"] == "snapshot")
    #expect(host.dialCount == 1)
    let requests = host.seenRequests.filter { $0["method"] == "session.tabs.subscribe" }
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0["executionHost"] == Self.serverId })
    await connection.close()
  }
}
