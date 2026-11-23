import Foundation

/// A paired host's WebSocket address as Edit host shows and takes it (transport/hosts/host-endpoint*.ts):
/// `host:port` on screen, `ws://host:port` stored.
public enum HostEndpoint {
  public enum EditError: Error, Sendable, Equatable {
    case addressRequired, invalidPort, invalidScheme, invalidAddress, pathOrQueryNotAllowed, invalidHostname,
      hostnameRequired
  }

  public enum Edit: Sendable, Equatable {
    case unchanged
    case changed(String)
    case invalid(EditError)
  }

  static let defaultPort = "6768"

  /// `host:port` (the host bracketed when it is IPv6), or the stored text when it doesn't parse.
  public static func display(_ endpoint: String) -> String {
    guard let parts = split(endpoint) else { return endpoint }
    return parts.port.map { "\(bracketed(parts.host)):\($0)" } ?? bracketed(parts.host)
  }

  /// What typing `input` over `stored` would save (resolveHostEndpointEdit): an unchanged authority keeps
  /// the stored text, and a bare `host` keeps the stored scheme and port.
  public static func resolveEdit(stored: String, input: String) -> Edit {
    let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if typed == display(stored) { return .unchanged }
    let storedParts = split(stored)
    let fallbackScheme = storedParts?.scheme == "wss" ? "wss" : "ws"
    let fallbackPort =
      typed.lowercased().hasPrefix("wss://") ? "443" : (storedParts?.port ?? (fallbackScheme == "wss" ? "443" : defaultPort))
    switch normalize(typed, fallbackPort: fallbackPort, fallbackScheme: fallbackScheme) {
    case .failure(let error):
      return .invalid(error)
    case .success(let endpoint):
      if let next = split(endpoint), let storedParts, next.scheme == storedParts.scheme,
        next.host.lowercased() == storedParts.host.lowercased(), next.port == (storedParts.port ?? next.port)
      {
        return .unchanged
      }
      return .changed(endpoint + (storedParts?.suffix ?? ""))
    }
  }

  /// A tailnet address: 100.64.0.0/10 or a `*.ts.net` name (isTailscaleEndpoint).
  public static func isTailscale(_ endpoint: String) -> Bool {
    guard let host = split(endpoint)?.host.lowercased() else { return false }
    if host.hasSuffix(".ts.net") { return true }
    let octets = host.split(separator: ".").compactMap { Int($0) }
    return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
  }

  static func normalize(_ input: String, fallbackPort: String, fallbackScheme: String) -> Result<String, EditError> {
    guard !input.isEmpty else { return .failure(.addressRequired) }
    if let schemeEnd = input.range(of: "://") {
      let scheme = input[..<schemeEnd.lowerBound].lowercased()
      guard scheme == "ws" || scheme == "wss" else { return .failure(.invalidScheme) }
      var authority = String(input[schemeEnd.upperBound...])
      if let cut = authority.firstIndex(where: { "/?#".contains($0) }) {
        guard authority[cut...] == "/" else { return .failure(.pathOrQueryNotAllowed) }
        authority = String(authority[..<cut])
      }
      guard !authority.contains("@") else { return .failure(.invalidAddress) }
      return hostPort(authority, fallbackPort: fallbackPort, scheme: scheme, explicitScheme: true)
    }
    return hostPort(input, fallbackPort: fallbackPort, scheme: fallbackScheme, explicitScheme: false)
  }

  private static func hostPort(_ input: String, fallbackPort: String, scheme: String, explicitScheme: Bool) -> Result<String, EditError> {
    var host: String
    var port: String?
    if input.hasPrefix("[") {
      guard let close = input.firstIndex(of: "]"), input.distance(from: input.startIndex, to: close) > 1 else {
        return .failure(.invalidAddress)
      }
      host = String(input[input.index(after: input.startIndex)..<close])
      let rest = input[input.index(after: close)...]
      if rest.hasPrefix(":") { port = String(rest.dropFirst()) } else if !rest.isEmpty { return .failure(.invalidAddress) }
    } else if input.filter({ $0 == ":" }).count == 1, let colon = input.firstIndex(of: ":") {
      host = String(input[..<colon])
      port = String(input[input.index(after: colon)...])
    } else {
      host = input
    }
    host = host.trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty else { return .failure(.hostnameRequired) }
    if let error = validate(host: host) { return .failure(error) }
    if let typed = port?.trimmingCharacters(in: .whitespaces) {
      guard let number = Int(typed), (1...65535).contains(number), typed.allSatisfy(\.isASCII) else {
        return .failure(.invalidPort)
      }
      port = String(number)
    }
    // An explicit wss:// without a port means 443, as a browser would dial it.
    let finalPort = port ?? (explicitScheme && scheme == "wss" ? "443" : fallbackPort)
    return .success("\(scheme)://\(bracketed(host)):\(finalPort)")
  }

  private static func validate(host: String) -> EditError? {
    if host.contains(where: { $0.isWhitespace || "/?#@[]".contains($0) }) { return .invalidHostname }
    if host.contains(":") {
      let groups = host.split(separator: ":", omittingEmptySubsequences: false)
      let wellFormed =
        host.allSatisfy { $0.isHexDigit || $0 == ":" } && groups.allSatisfy { $0.count <= 4 }
        && (host.contains("::") ? groups.count <= 8 : groups.count == 8)
      return wellFormed ? nil : .invalidHostname
    }
    // A number-only name must be a plain dotted IPv4 address; aliases like 0x7f.1 would dial somewhere else.
    if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.lowercased().hasPrefix("0x") {
      let octets = host.split(separator: ".", omittingEmptySubsequences: false)
      let canonical =
        octets.count == 4
        && octets.allSatisfy { part in Int(part).map { (0...255).contains($0) && String($0) == part } ?? false }
      return canonical ? nil : .invalidHostname
    }
    let label = "[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
    return host.range(of: "^\(label)(?:\\.\(label))*$", options: .regularExpression) == nil ? .invalidHostname : nil
  }

  private static func bracketed(_ host: String) -> String {
    host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
  }

  /// Scheme, bare host, explicit port and whatever followed the authority.
  private static func split(_ endpoint: String) -> (scheme: String, host: String, port: String?, suffix: String)? {
    guard let schemeEnd = endpoint.range(of: "://") else { return nil }
    let scheme = endpoint[..<schemeEnd.lowerBound].lowercased()
    let rest = endpoint[schemeEnd.upperBound...]
    let cut = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
    let authority = rest[..<cut]
    let suffix = String(rest[cut...])
    if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
      let host = String(authority[authority.index(after: authority.startIndex)..<close])
      let after = authority[authority.index(after: close)...]
      return (scheme, host, after.hasPrefix(":") ? String(after.dropFirst()) : nil, suffix)
    }
    let pieces = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard let host = pieces.first, !host.isEmpty else { return nil }
    return (scheme, String(host), pieces.count == 2 ? String(pieces[1]) : nil, suffix)
  }
}
