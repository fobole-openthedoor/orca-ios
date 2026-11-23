import Foundation
import Testing

@testable import OrcaCore

@Suite struct HostStatusGateTests {
  @Test func floatingWorkspaceNeedsAnExplicitTrue() {
    #expect(HostStatus(["floatingWorkspaceEnabled": true]).floatingWorkspaceEnabled)
    #expect(!HostStatus(["floatingWorkspaceEnabled": "true"]).floatingWorkspaceEnabled)
    #expect(!HostStatus([:]).floatingWorkspaceEnabled)
  }

  @Test func readsAHostSavedBeforePersonalNames() throws {
    let saved = #"[{"id":"7C5A1E6E-0C2B-4C7E-9F55-3A1E0D3B7E10","name":"Desktop","endpoint":"ws://10.0.0.2:6768","deviceToken":"t","publicKeyB64":"k","pairedAt":0}]"#
    let hosts = try JSONDecoder().decode([PairedHost].self, from: Data(saved.utf8))
    #expect(hosts.first?.personalName == nil)
  }
}

@Suite struct BotSharesTests {
  @Test func readsTheLinksAndDropsAMalformedOne() throws {
    let reply: JSONValue = [
      "status": "ok",
      "value": [
        [
          "id": "s1", "url": "https://app.orca.dev/bots/share/s1", "packageId": "p", "name": "bot-ab12",
          "createdAt": "2026-11-20T10:00:00.000Z", "canonical": true, "pinnedVersionId": "v1",
        ],
        ["id": "broken"],
      ],
    ]
    let shares = try HostAPI.botShares(from: reply)
    #expect(shares.map(\.id) == ["s1"])
    #expect(shares.first?.urlText == "app.orca.dev/bots/share/s1")
    #expect(shares.first?.createdAt != nil)
    #expect(BotOwnedShare.packageName(botId: "AB-12") == "bot-ab12")
  }

  @Test func aSignedOutDesktopThrowsItsSignInCode() {
    #expect(throws: BotShareError.reconnect) { try HostAPI.botShares(from: ["status": "reconnect-required"]) }
    #expect(throws: BotShareError.signIn) { try HostAPI.botShares(from: ["status": "unconfigured"]) }
    let refusal = RPCError(code: "invalid_argument", message: "bot_share_link_moved", data: nil)
    #expect(BotShareError.code(of: refusal) == .moved)
  }
}

@Suite struct HostEndpointTests {
  @Test func showsTheAuthority() {
    #expect(HostEndpoint.display("ws://127.0.0.1:6770") == "127.0.0.1:6770")
    #expect(HostEndpoint.display("ws://[fe80::1]:6768") == "[fe80::1]:6768")
  }

  @Test func resolvesEdits() {
    let stored = "ws://192.168.1.10:6768"
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "192.168.1.10:6768") == .unchanged)
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "ws://192.168.1.10:6768/") == .unchanged)
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "mac.local") == .changed("ws://mac.local:6768"))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "10.0.0.5:7000") == .changed("ws://10.0.0.5:7000"))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "wss://box.ts.net") == .changed("wss://box.ts.net:443"))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "") == .invalid(.addressRequired))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "mac.local:99999") == .invalid(.invalidPort))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "http://mac.local") == .invalid(.invalidScheme))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "ws://mac.local/x") == .invalid(.pathOrQueryNotAllowed))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "0x7f.1") == .invalid(.invalidHostname))
    #expect(HostEndpoint.resolveEdit(stored: stored, input: "bad host") == .invalid(.invalidHostname))
  }

  @Test func recognisesTailnetAddresses() {
    #expect(HostEndpoint.isTailscale("ws://100.101.2.3:6768"))
    #expect(HostEndpoint.isTailscale("wss://mac.tail1234.ts.net:443"))
    #expect(!HostEndpoint.isTailscale("ws://192.168.1.10:6768"))
  }
}

@Suite struct ConnectionDiagnosisTests {
  static func entry(_ id: Int, _ code: ConnectionLogEntry.Code?, path: ConnectionLogEntry.Path? = nil, close: Int? = nil)
    -> ConnectionLogEntry
  {
    ConnectionLogEntry(id: id, level: .warn, message: "m", code: code, path: path, relayCloseCode: close)
  }

  @Test func namesTheNewestFailureSinceTheSessionBegan() {
    let endpoint = "ws://192.168.1.10:6768"
    #expect(
      ConnectionDiagnosis.diagnose(endpoint: endpoint, state: .connected, path: .lan, entries: []).likelyCause
        == "Connection is healthy via LAN/direct.")
    let entries = [Self.entry(1, .authenticationRejected), Self.entry(2, .directConnected), Self.entry(3, .connectTimeout)]
    #expect(
      ConnectionDiagnosis.diagnose(endpoint: endpoint, state: .reconnecting(attempt: 2), path: nil, entries: entries).likelyCause
        == "The saved direct endpoint did not answer before the connection timeout.")
    // Relay evidence outranks a newer direct timeout.
    let relay = [Self.entry(1, .relayDialFailed, path: .relay, close: 4404), Self.entry(2, .connectTimeout)]
    #expect(
      ConnectionDiagnosis.diagnose(endpoint: endpoint, state: .reconnecting(attempt: 1), path: nil, entries: relay).likelyCause
        .contains("host offline"))
  }

  @Test func reportsStateHistoryAndElapsedTimes() {
    let base = Date(timeIntervalSince1970: 0)
    let entry = ConnectionLogEntry(id: 1, date: base.addingTimeInterval(11795), level: .success, message: "Authenticated", detail: "Channel ready for RPC")
    #expect(entry.elapsedText(since: base) == "+11795s")
    #expect(entry.elapsedText(since: base.addingTimeInterval(11790)) == "+5.00s")
    let report = ConnectionReport.build(
      hostName: "mac", endpoint: "ws://127.0.0.1:6770", state: .connected, path: .lan, lastConnectedAt: nil,
      appVersion: "1.0", platform: "iOS", desktopAppVersion: "1.4.268", entries: [entry], now: base)
    #expect(report.contains("Host Orca version: 1.4.268"))
    #expect(report.contains("Endpoint: 127.0.0.1:6770"))
    #expect(report.contains("[success] Authenticated — Channel ready for RPC"))
  }
}
