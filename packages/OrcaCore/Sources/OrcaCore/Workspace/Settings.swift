import Foundation

/// A speech model the desktop can transcribe with (`speech.models.list` row).
public struct SpeechModel: Sendable, Equatable, Identifiable {
  public var id: String
  public var label: String
  /// `local` or `openai`.
  public var provider: String?
  /// `ready`, `not-downloaded`, `downloading`, `extracting` or `error`.
  public var status: String?
  public var sizeBytes: Double?
  /// 0…1 while downloading.
  public var progress: Double?
  public var recommended: Bool

  public var isInFlight: Bool { status == "downloading" || status == "extracting" }

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue else { return nil }
    self.id = id
    label = json["label"]?.stringValue ?? id
    provider = json["provider"]?.stringValue
    status = json["status"]?.stringValue
    sizeBytes = json["sizeBytes"]?.doubleValue
    progress = json["progress"]?.doubleValue
    if let flag = json["recommended"]?.boolValue {
      recommended = flag
    } else {
      recommended = json["recommended"].map { !$0.isNull } ?? false
    }
  }
}

/// The desktop's voice dictation settings and models.
public struct DictationSetup: Sendable, Equatable {
  public var enabled: Bool
  public var selectedModelId: String?
  /// `toggle` or `hold`.
  public var dictationMode: String?
  /// Absent from an older desktop, which has no Auto mode.
  public var dictationHoldToRecord: Bool?
  public var models: [SpeechModel]

  /// The shortcut mode the official screen shows: Auto is Toggle plus hold-to-record.
  public var shortcutMode: String {
    if dictationMode == "hold" { return "hold" }
    return dictationHoldToRecord == false ? "toggle" : "auto"
  }

  init(_ json: JSONValue) {
    enabled = json["enabled"]?.boolValue ?? false
    selectedModelId = json["selectedModelId"]?.stringValue
    dictationMode = json["dictationMode"]?.stringValue
    dictationHoldToRecord = json["dictationHoldToRecord"]?.boolValue
    models = (json["models"]?.arrayValue ?? []).compactMap(SpeechModel.init)
  }
}

extension HostAPI {
  // MARK: Terminal

  /// How long after the phone leaves a terminal the desktop restores its size; nil keeps the phone's size.
  public func terminalAutoRestoreFit() async throws -> Double? {
    try await connection.request("terminal.getAutoRestoreFit", [:])["ms"]?.doubleValue
  }

  /// Saves the delay (nil = keep phone size) and returns what the desktop stored; it clamps to 5 s…60 min.
  @discardableResult
  public func setTerminalAutoRestoreFit(ms: Double?) async throws -> Double? {
    let reply = try await connection.request("terminal.setAutoRestoreFit", ["ms": ms.map(JSONValue.number) ?? .null])
    return reply["ms"]?.doubleValue
  }

  // MARK: Voice

  public func dictationSetup() async throws -> DictationSetup {
    DictationSetup(try await connection.request("speech.models.list", nil))
  }

  /// Changes the dictation settings given and returns the desktop's whole setup.
  @discardableResult
  public func configureDictation(
    enabled: Bool? = nil, modelId: String? = nil, dictationMode: String? = nil, holdToRecord: Bool? = nil
  ) async throws -> DictationSetup {
    var params: [String: JSONValue] = [:]
    if let enabled { params["enabled"] = .bool(enabled) }
    if let modelId { params["modelId"] = .string(modelId) }
    if let dictationMode { params["dictationMode"] = .string(dictationMode) }
    if let holdToRecord { params["dictationHoldToRecord"] = .bool(holdToRecord) }
    return DictationSetup(try await connection.request("speech.dictation.setup", .object(params)))
  }

  /// Starts a model download; poll `dictationSetup()` for progress.
  public func downloadSpeechModel(_ modelId: String) async throws {
    _ = try await connection.request("speech.models.download", ["modelId": .string(modelId)])
  }

  @discardableResult
  public func deleteSpeechModel(_ modelId: String) async throws -> DictationSetup {
    DictationSetup(try await connection.request("speech.models.delete", ["modelId": .string(modelId)]))
  }
}
