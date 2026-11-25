import Testing

@testable import OrcaCore

@MainActor
@Suite struct RemoteOrcaServerTests {
  nonisolated private static let serverId: JSONValue = "runtime:server"
  nonisolated private static let server: JSONValue = [
    "hostId": serverId, "label": "Build server", "health": "available", "relay": "ready", "installationId": "server-store",
  ]

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
        socket.stream(request, ["type": "snapshot", "tabs": []])
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
    #expect(try await tabEvents.next()?["type"] == "snapshot")
    await server.api.connection.unsubscribe(tabs.requestId)

    let terminal = await server.api.terminal(handle: "shell", cols: 80, rows: 24)
    var terminalFrames = terminal.frames.makeAsyncIterator()
    #expect(try await terminalFrames.next() == .reply(["type": "subscribed", "streamId": 17]))
    #expect(try await terminalFrames.next() == .binary([1, 2, 3]))
    try await server.api.sendTerminalInput("pwd\n", handle: "shell")
    await server.api.connection.unsubscribe(terminal.requestId)

    let requests = host.seenRequests
    let routedMethods = ["session.tabs.subscribe", "session.tabs.unsubscribe", "terminal.subscribe", "terminal.send", "terminal.unsubscribe"]
    for method in routedMethods {
      #expect(requests.first { $0["method"]?.stringValue == method }?["executionHost"] == Self.serverId)
    }
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
