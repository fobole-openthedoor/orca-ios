import CryptoKit
import Foundation

/// The canonical JSON the host hashes to check a chat write: sorted keys, no whitespace, and
/// JavaScript's `JSON.stringify` spelling of strings and numbers. `JSONEncoder` does not match it
/// (it escapes `/`), so this is written out by hand.
/// Mirrors `structured-agent-session-mutation.ts` in stablyai/orca.
public enum CanonicalJSON {
  public static func string(_ value: JSONValue) -> String {
    var out = ""
    write(value, into: &out)
    return out
  }

  public static func sha256Hex(_ value: JSONValue) -> String {
    SHA256.hash(data: Data(string(value).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func write(_ value: JSONValue, into out: inout String) {
    switch value {
    case .null:
      out += "null"
    case .bool(let bool):
      out += bool ? "true" : "false"
    case .number(let number):
      out += numberString(number)
    case .string(let string):
      writeString(string, into: &out)
    case .array(let array):
      out += "["
      for (index, item) in array.enumerated() {
        if index > 0 {
          out += ","
        }
        write(item, into: &out)
      }
      out += "]"
    case .object(let object):
      out += "{"
      // JavaScript compares keys by UTF-16 code unit.
      let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
      for (index, key) in keys.enumerated() {
        if index > 0 {
          out += ","
        }
        writeString(key, into: &out)
        out += ":"
        write(object[key] ?? .null, into: &out)
      }
      out += "}"
    }
  }

  private static func numberString(_ number: Double) -> String {
    guard number.isFinite else {
      return "null"
    }
    if number == number.rounded(), abs(number) < 1e21 {
      // Covers -0, which JavaScript prints as 0.
      return number == 0 ? "0" : String(format: "%.0f", number)
    }
    return "\(number)"
  }

  private static func writeString(_ string: String, into out: inout String) {
    out += "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"":
        out += "\\\""
      case "\\":
        out += "\\\\"
      case "\u{08}":
        out += "\\b"
      case "\u{0C}":
        out += "\\f"
      case "\n":
        out += "\\n"
      case "\r":
        out += "\\r"
      case "\t":
        out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
  }
}

/// The envelope every chat write carries, and the fingerprint the host recomputes over its fields.
public struct AgentSessionMutation: Sendable, Equatable {
  public let method: String
  public let sessionId: String
  /// The idempotency key. Replaying after a lost reply reuses it verbatim; a new one is a new write.
  public let clientOperationId: String
  public let fields: [String: JSONValue]
  /// The fence last seen for this session; nil only when creating one.
  public let expectedRuntimeFence: Int?

  public init(method: String, sessionId: String, fields: [String: JSONValue], expectedRuntimeFence: Int?, clientOperationId: String = AgentSessionMutation.newOperationId()) {
    self.method = method
    self.sessionId = sessionId
    self.fields = fields
    self.expectedRuntimeFence = expectedRuntimeFence
    self.clientOperationId = clientOperationId
  }

  /// `<13-digit ms>-<32 lowercase hex>`, the format the host requires for launch operation ids too.
  public static func newOperationId(now: Date = Date()) -> String {
    let milliseconds = String(format: "%013lld", Int64(now.timeIntervalSince1970 * 1000))
    return milliseconds + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  /// A few methods are fingerprinted under another name, and create leaves tab placement out.
  var fingerprintMethod: String {
    switch method {
    case "agentSession.respondToApproval":
      return "agentSession.respondTo:approval"
    case "agentSession.respondToQuestion":
      return "agentSession.respondTo:question"
    default:
      return method
    }
  }

  var fingerprintFields: [String: JSONValue] {
    guard method == "agentSession.create" else {
      return fields
    }
    let included = ["worktree", "agent", "resumeFrom", "forkFrom", "tabId", "firstMessage", "optionsMode", "options"]
    return fields.filter { included.contains($0.key) }
  }

  public var payloadFingerprint: String {
    CanonicalJSON.sha256Hex([
      "method": .string(fingerprintMethod),
      "sessionId": .string(sessionId),
      "fields": .object(fingerprintFields),
    ])
  }

  /// The request params: the fields plus the envelope.
  public var params: JSONValue {
    var object = fields
    object["envelope"] = [
      "sessionId": .string(sessionId),
      "clientOperationId": .string(clientOperationId),
      "expectedRuntimeFence": expectedRuntimeFence.map { .number(Double($0)) } ?? .null,
      "payloadFingerprint": .string(payloadFingerprint),
    ]
    return .object(object)
  }
}

/// What a chat write answered. A refusal arrives inside a successful reply.
public enum AgentSessionMutationResult: Sendable, Equatable {
  case accepted(value: JSONValue, fence: Int?, replayed: Bool)
  case refused(code: String, message: String)

  public init(result: JSONValue) {
    if result["ok"]?.boolValue == true {
      self = .accepted(value: result["value"] ?? .null, fence: result["fence"]?.intValue, replayed: result["replayed"]?.boolValue ?? false)
    } else {
      self = .refused(
        code: result["refusal"]?["code"]?.stringValue ?? "unknown",
        message: result["refusal"]?["message"]?.stringValue ?? "")
    }
  }
}
