import Foundation

/// The host's hold on a page whose certificate it would not trust (`BrowserCertificateFailure`): Proceed names
/// the challenge, and only the one this failure shows may be proceeded past.
public struct BrowserCertificateFailure: Sendable, Equatable {
  public var challengeId: String
  public var pageId: String
  public var errorCode: Int?
  public var error: String
  public var origin: String
  public var canProceed: Bool

  public init(challengeId: String, pageId: String, errorCode: Int?, error: String, origin: String, canProceed: Bool) {
    self.challengeId = challengeId
    self.pageId = pageId
    self.errorCode = errorCode
    self.error = error
    self.origin = origin
    self.canProceed = canProceed
  }

  init?(_ json: JSONValue) {
    guard let challengeId = json["challengeId"]?.stringValue, let pageId = json["browserPageId"]?.stringValue else { return nil }
    self.challengeId = challengeId
    self.pageId = pageId
    errorCode = json["errorCode"]?.intValue
    error = json["error"]?.stringValue ?? ""
    origin = json["origin"]?.stringValue ?? ""
    canProceed = json["canProceed"]?.boolValue ?? false
  }
}

/// What the failure page says, by the shared rule (shared/browser/navigation/browser-load-failure.ts and
/// certificate-trust/browser-certificate-failure-match.ts); the words come from the app's catalog.
public struct BrowserLoadFailure: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case notRunning, refused, dns, offline, timeout, reset, blocked, other
  }

  /// Which sentence explains a certificate it would not trust.
  public enum CertificateReason: Sendable, Equatable {
    case nameMismatch, dateInvalid, authorityInvalid, unverified
  }

  public enum Presentation: Sendable, Equatable {
    case certificate(CertificateReason)
    case network(Kind)
  }

  public var presentation: Presentation
  /// `hostname:port` as the page asked for it; nil when the URL has none.
  public var host: String?
  /// Chromium's name for the error (ERR_CONNECTION_REFUSED), for the small developer line.
  public var errorName: String?
  /// Orca's own message (code 0) stands in for the description.
  public var ownMessage: String?
  /// The challenge Proceed answers; nil when this failure can't be proceeded past from here.
  public var proceedChallenge: BrowserCertificateFailure?

  /// Nil for a failure the page shows itself (an HTTP error, Orca's own pages): the streamed frame says it.
  public init?(loadError: BrowserLoadError, certificateFailure: BrowserCertificateFailure?, pageId: String?, canProceed: Bool) {
    let match = Self.match(loadError: loadError, certificateFailure: certificateFailure, pageId: pageId, canProceed: canProceed)
    // Chromium can report -1 after the host captured the exact challenge; the challenge's code is the one to show.
    var shown = loadError
    if let match, loadError.code == -1 {
      shown.code = match.errorCode ?? loadError.code
      shown.description = match.error
    }
    let parsed = Self.readHost(shown.validatedUrl)
    host = parsed.host
    errorName = shown.description.range(of: #"^(?:net::)?(ERR_[A-Z_]+)$"#, options: .regularExpression).map { _ in
      shown.description.hasPrefix("net::") ? String(shown.description.dropFirst(5)) : shown.description
    }
    proceedChallenge = match
    ownMessage = nil
    if Self.certificateCodes.contains(shown.code) {
      presentation = .certificate(
        shown.code == -200 ? .nameMismatch : shown.code == -201 ? .dateInvalid : shown.code == -202 ? .authorityInvalid : .unverified)
    } else if shown.code < 0, shown.code > -1000 {
      presentation = .network(Self.kind(code: shown.code, isDevHost: parsed.isDevHost))
    } else {
      return nil
    }
  }

  // Exact Chromium certificate codes, so unrelated failures never get certificate advice.
  static let certificateCodes: Set<Int> = [-200, -201, -202, -203, -204, -205, -206, -207, -208, -210, -211, -212, -213, -214, -217, -219]

  static func kind(code: Int, isDevHost: Bool) -> Kind {
    switch code {
    case -102: isDevHost ? .notRunning : .refused
    case -106: .offline
    case -20: .blocked
    case -105, -137: .dns
    case -7, -118: .timeout
    case -100, -101, -103, -324: .reset
    // A phone can't see the SSH route, so SOCKS failures read as "can't reach".
    default: .other
    }
  }

  /// The challenge when it is the one this failure shows and can be proceeded past: only an untrusted authority
  /// (-202), on this page, for the failed URL's origin.
  static func match(
    loadError: BrowserLoadError, certificateFailure: BrowserCertificateFailure?, pageId: String?, canProceed: Bool
  ) -> BrowserCertificateFailure? {
    guard canProceed, let failure = certificateFailure, failure.canProceed, let pageId, failure.pageId == pageId,
      failure.errorCode == -202
    else { return nil }
    func normalized(_ error: String) -> String {
      var text = error.trimmingCharacters(in: .whitespaces)
      if text.lowercased().hasPrefix("net::") { text.removeFirst(5) }
      return text.uppercased()
    }
    let sameError = loadError.code == -1 || (loadError.code == failure.errorCode && normalized(failure.error) == normalized(loadError.description))
    guard sameError, let components = URLComponents(string: loadError.validatedUrl), let scheme = components.scheme,
      let host = authority(components)
    else { return nil }
    return "\(scheme.lowercased())://\(host)" == failure.origin ? failure : nil
  }

  /// `host:port` as a browser's URL.host reads it: lowercased, IPv6 in brackets, a scheme's default port left out.
  static func authority(_ components: URLComponents) -> String? {
    guard let raw = components.host, !raw.isEmpty else { return nil }
    let name = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let defaults: [String: Int] = ["http": 80, "https": 443, "ws": 80, "wss": 443]
    let port = components.port.flatMap { $0 == defaults[components.scheme?.lowercased() ?? ""] ? nil : ":\($0)" } ?? ""
    return (name.contains(":") ? "[\(name)]" : name) + port
  }

  /// The URL's `host:port`, and whether it's a host a developer runs: this machine, the LAN, the tailnet, a dev name.
  static func readHost(_ url: String) -> (host: String?, isDevHost: Bool) {
    guard let components = URLComponents(string: url), let display = authority(components), let hostname = components.host else {
      return (nil, false)
    }
    let name = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if name == "0.0.0.0" || name == "::" { return (display, true) }
    if name.range(of: #"\.(local|test|internal|lan)$"#, options: .regularExpression) != nil { return (display, true) }
    return (display, !isPublic(name))
  }

  private static func isPublic(_ name: String) -> Bool {
    let loopback: Set<String> = [
      "localhost", "localhost.localdomain", "localhost6", "localhost6.localdomain6", "ip6-localhost", "ip6-loopback", "127.0.0.1", "::1",
    ]
    if loopback.contains(name) || name.hasSuffix(".localhost") || name.hasPrefix("127.") { return false }
    let octets = name.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
    if octets.count == 4, name.split(separator: ".").count == 4 {
      if octets[0] == 100, (64...127).contains(octets[1]) { return false }
      if octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168) { return false }
    }
    if let first = name.split(separator: ":").first, let hextet = Int(first, radix: 16), name.contains(":") {
      if hextet & 0xfe00 == 0xfc00 || hextet & 0xffc0 == 0xfe80 { return false }
    }
    return name.contains(".") || name.contains(":")
  }
}

/// Why Proceed didn't go through: the host's reason, a lost request, or a host too old to take it from a phone.
public enum BrowserCertificateProceedFailure: Sendable, Equatable {
  case expired, changed, unavailable, requestFailed, hostUpdateNeeded

  init(reason: String?) {
    switch reason {
    case "expired": self = .expired
    case "changed", "navigated": self = .changed
    default: self = .unavailable
    }
  }
}

/// A browser profile the host keeps (`browser.profileList`): its own cookies and sign-ins.
public struct BrowserProfile: Sendable, Equatable {
  public var id: String
  public var label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }

  /// The name a row shows (browser-session-profile-label.ts): the default profile reads as `defaultLabel`.
  public static func label(_ label: String?, id: String?, defaultLabel: String) -> String {
    let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
    if trimmed.isEmpty, let id, id != "default" { return id }
    if id == "default" || trimmed.isEmpty || (id == nil && label == "Default") { return defaultLabel }
    return label ?? defaultLabel
  }

  /// The rows a reply lists; a row without an id or a label is skipped, not the reply.
  public static func list(_ reply: JSONValue) -> [BrowserProfile] {
    (reply["profiles"]?.arrayValue ?? []).compactMap { row in
      guard let id = row["id"]?.stringValue, let label = row["label"]?.stringValue else { return nil }
      return BrowserProfile(id: id, label: label)
    }
  }
}

public enum BrowserCertificateTrustCapability {
  /// The host takes `browser.certificate.proceed` from a phone.
  public static let certificateTrust = "browser.certificate-trust.v1"
}

extension HostAPI {
  /// The host's browser profiles; empty on an older host, which refuses the call from a phone.
  public func browserProfiles() async -> [BrowserProfile] {
    guard let reply = try? await connection.request("browser.profileList", nil, timeout: .seconds(10)) else { return [] }
    return BrowserProfile.list(reply)
  }

  /// Accepts the host's certificate challenge for this page, the same path desktop's Proceed takes; nil once it did.
  public func browserCertificateProceed(worktreeId: String, pageId: String, challengeId: String) async -> BrowserCertificateProceedFailure? {
    do {
      let reply = try await connection.request(
        "browser.certificate.proceed",
        ["worktree": .string("id:\(worktreeId)"), "page": .string(pageId), "challengeId": .string(challengeId)],
        timeout: .seconds(15))
      return reply["ok"]?.boolValue == true ? nil : BrowserCertificateProceedFailure(reason: reply["reason"]?.stringValue)
    } catch let error as RPCError {
      if error.code == "forbidden" || error.code == "method_not_found" || error.message.contains("not available to mobile clients") {
        return .hostUpdateNeeded
      }
      return .requestFailed
    } catch {
      return .requestFailed
    }
  }
}
