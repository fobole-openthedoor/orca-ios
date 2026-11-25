import CryptoKit
import Foundation

/// Control frames and unpublished tab inventories cannot replace the displayed tabs.
public func hasSessionTabsSnapshot(_ json: JSONValue) -> Bool {
  if json["removed"]?.boolValue == true { return true }
  let epoch = json["publicationEpoch"]?.stringValue
  return json["tabs"]?.arrayValue != nil && epoch != "none" && epoch != "none:client-navigation"
}

/// One tab of a workspace's session, from `session.tabs.subscribe`.
public struct SessionTab: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// `handle` is nil while the host has listed the tab but not yet started its terminal.
    case terminal(handle: String?)
    case agentSession(sessionId: String, agent: String)
    /// `pageId`: the desktop's page, nil until it has registered one. The rest is in `browser`.
    case browser(pageId: String?)
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
  public private(set) var terminalChat: TerminalChatSource?
  public private(set) var prefersTerminalChat = false
  private var terminalAgentReported = false
  fileprivate var terminalPaneKey: String?
  /// The desktop's terminal palette (xterm theme keys: background, foreground, cursor, black … brightWhite).
  public var terminalColors: [String: String]?
  /// For browser tabs: the page's address and navigation state, which change without changing the tab.
  public var browser: BrowserTabState?

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
      if let parent = json["parentTabId"]?.stringValue ?? json["id"]?.stringValue,
        let leaf = json["leafId"]?.stringValue
      {
        terminalPaneKey = "\(parent):\(leaf)"
      }
      terminalChat = TerminalChatSource(tab: json)
      prefersTerminalChat = json["viewMode"]?.stringValue == "chat"
      terminalAgentReported = json["agentStatus"]?.objectValue != nil
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
      let state = BrowserTabState(json)
      kind = .browser(pageId: state.pageId)
      browser = state
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

  fileprivate mutating func retainTerminalChat(from previous: Self) {
    guard !terminalAgentReported, let handle = terminalHandle, handle == previous.terminalHandle else { return }
    terminalChat = previous.terminalChat
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

  /// Some reconnect frames omit status. Keep the known transcript only for the same terminal handle.
  public mutating func retainTerminalChats(from previous: SessionTabs) {
    let previousById = Dictionary(previous.tabs.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
    for index in tabs.indices {
      if let prior = previousById[tabs[index].id] { tabs[index].retainTerminalChat(from: prior) }
    }
  }

  public var activeTab: SessionTab? {
    tabs.first { $0.id == activeTabId } ?? tabs.first(where: \.isActive) ?? tabs.first
  }

  /// Structured chats have a stable session ID. The host projects each split terminal leaf as its own tab.
  public func agentTab(sessionId: String?, paneKey: String?) -> SessionTab? {
    let prefix = "orca_session_id:"
    let key = sessionId.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
    let paneSession = Self.structuredSessionID(forPaneKey: paneKey)
    if let chat = tabs.first(where: {
      if case .agentSession(let id, _) = $0.kind { return id == key || id == paneSession }
      return false
    }) {
      return chat
    }
    guard let paneKey else { return nil }
    if let exact = tabs.first(where: { $0.id == paneKey || $0.terminalPaneKey == paneKey }) { return exact }
    guard let separator = paneKey.lastIndex(of: ":") else { return nil }
    let tabId = paneKey[..<separator]
    return tabs.first { $0.id == tabId && $0.terminalPaneKey == nil }
  }

  /// A slot-based chat can keep the same pane address after its visible tab ID changes.
  public static func structuredSessionID(forPaneKey paneKey: String?) -> String? {
    let prefix = "structured-agent-session-"
    guard let paneKey, paneKey.hasPrefix(prefix), let colon = paneKey.firstIndex(of: ":") else { return nil }
    let sessionID = String(paneKey[..<colon].dropFirst(prefix.count))
    guard !sessionID.isEmpty, sessionID.utf8.count <= 256 else { return nil }
    let hex = SHA256.hash(data: Data(sessionID.utf8)).prefix(16).flatMap { [Int($0 >> 4), Int($0 & 15)] }
    let digits = Array("0123456789abcdef")
    var leaf = hex.map { digits[$0] }
    leaf[12] = "4"
    leaf[16] = "a"
    for index in [20, 16, 12, 8] { leaf.insert("-", at: index) }
    return paneKey[paneKey.index(after: colon)...] == String(leaf) ? sessionID : nil
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
  public var installationId: String?
  /// The desktop has its Floating Workspace turned on (host-status-gates.ts): only an explicit true counts.
  public var floatingWorkspaceEnabled: Bool

  public init(_ json: JSONValue) {
    machineName = json["machineName"]?.stringValue
    appVersion = json["appVersion"]?.stringValue
    hostPlatform = json["hostPlatform"]?.stringValue
    hostKind = json["hostMachine"]?["kind"]?.stringValue
    hostModel = json["hostMachine"]?["model"]?.stringValue
    pairedDeviceId = json["pairedDeviceId"]?.stringValue
    let reportedInstallationId = json["hostDescriptor"]?["installationId"]?.stringValue
    installationId = reportedInstallationId.flatMap { $0.isEmpty ? nil : $0 }
    floatingWorkspaceEnabled = json["floatingWorkspaceEnabled"]?.boolValue == true
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
