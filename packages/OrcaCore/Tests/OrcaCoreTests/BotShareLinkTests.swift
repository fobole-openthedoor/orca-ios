import Testing

@testable import OrcaCore

@Suite struct BotShareLinkTests {
  @Test func readsTheShareIdFromEachLinkForm() {
    #expect(BotShareReview.shareId(in: "abc_DEF-123") == "abc_DEF-123")
    #expect(BotShareReview.shareId(in: " https://app.orca.dev/bots/share/abc123/ ") == "abc123")
    #expect(BotShareReview.shareId(in: "https://share.onorca.dev/bots/share/xyz") == "xyz")
    #expect(BotShareReview.shareId(in: "orca://bots/share/q1") == "q1")
  }

  @Test func refusesOtherHostsKindsAndSchemes() {
    #expect(BotShareReview.shareId(in: "https://example.com/bots/share/abc") == nil)
    #expect(BotShareReview.shareId(in: "https://app.orca.dev/skills/share/abc") == nil)
    #expect(BotShareReview.shareId(in: "http://app.orca.dev/bots/share/abc") == nil)
    #expect(BotShareReview.shareId(in: "not a link") == nil)
  }
}
