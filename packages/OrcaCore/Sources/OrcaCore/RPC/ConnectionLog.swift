import Foundation

/// One step of dialing a host, for Network diagnostics (diagnostics/connection/connection-log-types.ts).
/// Messages are the official client's own English lines, so a report reads the same from either app.
public struct ConnectionLogEntry: Sendable, Equatable, Identifiable {
  public enum Level: String, Sendable { case info, success, warn, error }

  /// The evidence the diagnosis reads, as ConnectionDiagnosticCode.
  public enum Code: String, Sendable {
    case clientSessionStarted = "client-session-started"
    case connectTimeout = "connect-timeout"
    case handshakeTimeout = "handshake-timeout"
    case authenticationRejected = "authentication-rejected"
    case socketClosed = "socket-closed"
    case livenessTimeout = "liveness-timeout"
    case retryScheduled = "retry-scheduled"
    case relayDialFailed = "relay-dial-failed"
    case relayConnected = "relay-connected"
    case directConnected = "direct-connected"
  }

  public enum Path: String, Sendable { case lan, tailscale, relay }

  public let id: Int
  public let date: Date
  public let level: Level
  public let message: String
  public let detail: String?
  public let code: Code?
  public let path: Path?
  /// The relay cell's close code, kept apart so the diagnosis need not parse `detail`.
  public let relayCloseCode: Int?

  public init(
    id: Int, date: Date = Date(), level: Level, message: String, detail: String? = nil, code: Code? = nil,
    path: Path? = nil, relayCloseCode: Int? = nil
  ) {
    self.id = id
    self.date = date
    self.level = level
    self.message = message
    self.detail = detail
    self.code = code
    self.path = path
    self.relayCloseCode = relayCloseCode
  }

  /// Seconds since `base`, as the official log column shows them: finer while short.
  public func elapsedText(since base: Date) -> String {
    let elapsed = max(0, date.timeIntervalSince(base))
    if elapsed < 10 { return String(format: "+%.2fs", elapsed) }
    if elapsed < 100 { return String(format: "+%.1fs", elapsed) }
    return "+\(Int(elapsed.rounded()))s"
  }

  /// The level's glyph in the log column.
  public var glyph: String {
    switch level {
    case .info: "•"
    case .success: "✓"
    case .warn: "!"
    case .error: "✕"
    }
  }
}

/// What the recorded events suggest (connection-diagnostics-analysis.ts), in the official English.
public struct ConnectionDiagnosis: Sendable, Equatable {
  public var likelyCause: String
  public var nextStep: String

  public static func diagnose(
    endpoint: String, state: ConnectionState, path: ConnectionLogEntry.Path?, entries: [ConnectionLogEntry]
  ) -> ConnectionDiagnosis {
    if state == .connected {
      let via = path.map { " via \(Self.name(of: $0))" } ?? ""
      return .init(likelyCause: "Connection is healthy\(via).", nextStep: "No action needed.")
    }
    // The newest failure since the last session began; relay evidence names the desktop's state, so it leads.
    let start = (entries.lastIndex { [.clientSessionStarted, .directConnected, .relayConnected].contains($0.code) } ?? -1) + 1
    let failures = entries[start...].reversed().filter { $0.code.map(Self.failureCodes.contains) ?? false }
    guard let failure = failures.first(where: { $0.path == .relay }) ?? failures.first else {
      return .init(
        likelyCause: "No single failure cause can be determined from the recorded events.",
        nextStep: "Run diagnostics and copy the report again after the next connection attempt.")
    }
    switch failure.code {
    case .livenessTimeout:
      let who = failure.path == .relay ? "Relay" : "The connected host"
      return .init(
        likelyCause: "\(who) stopped answering authenticated health checks.",
        nextStep: "Orca closed the stale session and started recovery.")
    case .authenticationRejected:
      return .init(
        likelyCause: "The desktop rejected this device during authentication.",
        nextStep: "Confirm the device is still paired; pair it again if the rejection repeats.")
    case .connectTimeout:
      return .init(
        likelyCause: HostEndpoint.isTailscale(endpoint)
          ? "The saved Tailscale endpoint did not answer before the connection timeout."
          : "The saved direct endpoint did not answer before the connection timeout.",
        nextStep: "Check the local/VPN network and confirm the desktop is awake.")
    case .handshakeTimeout:
      return .init(
        likelyCause: "The endpoint opened, but the encrypted Orca handshake did not finish.",
        nextStep: "Confirm the desktop is running a compatible Orca version and retry.")
    default:
      // A relay dial: its close code says whether the desktop or this phone is the one missing.
      switch failure.relayCloseCode {
      case 4404?:
        return .init(
          likelyCause: "Relay answered, but the desktop is not connected to it (close code 4404, host offline).",
          nextStep: "Check the desktop is awake, Orca is running, and it is signed in to Orca Cloud.")
      case 4401?:
        return .init(
          likelyCause: "Relay refused this device’s relay credential (close code 4401).",
          nextStep: "Re-pair this phone with the desktop.")
      case 1006?:
        return .init(
          likelyCause: "The phone could not reach the Relay cell (transport close 1006).",
          nextStep: "Check this phone’s network connection; Relay recovery retries automatically.")
      case let code?:
        return .init(
          likelyCause: "Relay closed the dial with code \(code); recovery re-resolves and retries.",
          nextStep: "Keep Orca open while Relay recovery retries.")
      case nil:
        return .init(
          likelyCause: "The Relay dial failed before the cell answered.",
          nextStep: "Check this phone’s network connection; Relay recovery retries automatically.")
      }
    }
  }

  private static let failureCodes: Set<ConnectionLogEntry.Code> = [
    .connectTimeout, .handshakeTimeout, .authenticationRejected, .livenessTimeout, .relayDialFailed,
  ]

  static func name(of path: ConnectionLogEntry.Path) -> String {
    switch path {
    case .relay: "Relay"
    case .tailscale: "Tailscale/direct"
    case .lan: "LAN/direct"
    }
  }
}

/// The shareable report Copy report puts on the clipboard (connection-diagnostics-report.ts).
public enum ConnectionReport {
  public static func build(
    hostName: String, endpoint: String, state: ConnectionState, path: ConnectionLogEntry.Path?,
    lastConnectedAt: Date?, appVersion: String, platform: String, desktopAppVersion: String?,
    entries: [ConnectionLogEntry], now: Date = Date()
  ) -> String {
    let diagnosis = ConnectionDiagnosis.diagnose(endpoint: endpoint, state: state, path: path, entries: entries)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var lines = [
      "Orca Mobile connection diagnostics",
      "Generated: \(iso.string(from: now))",
      "App: Orca Mobile \(appVersion) · \(platform)",
    ]
    let connected = state == .connected
    lines.append("Host Orca version: \(connected ? (desktopAppVersion ?? "unknown") : "unknown (not currently connected)")")
    lines.append("Host: \(hostName)")
    let authority = URL(string: endpoint).flatMap { url in url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } }
    lines.append("Endpoint: \(authority ?? "invalid endpoint")\(HostEndpoint.isTailscale(endpoint) ? " (Tailscale)" : "")")
    lines.append("State: \(state.diagnosticName) (reconnect attempts: \(state.reconnectAttempt))")
    if let path { lines.append("Path: active=\(path.rawValue)") }
    if let lastConnectedAt {
      lines.append("Last connected: \(iso.string(from: lastConnectedAt)) (\(agoText(now.timeIntervalSince(lastConnectedAt))) ago)")
    } else {
      lines.append("Last connected: never this session")
    }
    lines += ["", "Likely cause: \(diagnosis.likelyCause)", "Next step: \(diagnosis.nextStep)", ""]
    if entries.isEmpty {
      lines.append("No connection events recorded.")
    } else {
      lines.append("Recent connection history (\(entries.count) events, oldest first):")
      for entry in entries {
        let evidence = [entry.code?.rawValue, entry.path?.rawValue].compactMap { $0 }.joined(separator: " · ")
        lines.append(
          "\(iso.string(from: entry.date)) [\(entry.level.rawValue)]\(evidence.isEmpty ? "" : " [\(evidence)]") "
            + entry.message + (entry.detail.map { " — \($0)" } ?? ""))
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func agoText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
    return "\(minutes / 60)h \(minutes % 60)m"
  }
}

extension ConnectionState {
  /// The official ConnectionState spelling: `connecting`, `auth-failed` and so on.
  public var diagnosticName: String {
    switch self {
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .handshaking: "handshaking"
    case .connected: "connected"
    case .reconnecting: "reconnecting"
    case .authFailed: "auth-failed"
    }
  }

  public var reconnectAttempt: Int {
    if case .reconnecting(let attempt) = self { return attempt }
    return 0
  }
}
