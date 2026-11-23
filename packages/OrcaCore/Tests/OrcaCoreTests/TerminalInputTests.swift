import Foundation
import Testing

@testable import OrcaCore

@Suite struct TerminalModesTests {
  @Test func followsModeChangesAcrossChunks() {
    var modes = TerminalModes()
    modes.scan(Array("hello\u{1b}[?1049h\u{1b}[?1h\u{1b}[?2004h".utf8))
    #expect(modes.alternateScreen && modes.applicationCursor && modes.bracketedPaste)

    // A sequence split mid-parameter still lands.
    modes.scan(Array("\u{1b}[?10".utf8))
    #expect(modes.alternateScreen)
    modes.scan(Array("49l text \u{1b}[?1000;1006h".utf8))
    #expect(!modes.alternateScreen)
    #expect(modes.mouseTracking && modes.sgrMouse)

    modes.scan(Array("\u{1b}[?1l\u{1b}[?2004l\u{1b}[?1000l".utf8))
    #expect(!modes.applicationCursor && !modes.bracketedPaste && !modes.mouseTracking)
  }

  @Test func ignoresLookalikes() {
    var modes = TerminalModes()
    // Not private, a different final byte, and a `>` sequence with the same numbers.
    modes.scan(Array("\u{1b}[1049h\u{1b}[?1049$p\u{1b}[>1;2004h\u{1b}[?2004m".utf8))
    #expect(!modes.alternateScreen && !modes.bracketedPaste && !modes.applicationCursor && !modes.mouseTracking)

    modes.scan(Array("\u{1b}[?2004h".utf8))
    modes.reset()
    #expect(!modes.bracketedPaste)
  }
}

@Suite struct TerminalInputTests {
  @Test func encodesKeysForTheCursorMode() {
    var modes = TerminalModes()
    #expect(TerminalKey.up.encoded(modes: modes) == "\u{1b}[A")
    #expect(TerminalKey.shiftTab.encoded(modes: modes) == "\u{1b}[Z")
    #expect(TerminalKey.control("c").encoded(modes: modes) == "\u{03}")
    #expect(TerminalKey.control("[").encoded(modes: modes) == "\u{1b}")
    #expect(TerminalKey.backspace.encoded(modes: modes) == "\u{7f}")
    modes.scan(Array("\u{1b}[?1h".utf8))
    #expect(TerminalKey.up.encoded(modes: modes) == "\u{1b}OA")
    #expect(TerminalKey.left.encoded(modes: modes) == "\u{1b}OD")
  }

  @Test func appliesLatchedModifiersToTypedText() {
    #expect(TerminalInput.applying(control: true, alt: false, to: "d") == "\u{04}")
    #expect(TerminalInput.applying(control: true, alt: false, to: "D") == "\u{04}")
    #expect(TerminalInput.applying(control: false, alt: true, to: "b") == "\u{1b}b")
    #expect(TerminalInput.applying(control: true, alt: false, to: "né") == "né")
    #expect(TerminalInput.applying(control: true, alt: false, to: "1") == "1")
  }

  @Test func framesPastes() throws {
    var modes = TerminalModes()
    #expect(TerminalInput.paste("a\r\nb\nc", modes: modes) == ["a\rb\rc"])
    // A pasted ESC must not be able to close the bracket or start a sequence.
    #expect(TerminalInput.paste("x\u{1b}[201~rm -rf", modes: modes) == ["x\u{241b}[201~rm -rf"])

    modes.scan(Array("\u{1b}[?2004h".utf8))
    #expect(TerminalInput.paste("ls\n", modes: modes) == ["\u{1b}[200~ls\r\u{1b}[201~"])

    let long = String(repeating: "漢", count: 30_000)
    let chunks = try #require(TerminalInput.paste(long, modes: modes))
    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { $0.utf8.count <= 64 * 1024 })
    #expect(chunks.joined() == "\u{1b}[200~" + long + "\u{1b}[201~")
    #expect(TerminalInput.paste(String(repeating: "a", count: 16 * 1024 * 1024 + 1), modes: modes) == nil)
  }

  @Test func quotesPathsOnlyWhenNeeded() {
    #expect(TerminalInput.pathReference("/tmp/a.png") == "/tmp/a.png ")
    #expect(TerminalInput.pathReference("/tmp/my shot.png") == "'/tmp/my shot.png' ")
    #expect(TerminalInput.pathReference("/tmp/it's.png") == "'/tmp/it'\\''s.png' ")
  }

  @Test func fitsWholeCellsAndRefusesUselessWidths() throws {
    let grid = try #require(TerminalInput.grid(width: 390, height: 600, cellWidth: 7.8, cellHeight: 16))
    #expect(grid.cols == 50 && grid.rows == 37)
    #expect(TerminalInput.grid(width: 390, height: 40, cellWidth: 7.8, cellHeight: 16)?.rows == 8)
    #expect(TerminalInput.grid(width: 120, height: 600, cellWidth: 7.8, cellHeight: 16) == nil)
    #expect(TerminalInput.grid(width: 390, height: 600, cellWidth: 0, cellHeight: 16) == nil)
  }
}

@Suite struct TerminalQueryReplyTests {
  @Test func recognisesRepliesAndOnlyReplies() {
    for reply in ["\u{1b}[12;40R", "\u{1b}[?1;2c", "\u{1b}[>0;276;0c", "\u{1b}[?2004;1$y", "\u{1b}[?1u", "\u{1b}[8;24;80t",
                  "\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{07}", "\u{1b}]10;rgb:ffff/ffff/ffff\u{1b}\\", "\u{1b}P>|ghostty 1.2\u{1b}\\",
                  "\u{1b}[?997;1n", "\u{1b}[12;40R\u{1b}[?1;2c"] {
      #expect(TerminalQueryReply.isReply(reply), "\(reply.debugDescription)")
    }
    for typed in ["ls", "\u{1b}", "\u{1b}[A", "\u{1b}OA", "\r", "\u{1b}[200~ls\u{1b}[201~", "\u{1b}[12;40Rx", "\u{1b}[13;2u"] {
      #expect(!TerminalQueryReply.isReply(typed), "\(typed.debugDescription)")
    }
  }
}
