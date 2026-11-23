import Foundation

/// Send diagnostics (diagnostics/connection-diagnostics-submission.ts): after the person's tap, the already-redacted
/// report goes to Orca's feedback endpoint, cut to 64 KiB by dropping the oldest events first.
public enum ConnectionDiagnosticsSubmission {
  static let endpoint = URL(string: "https://orca.dev/v1/feedback")!
  static let timeout: TimeInterval = 10
  public static let maxBytes = 64 * 1024

  /// Nil once it was sent; otherwise what went wrong, in the official words.
  public static func submit(report: String, appVersion: String, platform: String, session: URLSession = .shared) async -> String? {
    var request = URLRequest(url: endpoint, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "feedback": bound(report), "submissionType": "connection_diagnostics", "githubLogin": NSNull(), "githubEmail": NSNull(),
      "appVersion": appVersion, "platform": "mobile-\(platform)", "osRelease": "unknown", "arch": "unknown",
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    do {
      let (_, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return (200..<300).contains(status) ? nil : "status \(status)"
    } catch let error as URLError where error.code == .timedOut {
      return "request timed out"
    } catch {
      return error.localizedDescription
    }
  }

  /// The report within `maxBytes`: the header whole, then as many of the newest events as fit.
  public static func bound(_ report: String, maxBytes: Int = maxBytes) -> String {
    guard report.utf8.count > maxBytes else { return report }
    let lines = report.components(separatedBy: "\n")
    guard let historyIndex = lines.firstIndex(where: { $0.hasPrefix("Recent connection history (") }) else {
      return clamp(report, maxBytes)
    }
    let header = Array(lines[..<historyIndex])
    let events = Array(lines[(historyIndex + 1)...])
    func format(_ kept: [String]) -> String {
      (header + ["Recent connection history (\(kept.count) newest events; \(events.count - kept.count) older omitted):"] + kept)
        .joined(separator: "\n")
    }
    var kept: [String] = []
    for event in events.reversed() {
      let candidate = [event] + kept
      if format(candidate).utf8.count > maxBytes { break }
      kept = candidate
    }
    if kept.isEmpty, let newest = events.last {
      // Not even the newest event fits whole: its start, marked as cut.
      let prefix = (header + ["Recent connection history (1 newest event; \(events.count - 1) older omitted):"]).joined(separator: "\n") + "\n"
      let marker = " … [truncated]"
      let available = maxBytes - prefix.utf8.count - marker.utf8.count
      guard available > 0 else { return clamp(prefix, maxBytes) }
      return prefix + clamp(newest, available) + marker
    }
    return clamp(format(kept), maxBytes)
  }

  /// The longest prefix within `maxBytes` of UTF-8 that doesn't split a character.
  static func clamp(_ text: String, _ maxBytes: Int) -> String {
    guard text.utf8.count > maxBytes else { return text }
    var result = ""
    var bytes = 0
    for character in text {
      let size = String(character).utf8.count
      if bytes + size > maxBytes { break }
      result.append(character)
      bytes += size
    }
    return result
  }
}
