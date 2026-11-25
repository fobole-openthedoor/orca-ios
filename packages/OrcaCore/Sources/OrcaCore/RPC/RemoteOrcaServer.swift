import Foundation

/// An Orca runtime reachable through a paired desktop's mobile relay.
public struct RemoteOrcaServer: Sendable, Equatable {
  struct Route: Sendable, Hashable {
    let hostId: String
    let installationId: String?
  }

  public enum Availability: String, Sendable {
    case ready
    case updateNeeded = "update-needed"
    case unavailable
  }

  let route: Route
  public var id: String { route.hostId }
  public let label: String
  public let health: String
  public let availability: Availability

  init?(_ json: JSONValue) {
    guard let id = json["hostId"]?.stringValue, id.hasPrefix("runtime:"), id.count > "runtime:".count,
      id.utf8.count <= 1024
    else { return nil }
    route = Route(hostId: id, installationId: json["installationId"]?.stringValue)
    label = json["label"]?.stringValue ?? id
    health = json["health"]?.stringValue ?? "disconnected"
    availability = json["relay"]?.stringValue.flatMap(Availability.init(rawValue:)) ?? .unavailable
  }

  static func list(_ reply: JSONValue) -> [RemoteOrcaServer]? {
    guard let hosts = reply["hosts"]?.arrayValue else { return nil }
    var seen: Set<String> = []
    return hosts.compactMap(RemoteOrcaServer.init).filter { seen.insert($0.id).inserted }
  }
}

/// A host's RPC surface. A remote server shares the desktop's socket, but every operation names its server.
public struct HostRPC: Sendable {
  public let transport: OrcaConnection
  private let route: RemoteOrcaServer.Route?
  public var isRelayed: Bool { route != nil }

  init(transport: OrcaConnection, server: RemoteOrcaServer?) {
    self.transport = transport
    route = server?.route
  }

  public func request(_ method: String, _ params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
    try await transport.request(method, params, timeout: timeout, route: route)
  }

  @discardableResult
  func notify(_ method: String, _ params: JSONValue? = nil) async -> Bool {
    await transport.notify(method, params, route: route)
  }

  func subscribe(_ method: String, _ params: JSONValue? = nil, release: StreamRelease = .none) async -> RPCSubscription {
    await transport.subscribe(method, params, release: release, route: route)
  }

  func subscribeWithBinary(_ method: String, _ params: JSONValue? = nil, release: StreamRelease = .none) async -> RPCBinarySubscription {
    await transport.subscribeWithBinary(method, params, release: release, route: route)
  }

  public func unsubscribe(_ requestId: String) async {
    await transport.unsubscribe(requestId)
  }

  public func close() async {
    if route == nil { await transport.close() }
  }

  func updateReplayParams(of requestId: String, _ params: JSONValue?) async {
    await transport.updateReplayParams(of: requestId, params)
  }
}
