import Foundation
import Testing

@testable import OrcaCore

@Suite struct BrowserLoadFailureTests {
  static func failure(_ code: Int, _ description: String, _ url: String) -> BrowserLoadFailure? {
    BrowserLoadFailure(
      loadError: BrowserLoadError(code: code, description: description, validatedUrl: url), certificateFailure: nil, pageId: "p1",
      canProceed: true)
  }

  @Test func namesNetworkFailuresByKind() {
    let refusedLocal = Self.failure(-102, "ERR_CONNECTION_REFUSED", "http://localhost:3000/")
    #expect(refusedLocal?.presentation == .network(.notRunning))
    #expect(refusedLocal?.host == "localhost:3000")
    #expect(refusedLocal?.errorName == "ERR_CONNECTION_REFUSED")
    #expect(Self.failure(-102, "net::ERR_CONNECTION_REFUSED", "https://example.com/")?.presentation == .network(.refused))
    #expect(Self.failure(-102, "x", "http://192.168.1.4:8080")?.presentation == .network(.notRunning))
    #expect(Self.failure(-102, "x", "http://100.80.1.2")?.presentation == .network(.notRunning))
    #expect(Self.failure(-102, "x", "http://app.test")?.presentation == .network(.notRunning))
    #expect(Self.failure(-105, "ERR_NAME_NOT_RESOLVED", "https://nope.example/")?.presentation == .network(.dns))
    #expect(Self.failure(-106, "ERR_INTERNET_DISCONNECTED", "https://a.com")?.presentation == .network(.offline))
    #expect(Self.failure(-118, "x", "https://a.com")?.presentation == .network(.timeout))
    #expect(Self.failure(-101, "x", "https://a.com")?.presentation == .network(.reset))
    #expect(Self.failure(-20, "x", "https://a.com")?.presentation == .network(.blocked))
    #expect(Self.failure(-130, "x", "https://a.com")?.presentation == .network(.other))
    #expect(Self.failure(-130, "Proxy failed", "https://a.com")?.errorName == nil)
    // The default port drops out of the host, as a browser's URL.host reads it.
    #expect(Self.failure(-7, "x", "https://a.com:443/x")?.host == "a.com")
    // Orca's own messages and HTTP errors show on the page itself.
    #expect(Self.failure(0, "Bad address", "https://a.com") == nil)
    #expect(Self.failure(-1, "ERR_FAILED", "https://a.com")?.presentation == .network(.other))
  }

  @Test func offersProceedOnlyForThisPagesUntrustedAuthority() {
    let challenge = BrowserCertificateFailure(
      challengeId: "c1", pageId: "p1", errorCode: -202, error: "net::ERR_CERT_AUTHORITY_INVALID", origin: "https://dev.local:8443",
      canProceed: true)
    let error = BrowserLoadError(code: -202, description: "ERR_CERT_AUTHORITY_INVALID", validatedUrl: "https://dev.local:8443/app")
    let shown = BrowserLoadFailure(loadError: error, certificateFailure: challenge, pageId: "p1", canProceed: true)
    #expect(shown?.presentation == .certificate(.authorityInvalid))
    #expect(shown?.proceedChallenge?.challengeId == "c1")
    #expect(BrowserLoadFailure(loadError: error, certificateFailure: challenge, pageId: "p2", canProceed: true)?.proceedChallenge == nil)
    #expect(BrowserLoadFailure(loadError: error, certificateFailure: challenge, pageId: "p1", canProceed: false)?.proceedChallenge == nil)
    // Chromium's -1 after the challenge was captured shows as the challenge's error.
    let generic = BrowserLoadError(code: -1, description: "ERR_FAILED", validatedUrl: "https://dev.local:8443/")
    let replaced = BrowserLoadFailure(loadError: generic, certificateFailure: challenge, pageId: "p1", canProceed: true)
    #expect(replaced?.presentation == .certificate(.authorityInvalid))
    #expect(replaced?.errorName == "ERR_CERT_AUTHORITY_INVALID")
    let mismatch = BrowserLoadError(code: -200, description: "ERR_CERT_COMMON_NAME_INVALID", validatedUrl: "https://a.com")
    #expect(
      BrowserLoadFailure(loadError: mismatch, certificateFailure: nil, pageId: "p1", canProceed: true)?.presentation
        == .certificate(.nameMismatch))

    let tab = BrowserTabState([
      "browserPageId": "p1", "url": "https://dev.local:8443",
      "certificateFailure": [
        "challengeId": "c1", "browserPageId": "p1", "errorCode": -202, "error": "net::ERR_CERT_AUTHORITY_INVALID",
        "origin": "https://dev.local:8443", "displayHost": "dev.local", "canProceed": true, "observedAt": 1,
      ],
    ])
    #expect(tab.certificateFailure == challenge)
  }

  @Test func readsProfilesAndTheirNames() {
    let profiles = BrowserProfile.list([
      "profiles": [["id": "default", "label": "Default"], ["id": "work", "label": "Work", "x": 1], ["id": 3]]
    ])
    #expect(profiles == [BrowserProfile(id: "default", label: "Default"), BrowserProfile(id: "work", label: "Work")])
    #expect(BrowserProfile.list(.null).isEmpty)
    #expect(BrowserProfile.label("Default", id: "default", defaultLabel: "默认") == "默认")
    #expect(BrowserProfile.label("", id: "abc", defaultLabel: "D") == "abc")
    #expect(BrowserProfile.label("Work", id: "work", defaultLabel: "D") == "Work")
  }
}
