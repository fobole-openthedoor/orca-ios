import Foundation

/// One tab of a workspace's session, from `session.tabs.subscribe`.
public struct SessionTab: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// `handle` is nil while the host has listed the tab but not yet started its terminal.
    case terminal(handle: String?)
    case agentSession(sessionId: String, agent: String)
    case browser(url: String)
    case file(relativePath: String, isDiff: Bool)
    case markdown(relativePath: String)
    /// A tab kind a newer host added; listed, but not openable here.
    case unknown(type: String)
  }

  public var id: String
  public var title: String
  public var kind: Kind
  public var isActive: Bool
  public var isPinned: Bool
  /// For terminal tabs running an agent CLI.
  public var launchAgent: String?
  /// The desktop's terminal palette (xterm theme keys: background, foreground, cursor, black … brightWhite).
  public var terminalColors: [String: String]?

  public init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let type = json["type"]?.stringValue else {
      return nil
    }
    self.id = id
    isActive = json["isActive"]?.boolValue ?? false
    isPinned = json["isPinned"]?.boolValue ?? false
    launchAgent = json["launchAgent"]?.stringValue
    if case .object(let colors)? = json["terminalTheme"]?["theme"] {
      terminalColors = colors.compactMapValues(\.stringValue)
    }
    let fallbackTitle = json["title"]?.stringValue ?? ""
    switch type {
    case "terminal":
      kind = .terminal(handle: json["terminal"]?.stringValue)
      // The user's own name wins, then the host's generated one.
      title = [json["customTitle"]?.stringValue, json["generatedTitle"]?.stringValue, json["quickCommandLabel"]?.stringValue]
        .compactMap { $0 }.first { !$0.isEmpty } ?? fallbackTitle
    case "agent-session":
      guard let sessionId = json["sessionId"]?.stringValue else {
        return nil
      }
      kind = .agentSession(sessionId: sessionId, agent: json["agent"]?.stringValue ?? "")
      title = fallbackTitle
    case "browser":
      kind = .browser(url: json["url"]?.stringValue ?? "")
      title = fallbackTitle
    case "file":
      kind = .file(relativePath: json["relativePath"]?.stringValue ?? "", isDiff: json["mode"]?.stringValue == "diff")
      title = fallbackTitle
    case "markdown":
      kind = .markdown(relativePath: json["relativePath"]?.stringValue ?? "")
      title = fallbackTitle
    default:
      kind = .unknown(type: type)
      title = fallbackTitle
    }
  }

  public var terminalHandle: String? {
    if case .terminal(let handle) = kind {
      return handle
    }
    return nil
  }
}

/// A workspace's tabs, in the order the desktop shows them.
public struct SessionTabs: Sendable, Equatable {
  public var tabs: [SessionTab] = []
  public var activeTabId: String?
  /// The workspace itself is gone.
  public var removed = false

  public init() {}

  /// Reads a `snapshot` or `updated` frame, or a `session.tabs.list` result. Both carry the full list.
  public init(_ json: JSONValue) {
    var byId: [String: SessionTab] = [:]
    var order: [String] = []
    for tab in (json["tabs"]?.arrayValue ?? []).compactMap(SessionTab.init) {
      byId[tab.id] = tab
      order.append(tab.id)
    }
    // Groups carry the visual order; tabs they do not name keep their listed order after them.
    var seen = Set<String>()
    var sorted: [SessionTab] = []
    let grouped = (json["tabGroups"]?.arrayValue ?? []).flatMap { $0["tabOrder"]?.arrayValue ?? [] }.compactMap(\.stringValue)
    for id in grouped + order where !seen.contains(id) {
      if let tab = byId[id] {
        seen.insert(id)
        sorted.append(tab)
      }
    }
    tabs = sorted
    activeTabId = json["activeTabId"]?.stringValue
    removed = json["removed"]?.boolValue ?? false
  }
}

/// The parts of `status.get` this client reads. Every field is optional on the wire.
public struct HostStatus: Sendable, Equatable {
  public var machineName: String?
  public var appVersion: String?
  public var hostPlatform: String?
  public var hostKind: String?
  /// A marketing name such as "MacBook Pro"; nil from desktops that predate it.
  public var hostModel: String?
  public var capabilities: Set<String>
  public var pairedDeviceId: String?

  public init(_ json: JSONValue) {
    machineName = json["machineName"]?.stringValue
    appVersion = json["appVersion"]?.stringValue
    hostPlatform = json["hostPlatform"]?.stringValue
    hostKind = json["hostMachine"]?["kind"]?.stringValue
    hostModel = json["hostMachine"]?["model"]?.stringValue
    pairedDeviceId = json["pairedDeviceId"]?.stringValue
    // One bad entry drops the whole list, as the official client does: a partial list would
    // silently disable features the host does have.
    let entries = json["capabilities"]?.arrayValue ?? []
    let strings = entries.compactMap(\.stringValue)
    capabilities = strings.count == entries.count ? Set(strings) : []
  }

  public func supports(_ capability: String) -> Bool {
    capabilities.contains(capability)
  }
}
