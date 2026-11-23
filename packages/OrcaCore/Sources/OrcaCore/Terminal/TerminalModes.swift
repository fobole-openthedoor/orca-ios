import Foundation

/// The terminal modes that decide how the phone encodes input, mirrored by scanning the output stream.
/// Kept apart from the emulator so paste framing, key encoding and scroll routing do not depend on its internals.
public struct TerminalModes: Sendable, Equatable {
  /// A full-screen program (vim, less, an agent TUI) owns the screen; there is no scrollback to scroll.
  public private(set) var alternateScreen = false
  /// DECCKM: arrows are sent as SS3 instead of CSI.
  public private(set) var applicationCursor = false
  /// DECSET 2004: pastes are wrapped so the program can tell them from typing.
  public private(set) var bracketedPaste = false
  /// The program asked for mouse reports (1000/1002/1003).
  public private(set) var mouseTracking = false
  /// SGR mouse encoding (1006), the only one safe to send from touch input.
  public private(set) var sgrMouse = false

  private enum State: Sendable, Equatable {
    case ground
    case escape
    case csi
  }

  private var state = State.ground
  private var isPrivate = false
  private var parameters: [Int] = []
  private var current: Int?

  public init() {}

  /// Forgets every mode, before a snapshot is replayed into a fresh emulator.
  public mutating func reset() {
    self = TerminalModes()
  }

  /// Scans output for mode changes. Sequences split across chunks are followed through.
  public mutating func scan(_ bytes: [UInt8]) {
    for byte in bytes {
      switch state {
      case .ground:
        if byte == 0x1b {
          state = .escape
        }
      case .escape:
        if byte == 0x5b {
          state = .csi
          isPrivate = false
          parameters = []
          current = nil
        } else if byte != 0x1b {
          state = .ground
        }
      case .csi:
        switch byte {
        case 0x3f where parameters.isEmpty && current == nil:
          isPrivate = true
        case 0x30...0x39:
          // Saturating: a hostile parameter must not overflow.
          current = min((current ?? 0) * 10 + Int(byte - 0x30), 100_000)
        case 0x3b:
          parameters.append(current ?? 0)
          current = nil
        case 0x40...0x7e:
          if let current {
            parameters.append(current)
          }
          if isPrivate, byte == 0x68 || byte == 0x6c {
            for parameter in parameters {
              apply(parameter, enabled: byte == 0x68)
            }
          }
          state = .ground
        case 0x1b:
          state = .escape
        default:
          // Intermediates and other markers (`>`, `=`, space): not a mode change this mirror tracks.
          if byte < 0x20 || byte == 0x3c || byte == 0x3d || byte == 0x3e {
            isPrivate = false
            parameters = [-1]
          }
        }
      }
    }
  }

  private mutating func apply(_ mode: Int, enabled: Bool) {
    switch mode {
    case 1:
      applicationCursor = enabled
    case 47, 1047, 1049:
      alternateScreen = enabled
    case 9, 1000, 1002, 1003:
      mouseTracking = enabled
    case 1006:
      sgrMouse = enabled
    case 2004:
      bracketedPaste = enabled
    default:
      break
    }
  }
}

/// A key of the terminal's accessory bar.
public enum TerminalKey: Sendable, Equatable {
  case escape
  case tab
  case shiftTab
  case enter
  case backspace
  case forwardDelete
  case up
  case down
  case left
  case right
  case home
  case end
  case pageUp
  case pageDown
  /// Ctrl held with a letter or one of `@ [ \ ] ^ _ ?`.
  case control(Character)

  /// The bytes the PTY expects, which for arrows depends on the program's cursor-key mode.
  public func encoded(modes: TerminalModes) -> String {
    let arrowPrefix = modes.applicationCursor ? "\u{1b}O" : "\u{1b}["
    switch self {
    case .escape: return "\u{1b}"
    case .tab: return "\t"
    case .shiftTab: return "\u{1b}[Z"
    case .enter: return "\r"
    case .backspace: return "\u{7f}"
    case .forwardDelete: return "\u{1b}[3~"
    case .up: return arrowPrefix + "A"
    case .down: return arrowPrefix + "B"
    case .right: return arrowPrefix + "C"
    case .left: return arrowPrefix + "D"
    case .home: return arrowPrefix + "H"
    case .end: return arrowPrefix + "F"
    case .pageUp: return "\u{1b}[5~"
    case .pageDown: return "\u{1b}[6~"
    case .control(let character): return TerminalInput.control(character) ?? ""
    }
  }
}

public enum TerminalInput {
  /// 64 KiB of UTF-8 per send.
  static let pasteChunkBytes = 64 * 1024
  public static let pasteMaxBytes = 16 * 1024 * 1024

  /// The control byte for Ctrl plus a character, when there is one.
  public static func control(_ character: Character) -> String? {
    guard let ascii = character.asciiValue else {
      return nil
    }
    switch ascii {
    case 0x40...0x5f:
      return String(UnicodeScalar(ascii & 0x1f))
    case 0x61...0x7a:
      return String(UnicodeScalar(ascii & 0x1f))
    case 0x20:
      return "\u{00}"
    case 0x3f:
      return "\u{7f}"
    default:
      return nil
    }
  }

  /// Text typed on the software keyboard while a modifier is latched on the accessory bar.
  public static func applying(control: Bool, alt: Bool, to text: String) -> String {
    var out = text
    if control, text.count == 1, let byte = Self.control(text.first!) {
      out = byte
    }
    return alt ? "\u{1b}" + out : out
  }

  /// A paste as the sends that carry it: line endings as the Enter key sends them, any ESC made
  /// harmless so pasted text cannot end the bracket or run a sequence, and the bracket when the
  /// program asked for one. Nil when the paste is over the cap.
  public static func paste(_ text: String, modes: TerminalModes) -> [String]? {
    guard text.utf8.count <= pasteMaxBytes else {
      return nil
    }
    var body = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
    body = body.replacingOccurrences(of: "\u{1b}", with: "\u{241b}")
    if modes.bracketedPaste {
      body = "\u{1b}[200~" + body + "\u{1b}[201~"
    }
    var chunks: [String] = []
    var current = ""
    var bytes = 0
    for character in body {
      let size = character.utf8.count
      if bytes + size > pasteChunkBytes, !current.isEmpty {
        chunks.append(current)
        current = ""
        bytes = 0
      }
      current.append(character)
      bytes += size
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }

  /// A host path typed into an agent's prompt, as a paste followed by a space so the next word is separate.
  public static func pathReference(_ path: String) -> String {
    let needsQuotes = path.contains { $0.isWhitespace || "\"'\\$`!*?[]{}()<>|&;#~".contains($0) }
    return (needsQuotes ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path) + " "
  }

  /// The grid a view of this size holds: whole cells only, never fewer than 8 rows, and no fit at all
  /// below 20 columns, where a shell is unusable and resizing the desktop's PTY would only harm it.
  public static func grid(width: Double, height: Double, cellWidth: Double, cellHeight: Double) -> (cols: Int, rows: Int)? {
    guard cellWidth > 0, cellHeight > 0 else {
      return nil
    }
    let cols = Int((width / cellWidth + 1e-6).rounded(.down))
    let rows = max(8, Int((height / cellHeight + 1e-6).rounded(.down)))
    return cols >= 20 ? (min(cols, 1000), min(rows, 500)) : nil
  }
}

/// Tells the emulator's own answers to a program's queries (cursor position, device attributes, colour
/// reports) from what the user typed. Both leave the emulator through one channel, unmarked.
/// Mirrors `terminal-query-reply.ts` in stablyai/orca.
public enum TerminalQueryReply {
  private static let grammars: [NSRegularExpression] = [
    // CPR and DSR. Modified F3 is byte-identical to CPR; that ambiguity is accepted upstream too.
    #"^\x1b\[\??[0-9;]*[Rn]"#,
    // Device attributes.
    #"^\x1b\[[?>=]?[0-9;]*c"#,
    // Window and text-area size reports.
    #"^\x1b\[[468];[0-9]+;[0-9]+t"#,
    // DECRPM.
    #"^\x1b\[\??[0-9;]*\$y"#,
    // Kitty keyboard flags.
    #"^\x1b\[\?[0-9]+u"#,
    // Kitty graphics acknowledgements.
    #"^\x1b_Gi=[0-9]+(?:,p=[0-9]+)?;(?:OK|E[A-Z]+:[^\x00-\x1f]*)\x1b\\"#,
    // OSC colour and title reports, ended by BEL or ST.
    #"^\x1b\][0-9]+;[^\x07\x1b]*(?:\x07|\x1b\\)"#,
    // DECRQSS and XTVERSION.
    #"^\x1bP(?:[01]\$r[^\x1b]*|>\|[^\x1b]*)\x1b\\"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  /// Whether `text` is made only of complete replies, one or several.
  public static func isReply(_ text: String) -> Bool {
    let utf16 = text as NSString
    guard utf16.length >= 3, text.first == "\u{1b}" else {
      return false
    }
    var offset = 0
    while offset < utf16.length {
      let range = NSRange(location: offset, length: utf16.length - offset)
      guard
        let match = grammars.lazy.compactMap({ $0.firstMatch(in: text, options: [.anchored], range: range) }).first,
        match.range.length > 0
      else {
        return false
      }
      offset += match.range.length
    }
    return true
  }
}
