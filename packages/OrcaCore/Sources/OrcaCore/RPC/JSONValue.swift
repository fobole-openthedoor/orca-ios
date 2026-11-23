import Foundation

/// A JSON value as the host sends it. Replies are read through this before a screen decodes what it needs,
/// so a field a newer host adds never fails the whole reply.
public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self {
      return object[key]
    }
    return nil
  }

  public subscript(index: Int) -> JSONValue? {
    if case .array(let array) = self, array.indices.contains(index) {
      return array[index]
    }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self {
      return value
    }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self {
      return value
    }
    return nil
  }

  public var doubleValue: Double? {
    if case .number(let value) = self {
      return value
    }
    return nil
  }

  public var intValue: Int? {
    if case .number(let value) = self, value == value.rounded(), abs(value) <= 9_007_199_254_740_991 {
      return Int(value)
    }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self {
      return value
    }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self {
      return value
    }
    return nil
  }

  public var isNull: Bool {
    self == .null
  }

  /// Decodes this value into a typed model.
  public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }

  /// Encodes a typed model into a value, for request params.
  public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  public static func parse(_ text: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  public func serialized() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(self)) ?? Data("null".utf8), as: UTF8.self)
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      // Whole numbers go out without a fraction, as the host's schemas expect integers.
      if value == value.rounded(), abs(value) <= 9_007_199_254_740_991 {
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) {
    self = .null
  }

  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }

  public init(integerLiteral value: Int) {
    self = .number(Double(value))
  }

  public init(floatLiteral value: Double) {
    self = .number(value)
  }

  public init(stringLiteral value: String) {
    self = .string(value)
  }

  public init(arrayLiteral elements: JSONValue...) {
    self = .array(elements)
  }

  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

extension NSNumber {
  /// Whether this number came from a JSON `true`/`false`. `value is Bool` cannot tell: it also holds for 0 and 1.
  var isJSONBoolean: Bool {
    CFGetTypeID(self) == CFBooleanGetTypeID()
  }
}
