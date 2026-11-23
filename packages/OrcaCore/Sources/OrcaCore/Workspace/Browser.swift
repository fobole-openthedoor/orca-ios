import Foundation

/// What a browser tab of the session says about its page (`RuntimeMobileSessionBrowserTab`).
public struct BrowserTabState: Sendable, Equatable {
  /// The page the desktop runs for this tab; nil until the desktop has registered it.
  public var pageId: String?
  public var url: String
  public var loading: Bool
  public var canGoBack: Bool
  public var canGoForward: Bool
  public var loadError: BrowserLoadError?
  /// The host's certificate challenge for this page, while a certificate stops it.
  public var certificateFailure: BrowserCertificateFailure?
  public var profileId: String?

  public init(_ json: JSONValue) {
    pageId = json["browserPageId"]?.stringValue
    url = json["url"]?.stringValue ?? ""
    loading = json["loading"]?.boolValue ?? false
    canGoBack = json["canGoBack"]?.boolValue ?? false
    canGoForward = json["canGoForward"]?.boolValue ?? false
    loadError = json["loadError"].flatMap(BrowserLoadError.init)
    certificateFailure = json["certificateFailure"].flatMap(BrowserCertificateFailure.init)
    profileId = json["browserProfileId"]?.stringValue
  }
}

/// A page that failed to load: Chromium's net error code (0 for Orca's own message), its text, and the URL.
public struct BrowserLoadError: Sendable, Equatable {
  public var code: Int
  public var description: String
  public var validatedUrl: String

  public init(code: Int, description: String, validatedUrl: String) {
    self.code = code
    self.description = description
    self.validatedUrl = validatedUrl
  }

  init?(_ json: JSONValue) {
    guard let description = json["description"]?.stringValue else { return nil }
    code = json["code"]?.intValue ?? 0
    self.description = description
    validatedUrl = json["validatedUrl"]?.stringValue ?? ""
  }
}

/// A frame's layout facts, as CDP's screencast reports them. Every field is optional on the wire.
public struct BrowserFrameMetadata: Sendable, Equatable {
  public var pageScaleFactor: Double?
  public var deviceWidth: Double?
  public var deviceHeight: Double?
  /// The page's zoom; older hosts omit it.
  public var zoomFactor: Double?

  public init(pageScaleFactor: Double? = nil, deviceWidth: Double? = nil, deviceHeight: Double? = nil, zoomFactor: Double? = nil) {
    self.pageScaleFactor = pageScaleFactor
    self.deviceWidth = deviceWidth
    self.deviceHeight = deviceHeight
    self.zoomFactor = zoomFactor
  }

  init(_ json: JSONValue) {
    func positive(_ key: String) -> Double? { json[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } }
    pageScaleFactor = positive("pageScaleFactor")
    deviceWidth = positive("deviceWidth")
    deviceHeight = positive("deviceHeight")
    zoomFactor = positive("zoomFactor")
  }
}

/// A screencast's binary frame: a 16-byte little-endian header (kind 0x62, version, opcode, format, seq,
/// metadata length, reserved), the metadata as JSON, then the JPEG or PNG.
/// Mirrors `browser/screencast/browser-screencast-protocol.ts` of the official app.
public struct BrowserScreencastFrame: Sendable, Equatable {
  public static let kind: UInt8 = 0x62
  static let headerLength = 16

  public let seq: UInt32
  public let isPNG: Bool
  public let metadata: BrowserFrameMetadata
  public let image: Data

  /// Nil for any other binary frame, or a malformed one.
  public init?(_ bytes: [UInt8]) {
    guard bytes.count >= Self.headerLength, bytes[0] == Self.kind, bytes[1] == 1, bytes[2] == 1,
      bytes[3] == 1 || bytes[3] == 2
    else { return nil }
    func u32(_ offset: Int) -> UInt32 {
      UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    let metadataLength = Int(u32(8))
    let imageStart = Self.headerLength + metadataLength
    guard u32(12) == 0, imageStart <= bytes.count,
      let json = JSONValue.parse(String(decoding: bytes[Self.headerLength..<imageStart], as: UTF8.self)),
      json.objectValue != nil
    else { return nil }
    seq = u32(4)
    isPNG = bytes[3] == 2
    metadata = BrowserFrameMetadata(json)
    image = Data(bytes[imageStart...])
  }
}

/// A JSON event of `browser.screencast` (mobile-browser-stream-events.ts).
public enum BrowserScreencastEvent: Sendable, Equatable {
  /// The stream is up. `frameAck`: the host counts frames against acks.
  case ready(subscriptionId: String?, frameAck: Bool, url: String?)
  case dialog(type: String, message: String, defaultPromptText: String, origin: String?)
  case dialogClosed
  case error(String)
  case end
  case other

  public init(_ json: JSONValue) {
    switch json["type"]?.stringValue {
    case "ready":
      self = .ready(
        subscriptionId: json["subscriptionId"]?.stringValue, frameAck: json["frameAck"]?.boolValue == true,
        url: json["tab"]?["url"]?.stringValue)
    case "dialog":
      self = .dialog(
        type: json["dialogType"]?.stringValue ?? "alert", message: json["message"]?.stringValue ?? "Browser dialog",
        defaultPromptText: json["defaultPromptText"]?.stringValue ?? "", origin: json["origin"]?.stringValue)
    case "dialogClosed": self = .dialogClosed
    case "error":
      self = .error(json["message"]?.stringValue ?? json["error"]?["message"]?.stringValue ?? "Browser stream failed.")
    case "end": self = .end
    default: self = .other
    }
  }
}

/// How the phone asks for a page: as the desktop shows it, or reflowed for a phone-sized viewport.
public enum BrowserViewMode: String, Sendable {
  case web, mobile

  /// A local HTML file opens in mobile view; everything else as the desktop shows it.
  public static func initial(for url: String) -> BrowserViewMode {
    guard let parsed = URL(string: url), parsed.scheme == "file" else { return .web }
    let path = parsed.path.lowercased()
    return path.hasSuffix(".html") || path.hasSuffix(".htm") ? .mobile : .web
  }
}

/// The frame size and pacing a phone asks for (browser-screencast-request-parameters.ts).
public enum BrowserScreencastRequest {
  public static func params(width: Double, height: Double, pixelRatio: Double, mode: BrowserViewMode) -> [String: JSONValue]? {
    guard width > 0, height > 0 else { return nil }
    // Density without desktop viewport params, which would switch Chromium into phone emulation.
    let scale = min(max(pixelRatio.isFinite ? pixelRatio : 1, 1), 2.5)
    var params: [String: JSONValue] = [
      "format": "jpeg",
      "quality": 72,
      "maxWidth": .number(clamp((width * scale).rounded(), 320, 2400)),
      "maxHeight": .number(clamp((height * scale).rounded(), 240, 2160)),
      "everyNthFrame": 1,
      "minFrameIntervalMs": 100,
    ]
    if mode == .mobile {
      params["viewportWidth"] = .number(width.rounded())
      params["viewportHeight"] = .number(height.rounded())
      params["deviceScaleFactor"] = 2
      params["mobile"] = true
    }
    return params
  }
}

/// Where a frame sits in the pane, and how a touch maps to the page's CSS pixels (browser-touch-geometry.ts).
public struct BrowserFrameGeometry: Sendable, Equatable {
  public static let minZoom = 1.0
  public static let maxZoom = 3.5

  public var sourceWidth: Double
  public var sourceHeight: Double
  public var viewportWidth: Double
  public var viewportHeight: Double
  public var renderedWidth: Double
  public var renderedHeight: Double
  public var offsetX: Double
  public var offsetY: Double
  public var scale: Double
  /// Frame device pixels to page CSS pixels: page scale times page zoom.
  public var pageScale: Double

  public init?(width: Double, height: Double, metadata: BrowserFrameMetadata?) {
    guard width > 0, height > 0 else { return nil }
    sourceWidth = metadata?.deviceWidth.flatMap { $0 > 0 ? $0 : nil } ?? width
    sourceHeight = metadata?.deviceHeight.flatMap { $0 > 0 ? $0 : nil } ?? height
    scale = min(width / sourceWidth, height / sourceHeight)
    guard scale.isFinite, scale > 0 else { return nil }
    viewportWidth = width
    viewportHeight = height
    renderedWidth = sourceWidth * scale
    renderedHeight = sourceHeight * scale
    offsetX = (width - renderedWidth) / 2
    offsetY = (height - renderedHeight) / 2
    pageScale =
      (metadata?.pageScaleFactor.flatMap { $0 > 0 ? $0 : nil } ?? 1) * (metadata?.zoomFactor.flatMap { $0 > 0 ? $0 : nil } ?? 1)
  }

  /// A pinch zoom: its scale and how far the frame's centre moved.
  public struct Zoom: Sendable, Equatable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public static let none = Zoom(scale: 1, offsetX: 0, offsetY: 0)

    public init(scale: Double, offsetX: Double, offsetY: Double) {
      self.scale = scale
      self.offsetX = offsetX
      self.offsetY = offsetY
    }
  }

  /// A point in the pane as the page's viewport CSS point; nil off the frame.
  public func pagePoint(x: Double, y: Double, zoom: Zoom) -> (x: Double, y: Double)? {
    guard zoom.scale > 0 else { return nil }
    let centerX = offsetX + renderedWidth / 2 + zoom.offsetX
    let centerY = offsetY + renderedHeight / 2 + zoom.offsetY
    let localX = (x - centerX) / zoom.scale + renderedWidth / 2
    let localY = (y - centerY) / zoom.scale + renderedHeight / 2
    guard localX >= 0, localY >= 0, localX <= renderedWidth, localY <= renderedHeight else { return nil }
    return (
      clamp((localX / renderedWidth * sourceWidth / pageScale).rounded(), 0, sourceWidth / pageScale),
      clamp((localY / renderedHeight * sourceHeight / pageScale).rounded(), 0, sourceHeight / pageScale)
    )
  }

  /// A drag on screen as the wheel the page should get, in its CSS pixels: inverted, as a wheel reports it.
  public func wheelDelta(screenDx: Double, screenDy: Double, zoomScale: Double) -> (dx: Double, dy: Double) {
    let factor = scale * zoomScale * pageScale
    let css = factor.isFinite && factor > 0 ? factor : 1
    func round(_ value: Double) -> Double { let r = value.rounded(); return r == 0 ? 0 : r }
    return (round(-screenDx / css), round(-screenDy / css))
  }

  /// A finger-sized radius in the page's CSS pixels, so a tap can still land on a tiny link.
  public func clickRadius(zoomScale: Double, touchRadius: Double = 14) -> Double {
    let factor = scale * zoomScale * pageScale
    guard factor.isFinite, factor > 0 else { return 10 }
    return clamp((touchRadius / factor).rounded(), 6, 48)
  }

  /// Keeps a zoom inside the frame: back at 1× it recentres.
  public func clamped(_ zoom: Zoom) -> Zoom {
    let scale = clamp(zoom.scale, Self.minZoom, Self.maxZoom)
    if scale <= Self.minZoom + 0.01 { return .none }
    let maxX = max(0, (renderedWidth * scale - viewportWidth) / 2)
    let maxY = max(0, (renderedHeight * scale - viewportHeight) / 2)
    return Zoom(scale: scale, offsetX: clamp(zoom.offsetX, -maxX, maxX), offsetY: clamp(zoom.offsetY, -maxY, maxY))
  }
}

/// The desktop's address-bar rule (shared/browser/navigation/browser-url.ts), with its default search engine.
public enum BrowserURL {
  /// What to load for what was typed: a URL, a local address, a file path, or a Google search. Blank opens a
  /// blank page. Nil for a scheme the browser refuses (javascript:, data:).
  public static func normalize(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "about:blank" || trimmed == "data:text/html," { return "about:blank" }
    if trimmed.range(of: #"^(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[[0-9a-f:]+\])(?::\d+)?(?:[/?#].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return "http://" + trimmed
    }
    if trimmed.hasPrefix("/") {
      let path = trimmed.split(separator: "/", omittingEmptySubsequences: false).map {
        String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? String($0)
      }
      return "file://" + path.joined(separator: "/")
    }
    if trimmed.range(of: #"^[^\s/\\:@?#]+\.[^\s/\\:@?#]*:\d+(?:[/?#].*)?$"#, options: .regularExpression) != nil {
      let host = trimmed.prefix { $0 != ":" }.lowercased()
      return (host.hasSuffix(".localhost") ? "http://" : "https://") + trimmed
    }
    // Anything with a scheme is a URL already; only web pages and local files load.
    if let scheme = trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) {
      return ["http", "https", "file"].contains(trimmed[scheme].dropLast().lowercased()) ? trimmed : nil
    }
    if looksLikeSearch(trimmed) {
      let query = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? trimmed
      return "https://www.google.com/search?q=" + query
    }
    return "https://" + trimmed
  }

  static func looksLikeSearch(_ input: String) -> Bool {
    if input.contains(" ") { return true }
    if input.range(of: #"^[^\s]+\.[a-z]{2,}(/.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
    return !(input.contains(".") || input.contains(":"))
  }

  /// The address bar's text: a blank page reads as about:blank.
  public static func display(_ url: String?) -> String {
    let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty || trimmed == "about:blank" || trimmed.hasPrefix("data:text/html") ? "about:blank" : trimmed
  }
}

private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { max(low, min(high, value)) }

// MARK: - Calls

public enum BrowserCapability {
  /// The host streams browser tabs to a phone.
  public static let screencast = "browser.screencast.v1"
}

extension HostAPI {
  /// Streams a browser page's frames (`browser.screencast`). Binary frames of kind 0x62 belong to it; the
  /// `ready` event names the subscription, which acks and the release use.
  public func browserScreencast(worktreeId: String, pageId: String, request: [String: JSONValue]) async -> RPCBinarySubscription {
    var params = request
    params["worktree"] = .string("id:\(worktreeId)")
    params["page"] = .string(pageId)
    params["frameAck"] = 1
    return await connection.subscribeWithBinary(
      "browser.screencast", .object(params), release: .readyId(method: "browser.screencast.unsubscribe"))
  }

  /// Credits frames up to `seq`; cumulative, so a dropped ack is covered by the next.
  public func browserScreencastAck(worktreeId: String, subscriptionId: String, seq: UInt32) async {
    await connection.notify(
      "browser.screencast.ack",
      ["worktree": .string("id:\(worktreeId)"), "subscriptionId": .string(subscriptionId), "seq": .number(Double(seq))])
  }

  /// A command on one page: `browser.back`, `browser.mouseClick`, `browser.keypress` …, with its own fields.
  @discardableResult
  public func browserCommand(
    _ method: String, worktreeId: String, pageId: String, _ fields: [String: JSONValue] = [:], timeout: Duration = .seconds(15)
  ) async throws -> JSONValue {
    var params = fields
    params["worktree"] = .string("id:\(worktreeId)")
    params["page"] = .string(pageId)
    return try await connection.request(method, .object(params), timeout: timeout)
  }

  /// Loads a URL in the page and answers the URL it settled on.
  public func browserGoto(worktreeId: String, pageId: String, url: String) async throws -> String? {
    try await browserCommand("browser.goto", worktreeId: worktreeId, pageId: pageId, ["url": .string(url)], timeout: .seconds(30))["url"]?
      .stringValue
  }
}
