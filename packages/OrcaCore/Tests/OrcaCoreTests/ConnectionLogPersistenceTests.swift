import Foundation
import Testing

@testable import OrcaCore

@Suite struct ConnectionLogPersistenceTests {
  static func store() -> PersistedConnectionLog {
    PersistedConnectionLog(directory: FileManager.default.temporaryDirectory.appendingPathComponent("connection-log-\(UUID().uuidString)"))
  }

  static func entry(_ n: Int, at seconds: TimeInterval, _ message: String = "m", detail: String? = nil) -> ConnectionLogEntry {
    ConnectionLogEntry(
      id: "e\(n)", date: Date(timeIntervalSince1970: seconds), level: .warn, message: message, detail: detail, code: .livenessTimeout,
      path: .relay, relayCloseCode: 4404)
  }

  @Test func keepsEachHostsHistoryInTheOfficialShape() throws {
    let store = Self.store()
    store.save(hostId: "host/1", entries: [Self.entry(1, at: 1.5, detail: "d")])
    store.save(hostId: "host-2", entries: [Self.entry(2, at: 2)])
    store.flush()
    let loaded = store.load(hostId: "host/1")
    #expect(loaded == [Self.entry(1, at: 1.5, detail: "d")])
    #expect(store.load(hostId: "host-2").map(\.id) == ["e2"])
    #expect(store.load(hostId: "unknown").isEmpty)
    let raw = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL("host/1"))) as? [[String: Any]])
    #expect(raw.first?["ts"] as? Double == 1500)
    #expect(raw.first?["code"] as? String == "liveness-timeout")
    #expect(store.fileURL("host/1").lastPathComponent == "orca.mobile.connection-log.v1.host%2F1.json")
  }

  @Test func keepsTheNewest200AndDropsBadRows() throws {
    let store = Self.store()
    store.save(hostId: "h", entries: (0..<250).map { Self.entry($0, at: Double($0)) })
    store.flush()
    let loaded = store.load(hostId: "h")
    #expect(loaded.count == PersistedConnectionLog.maxEntriesPerHost)
    #expect(loaded.first?.id == "e50")
    #expect(loaded.last?.id == "e249")

    // A row without a level, or a detail that isn't text, is skipped; unknown evidence is left off.
    let rows: [[String: Any]] = [
      ["id": "a", "ts": 1, "level": "info", "message": "ok", "code": "web-shell-page"],
      ["id": "b", "ts": 2, "message": "no level"],
      ["id": "c", "ts": 3, "level": "warn", "message": "x", "detail": 5],
    ]
    try JSONSerialization.data(withJSONObject: rows).write(to: store.fileURL("h"))
    let read = store.load(hostId: "h")
    #expect(read.map(\.id) == ["a"])
    #expect(read.first?.code == nil)
  }

  @Test func mergesKeptHistoryWithThisRunAndRedacts() {
    let stored = [Self.entry(1, at: 1), Self.entry(3, at: 3)]
    let live = [Self.entry(3, at: 3), Self.entry(2, at: 2, "Opening wss://user:pw@relay.test/?token=abc")]
    let merged = PersistedConnectionLog.merge(stored: stored, live: live)
    #expect(merged.map(\.id) == ["e1", "e2", "e3"])
    #expect(merged[1].message == "Opening wss://[redacted]@relay.test/?token=[redacted]")
  }

  @Test func redactsSecretsAsTheOfficialClientDoes() {
    #expect(ConnectionLogRedaction.redact(#"{"deviceToken":"abc123","x":1}"#) == #"{"deviceToken":"[redacted]","x":1}"#)
    #expect(ConnectionLogRedaction.redact("authorization: Bearer xyz") == "authorization: [redacted]")
    #expect(ConnectionLogRedaction.redact("token='q w'") == "token='[redacted]'")
    #expect(ConnectionLogRedaction.redact("Close code 4404") == "Close code 4404")
  }

  @Test func forgetsARemovedHost() {
    let store = Self.store()
    store.save(hostId: "h", entries: [Self.entry(1, at: 1)])
    store.flush()
    store.discard(hostId: "h")
    store.save(hostId: "h", entries: [Self.entry(2, at: 2)])
    store.flush()
    #expect(store.load(hostId: "h").isEmpty)
  }

  @Test func offersSendDiagnosticsOnlyForRelayFailures() {
    let relay = ConnectionDiagnosis.diagnose(
      endpoint: "ws://192.168.1.10:6768", state: .reconnecting(attempt: 1), path: nil, entries: [Self.entry(7, at: 1)])
    #expect(relay.reportableIncidentId == "e7")
    let direct = ConnectionDiagnosis.diagnose(
      endpoint: "ws://192.168.1.10:6768", state: .reconnecting(attempt: 1), path: nil,
      entries: [ConnectionLogEntry(id: "d", level: .warn, message: "m", code: .livenessTimeout, path: .lan)])
    #expect(direct.reportableIncidentId == nil)
    #expect(direct.likelyCause == "The connected host stopped answering authenticated health checks.")
  }

  @Test func boundsTheSubmittedReportByDroppingOldestEvents() {
    let header = "Orca Mobile connection diagnostics\nHost: mac\n"
    let events = (0..<40).map { "event \($0) " + String(repeating: "x", count: 30) }
    let report = header + "Recent connection history (40 events, oldest first):\n" + events.joined(separator: "\n")
    #expect(ConnectionDiagnosticsSubmission.bound(report) == report)
    let bounded = ConnectionDiagnosticsSubmission.bound(report, maxBytes: 400)
    #expect(bounded.utf8.count <= 400)
    #expect(bounded.contains("newest events;"))
    #expect(bounded.hasSuffix(events.last!))
    #expect(!bounded.contains("event 0 "))
    // Not even one event fits: its start, marked.
    let tiny = ConnectionDiagnosticsSubmission.bound(header + "Recent connection history (1 events, oldest first):\n" + String(repeating: "é", count: 200), maxBytes: 160)
    #expect(tiny.utf8.count <= 160)
    #expect(tiny.hasSuffix(" … [truncated]"))
  }
}
