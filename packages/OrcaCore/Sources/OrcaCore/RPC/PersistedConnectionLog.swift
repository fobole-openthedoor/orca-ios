import Foundation

/// Each desktop's connection history kept on this phone (diagnostics/connection/persisted-connection-log-store.ts),
/// so a failure from before a relaunch is still there to read: the newest 200 events per host, redacted, one
/// JSON file per host in the official entry shape. Writes coalesce on a background queue; a failed one is tried
/// once more.
public final class PersistedConnectionLog: @unchecked Sendable {
  public static let shared = PersistedConnectionLog(
    directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("connection-log", isDirectory: true))

  /// As the official store: bounded per host, across client swaps and relaunches.
  public static let maxEntriesPerHost = 200
  static let storagePrefix = "orca.mobile.connection-log.v1."
  static let retryDelay: TimeInterval = 0.2

  let directory: URL
  private let queue = DispatchQueue(label: "dev.orca.connection-log", qos: .utility)
  private let lock = NSLock()
  /// The newest snapshot waiting for the queue, per host; only the latest is ever written.
  private var pending: [String: [ConnectionLogEntry]] = [:]
  /// Removed hosts never come back under the same id, so a closing connection's late events are dropped.
  private var discarded: Set<String> = []

  public init(directory: URL) {
    self.directory = directory
  }

  func fileURL(_ hostId: String) -> URL {
    let encoded = hostId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? hostId
    return directory.appendingPathComponent(Self.storagePrefix + encoded + ".json")
  }

  /// What was kept for the host; empty when nothing was, or the file doesn't read.
  public func load(hostId: String) -> [ConnectionLogEntry] {
    guard let data = try? Data(contentsOf: fileURL(hostId)),
      let rows = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else { return [] }
    return rows.compactMap { ($0 as? [String: Any]).flatMap(ConnectionLogEntry.init(stored:)) }
  }

  /// Kept history first, then this run's events: redacted, each once, oldest first, the newest 200.
  public static func merge(stored: [ConnectionLogEntry], live: [ConnectionLogEntry]) -> [ConnectionLogEntry] {
    var seen = Set<String>()
    var merged: [ConnectionLogEntry] = []
    for entry in stored + live {
      let redacted = entry.redacted()
      let fingerprint = [redacted.id, "\(redacted.date.timeIntervalSince1970)", redacted.message, redacted.detail ?? ""].joined(separator: "\u{1f}")
      if seen.insert(fingerprint).inserted { merged.append(redacted) }
    }
    merged.sort { $0.date < $1.date }
    return trimmed(merged)
  }

  /// The newest `maxEntriesPerHost`.
  public static func trimmed(_ entries: [ConnectionLogEntry]) -> [ConnectionLogEntry] {
    entries.count > maxEntriesPerHost ? Array(entries.suffix(maxEntriesPerHost)) : entries
  }

  /// Writes the host's history soon; a burst of events folds into one write.
  public func save(hostId: String, entries: [ConnectionLogEntry]) {
    lock.lock()
    guard !discarded.contains(hostId) else {
      lock.unlock()
      return
    }
    let scheduled = pending[hostId] != nil
    pending[hostId] = Self.trimmed(entries)
    lock.unlock()
    if !scheduled {
      queue.async { self.writePending(hostId, retried: false) }
    }
  }

  /// Forgets a removed host: its file goes, and later events for it are ignored.
  public func discard(hostId: String) {
    lock.lock()
    discarded.insert(hostId)
    pending[hostId] = nil
    lock.unlock()
    let url = fileURL(hostId)
    queue.async { try? FileManager.default.removeItem(at: url) }
  }

  /// Waits for every write asked for so far, as the official flush before the app is suspended.
  public func flush() {
    queue.sync {}
  }

  private func writePending(_ hostId: String, retried: Bool) {
    lock.lock()
    let entries = pending.removeValue(forKey: hostId)
    lock.unlock()
    guard let entries else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: entries.map(\.stored))
      try data.write(to: fileURL(hostId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      // Once per snapshot, and only when no newer one is already on its way.
      lock.lock()
      let retry = !retried && pending[hostId] == nil && !discarded.contains(hostId)
      if retry { pending[hostId] = entries }
      lock.unlock()
      if retry {
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { self.writePending(hostId, retried: true) }
      }
    }
  }
}

extension ConnectionLogEntry {
  /// The official stored shape: `ts` in epoch milliseconds, evidence by its wire names.
  var stored: [String: Any] {
    var row: [String: Any] = [
      "id": id, "ts": (date.timeIntervalSince1970 * 1000).rounded(), "level": level.rawValue, "message": message,
    ]
    if let detail { row["detail"] = detail }
    if let code { row["code"] = code.rawValue }
    if let path { row["path"] = path.rawValue }
    if let relayCloseCode { row["relayCloseCode"] = relayCloseCode }
    return row
  }

  /// A kept row, checked as the official store checks it; evidence this build doesn't know is left off.
  init?(stored row: [String: Any]) {
    guard let id = row["id"] as? String, let ts = (row["ts"] as? NSNumber)?.doubleValue, ts.isFinite,
      let level = (row["level"] as? String).flatMap(Level.init(rawValue:)), let message = row["message"] as? String
    else { return nil }
    if row["detail"] != nil, !(row["detail"] is String) { return nil }
    self.init(
      id: id, date: Date(timeIntervalSince1970: ts / 1000), level: level, message: message, detail: row["detail"] as? String,
      code: (row["code"] as? String).flatMap(Code.init(rawValue:)), path: (row["path"] as? String).flatMap(Path.init(rawValue:)),
      relayCloseCode: (row["relayCloseCode"] as? NSNumber)?.intValue)
  }

  /// The entry with secrets taken out of its message and detail.
  func redacted() -> ConnectionLogEntry {
    ConnectionLogEntry(
      id: id, date: date, level: level, message: ConnectionLogRedaction.redact(message), detail: detail.map(ConnectionLogRedaction.redact),
      code: code, path: path, relayCloseCode: relayCloseCode)
  }
}

/// Takes tokens, credentials and URL user info out of a log line (diagnostics/connection-log-redaction.ts).
public enum ConnectionLogRedaction {
  private static let label = "(resumeToken|deviceToken|authorization|credential|token|publicKeyB64)"
  private static let rules: [(NSRegularExpression, String)] = [
    (#"(["'])"# + label + #"\1(\s*:\s*)(["'])(?:Bearer\s+)?(?:\\.|(?!\4)[^\\\r\n])*\4"#, "$1$2$1$3$4[redacted]$4"),
    (#"\b"# + label + #"(\s*[:=]\s*)(["'])(?:Bearer\s+)?(?:\\.|(?!\3)[^\\\r\n])*\3"#, "$1$2$3[redacted]$3"),
    (#"(["'])"# + label + #"\1(\s*:\s*)(["'])(?:Bearer\s+)?(?:\\.|(?!\4)[^\\\r\n])*(?=\r?\n|$)"#, "$1$2$1$3$4[redacted]"),
    (#"\b"# + label + #"(\s*[:=]\s*)(["'])(?:Bearer\s+)?(?:\\.|(?!\3)[^\\\r\n])*(?=\r?\n|$)"#, "$1$2$3[redacted]"),
    (#"\b"# + label + #"(\s*[:=]\s*)(?:Bearer\s+)?([^\s;,}"']+)"#, "$1$2[redacted]"),
    (#"([?&](?:token|credential|resumeToken|deviceToken)=)[^&#\s]+"#, "$1[redacted]"),
    (#"((?:wss?|https?)://)[^\s/?#]*@"#, "$1[redacted]@"),
  ].map { pattern, template in
    // The patterns are fixed; one that doesn't compile is a bug caught by the tests.
    (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]), template)
  }

  public static func redact(_ text: String) -> String {
    rules.reduce(text) { text, rule in
      rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
    }
  }
}
