import Foundation
import Testing

@testable import OrcaCore

@Suite struct BrowserTests {
  static func frame(seq: UInt32, format: UInt8 = 1, metadata: String, image: [UInt8], kind: UInt8 = 0x62) -> [UInt8] {
    let meta = Array(metadata.utf8)
    func le(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) } }
    return [kind, 1, 1, format] + le(seq) + le(UInt32(meta.count)) + le(0) + meta + image
  }

  @Test func decodesScreencastFrames() throws {
    let bytes = Self.frame(
      seq: 7, metadata: #"{"deviceWidth":1280,"deviceHeight":800,"pageScaleFactor":1,"zoomFactor":"x"}"#, image: [0xff, 0xd8, 0x01])
    let frame = try #require(BrowserScreencastFrame(bytes))
    #expect(frame.seq == 7)
    #expect(!frame.isPNG)
    #expect(frame.metadata == BrowserFrameMetadata(pageScaleFactor: 1, deviceWidth: 1280, deviceHeight: 800))
    #expect(frame.image == Data([0xff, 0xd8, 0x01]))
    // A terminal frame, a bad format, a truncated header or metadata that isn't an object are someone else's.
    #expect(BrowserScreencastFrame(Self.frame(seq: 1, metadata: "{}", image: [], kind: 0x74)) == nil)
    #expect(BrowserScreencastFrame(Self.frame(seq: 1, format: 3, metadata: "{}", image: [])) == nil)
    #expect(BrowserScreencastFrame(Array(bytes.prefix(10))) == nil)
    #expect(BrowserScreencastFrame(Self.frame(seq: 1, metadata: "[1]", image: [])) == nil)
  }

  @Test func readsBrowserTabsAndStreamEvents() {
    let tab = SessionTab([
      "type": "browser", "id": "web", "title": "Docs", "browserPageId": "p1", "url": "https://x.test", "loading": true,
      "canGoBack": true, "canGoForward": false, "isActive": true,
      "loadError": ["code": -105, "description": "ERR_NAME_NOT_RESOLVED", "validatedUrl": "https://x.test/"],
    ])
    #expect(tab?.kind == .browser(pageId: "p1"))
    #expect(tab?.browser?.url == "https://x.test")
    #expect(tab?.browser?.loading == true)
    #expect(tab?.browser?.canGoBack == true)
    #expect(tab?.browser?.loadError?.code == -105)
    #expect(SessionTab(["type": "browser", "id": "w", "title": "", "url": ""])?.kind == .browser(pageId: nil))

    #expect(
      BrowserScreencastEvent(["type": "ready", "subscriptionId": "s1", "frameAck": true, "tab": ["url": "https://a.test"]])
        == .ready(subscriptionId: "s1", frameAck: true, url: "https://a.test"))
    #expect(
      BrowserScreencastEvent(["type": "dialog", "dialogType": "prompt", "message": "Name?", "origin": "https://a.test"])
        == .dialog(type: "prompt", message: "Name?", defaultPromptText: "", origin: "https://a.test"))
    #expect(BrowserScreencastEvent(["type": "error", "error": ["message": "gone"]]) == .error("gone"))
    #expect(BrowserScreencastEvent(["type": "pointer"]) == .other)
  }

  @Test func asksForFramesThePaneCanShow() {
    let web = BrowserScreencastRequest.params(width: 390, height: 600, pixelRatio: 3, mode: .web)
    #expect(web?["maxWidth"] == 975)
    #expect(web?["maxHeight"] == 1500)
    #expect(web?["viewportWidth"] == nil)
    let mobile = BrowserScreencastRequest.params(width: 100, height: 80, pixelRatio: 1, mode: .mobile)
    #expect(mobile?["maxWidth"] == 320)
    #expect(mobile?["maxHeight"] == 240)
    #expect(mobile?["viewportWidth"] == 100)
    #expect(mobile?["mobile"] == true)
    #expect(BrowserScreencastRequest.params(width: 0, height: 10, pixelRatio: 2, mode: .web) == nil)
    #expect(BrowserViewMode.initial(for: "file:///tmp/index.html") == .mobile)
    #expect(BrowserViewMode.initial(for: "https://x.test/a.html") == .web)
  }

  @Test func mapsTouchesToPagePixels() throws {
    // A 1280×800 page fitted into a 400×500 pane: 400×250, centred vertically.
    let geometry = try #require(
      BrowserFrameGeometry(width: 400, height: 500, metadata: BrowserFrameMetadata(deviceWidth: 1280, deviceHeight: 800)))
    #expect(geometry.renderedHeight == 250)
    #expect(geometry.offsetY == 125)
    let point = try #require(geometry.pagePoint(x: 200, y: 250, zoom: .none))
    #expect(point.x == 640 && point.y == 400)
    #expect(geometry.pagePoint(x: 200, y: 50, zoom: .none) == nil)
    let zoomed = geometry.clamped(.init(scale: 2, offsetX: 1000, offsetY: 1000))
    #expect(zoomed.offsetX == 200 && zoomed.offsetY == 0)
    #expect(geometry.clamped(.init(scale: 0.5, offsetX: 30, offsetY: 30)) == .none)
    let wheel = geometry.wheelDelta(screenDx: 0, screenDy: -10, zoomScale: 1)
    #expect(wheel.dx == 0 && wheel.dy == 32)
    #expect(geometry.clickRadius(zoomScale: 1) == 45)
  }

  @Test func normalizesAddresses() {
    #expect(BrowserURL.normalize("") == "about:blank")
    #expect(BrowserURL.normalize("localhost:3000/a") == "http://localhost:3000/a")
    #expect(BrowserURL.normalize("example.com") == "https://example.com")
    #expect(BrowserURL.normalize("app.test:8443") == "https://app.test:8443")
    #expect(BrowserURL.normalize("https://x.test/p?q=1") == "https://x.test/p?q=1")
    #expect(BrowserURL.normalize("/Users/me/my page.html") == "file:///Users/me/my%20page.html")
    #expect(BrowserURL.normalize("react hooks") == "https://www.google.com/search?q=react%20hooks")
    #expect(BrowserURL.normalize("javascript:alert(1)") == nil)
    #expect(BrowserURL.display("data:text/html,") == "about:blank")
  }
}

@Suite struct SourceControlTests {
  @Test func readsStatusAndLocalBranches() {
    let status = GitStatus([
      "branch": "refs/heads/feature", "conflictOperation": "none",
      "upstreamStatus": ["hasUpstream": false, "ahead": 0, "behind": 0],
      "entries": [
        ["path": "a.swift", "status": "modified", "area": "staged", "added": 3],
        ["path": "b.swift", "status": "weird", "area": "unstaged"],
        ["path": "c.swift", "status": "added", "area": "nowhere"],
      ],
    ])
    #expect(status.branch == "feature")
    #expect(status.conflictOperation == nil)
    #expect(status.upstream?.hasUpstream == false)
    #expect(status.entries.map(\.path) == ["a.swift", "b.swift"])
    #expect(status.entries[1].status == "modified")

    let branches = GitLocalBranches(["current": "main", "branches": ["main", "feature", 3], "committedAt": ["main": 1]])
    #expect(branches.current == "main")
    #expect(branches.branches == ["main", "feature"])
    #expect(GitLocalBranches(["current": nil, "branches": []]).current == nil)
  }
}
