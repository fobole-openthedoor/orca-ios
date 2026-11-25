import Foundation

/// A workspace's paired desktop and, when relayed, the execution host behind it.
public struct WorkspaceRoute: Hashable, Sendable {
  public let host: UUID
  public let executionHost: String?

  public init(host: UUID, executionHost: String? = nil) {
    self.host = host
    self.executionHost = executionHost
  }

  public func openURL(worktreeId: String) -> URL? {
    var components = URLComponents()
    components.scheme = "orca"
    components.host = "open"
    var items = [
      URLQueryItem(name: "host", value: host.uuidString),
      URLQueryItem(name: "worktree", value: worktreeId),
    ]
    if let executionHost {
      items.append(URLQueryItem(name: "executionHost", value: executionHost))
    }
    components.queryItems = items
    return components.url
  }
}
