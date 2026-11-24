import CoreMedia
import CoreText
import OrcaCore
import UIKit

/// Draws a session transcript or a two-row agent status strip into a picture-in-picture frame.
@MainActor
enum PiPRenderer {
  private struct SymbolCacheKey: Hashable {
    let name: String
    let sizeTenths: Int
    let weightRaw: Int
    let rgba: UInt32
  }

  private struct LucideCacheKey: Hashable {
    let name: String
    let sizeTenths: Int
    let strokeTenths: Int
    let rgba: UInt32
  }

  private struct DynamicSpinnerSlot {
    let center: CGPoint
    let isChildStack: Bool
  }

  private struct DynamicToolSlot {
    let centerX: CGFloat
    let midY: CGFloat
    let baseIcon: UIImage?
    let globeIcon: UIImage?
    let startedAt: TimeInterval
  }

  private struct DynamicOverlayCapture {
    var spinners: [DynamicSpinnerSlot] = []
    var toolSlots: [DynamicToolSlot] = []
  }

  private struct CompactBackdropCache {
    let frame: PiPFrame
    let reduceMotion: Bool
    let image: CGImage
    let spinners: [DynamicSpinnerSlot]
    let toolSlots: [DynamicToolSlot]
  }

  private static var compactPool: CVPixelBufferPool?
  private static var transcriptPool: CVPixelBufferPool?
  private static var symbolCache: [SymbolCacheKey: UIImage] = [:]
  private static var lucideCache: [LucideCacheKey: UIImage] = [:]
  private static var backdropCache: CompactBackdropCache?

  static func clearCache() {
    backdropCache = nil
  }

  private static func pixelBuffer(width: Int, height: Int, layout: PiPLayout) -> CVPixelBuffer? {
    let existing = layout == .compact ? compactPool : transcriptPool
    let pool: CVPixelBufferPool?
    if let existing {
      pool = existing
    } else {
      let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
      let bufferAttrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      ]
      var created: CVPixelBufferPool?
      if CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &created) == kCVReturnSuccess,
        let created {
        if layout == .compact { compactPool = created } else { transcriptPool = created }
        pool = created
      } else {
        pool = nil
      }
    }
    var pixelBuffer: CVPixelBuffer?
    if let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer {
      return pixelBuffer
    }
    let fallbackAttrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    guard
      CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, fallbackAttrs as CFDictionary, &pixelBuffer)
        == kCVReturnSuccess
    else { return nil }
    return pixelBuffer
  }

  private static func compactBackdrop(for frame: PiPFrame, width: Int, height: Int, scale: CGFloat, at time: TimeInterval) -> CompactBackdropCache? {
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    if let cached = backdropCache, cached.frame == frame, cached.reduceMotion == reduceMotion {
      return cached
    }
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard
      let offscreen = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
    else { return nil }
    offscreen.translateBy(x: 0, y: CGFloat(height))
    offscreen.scaleBy(x: scale, y: -scale)
    var capture = DynamicOverlayCapture()
    UIGraphicsPushContext(offscreen)
    let bounds = CGRect(origin: .zero, size: PiPLayout.compact.size)
    compactGround.setFill()
    UIRectFill(bounds)
    drawCompact(frame, in: bounds, transition: nil, progress: 1, spinnerAngle: 0, childSpinnerAngle: 0, at: time, capture: &capture)
    UIGraphicsPopContext()
    guard let image = offscreen.makeImage() else { return nil }
    let cache = CompactBackdropCache(
      frame: frame, reduceMotion: reduceMotion, image: image,
      spinners: capture.spinners, toolSlots: capture.toolSlots)
    backdropCache = cache
    return cache
  }

  static func sampleBuffer(
    for frame: PiPFrame, layout: PiPLayout, transition: PiPScrollTransition? = nil,
    progress: CGFloat = 1, spinnerAngle: CGFloat = 0, childSpinnerAngle: CGFloat = 0,
    at time: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> CMSampleBuffer? {
    let size = layout.size
    let scale: CGFloat = layout == .compact ? 3 : 2
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    guard let pixelBuffer = pixelBuffer(width: width, height: height, layout: layout) else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }

    if layout == .compact, transition == nil,
      let cached = compactBackdrop(for: frame, width: width, height: height, scale: scale, at: time) {
      // Blit static 1200×204 backdrop directly in unflipped coordinates, then paint only the animated icons.
      context.setBlendMode(.copy)
      context.draw(cached.image, in: CGRect(x: 0, y: 0, width: width, height: height))
      context.setBlendMode(.normal)
      if !cached.spinners.isEmpty || !cached.toolSlots.isEmpty {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        let animatesIcons = !cached.reduceMotion
        for slot in cached.spinners {
          drawSpinner(
            in: context, center: slot.center,
            angle: slot.isChildStack ? childSpinnerAngle : spinnerAngle,
            isChildStack: slot.isChildStack)
        }
        for slot in cached.toolSlots {
          drawCrossfadingToolIcon(
            base: slot.baseIcon, globe: slot.globeIcon, centerX: slot.centerX, midY: slot.midY,
            startedAt: slot.startedAt, at: time, animated: animatesIcons)
        }
        UIGraphicsPopContext()
      }
    } else {
      // UIKit drawing, top-left origin, in points.
      context.translateBy(x: 0, y: CGFloat(height))
      context.scaleBy(x: scale, y: -scale)
      UIGraphicsPushContext(context)
      draw(
        frame, layout: layout, transition: transition, progress: progress,
        spinnerAngle: spinnerAngle, childSpinnerAngle: childSpinnerAngle, at: time)
      UIGraphicsPopContext()
    }

    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
    guard let format else { return nil }
    let now = CMClockGetTime(CMClockGetHostTimeClock())
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample)
    if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }

  /// The same frame as an image, for checking it by eye.
  static func image(for frame: PiPFrame, layout: PiPLayout, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    if layout == .compact {
      format.scale = 3
      format.opaque = true
    }
    return UIGraphicsImageRenderer(size: layout.size, format: format).image { _ in
      draw(frame, layout: layout, at: time)
    }
  }

  private static let ground = UIColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1)
  private static let green = UIColor(red: 0.30, green: 0.80, blue: 0.47, alpha: 1)
  private static let amber = UIColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1)
  private static let compactGround = UIColor(red: 10 / 255, green: 10 / 255, blue: 13 / 255, alpha: 1)
  private static let compactGreen = UIColor(red: 50 / 255, green: 215 / 255, blue: 75 / 255, alpha: 1)
  private static let compactAmber = UIColor(red: 245 / 255, green: 184 / 255, blue: 46 / 255, alpha: 1)
  private static let decisionRed = UIColor(red: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
  private static let decisionGlyph = UIColor(red: 255 / 255, green: 107 / 255, blue: 99 / 255, alpha: 1)
  private static let answerOrange = UIColor(red: 255 / 255, green: 159 / 255, blue: 10 / 255, alpha: 1)
  private static let answerGlyph = UIColor(red: 255 / 255, green: 179 / 255, blue: 64 / 255, alpha: 1)
  private static let coinDark = UIColor(red: 27 / 255, green: 27 / 255, blue: 33 / 255, alpha: 1)
  private static let coinLight = UIColor(red: 236 / 255, green: 236 / 255, blue: 241 / 255, alpha: 1)
  private static let coinOverflow = UIColor(red: 38 / 255, green: 38 / 255, blue: 46 / 255, alpha: 1)
  private static let decisionCutout = UIColor(red: 24 / 255, green: 14 / 255, blue: 16 / 255, alpha: 1)
  private static let answerCutout = UIColor(red: 24 / 255, green: 19 / 255, blue: 12 / 255, alpha: 1)

  private static let spinnerStroke: (path: CGPath, gradient: CGGradient?, tail: CGPoint, head: CGPoint) = {
    let radius: CGFloat = 2.85
    let headHalfWidth: CGFloat = 0.8
    let sweep: CGFloat = .pi * 0.97
    let segments = 16
    func point(at index: Int, edge: CGFloat) -> CGPoint {
      let fraction = CGFloat(index) / CGFloat(segments)
      let angle = -sweep * (1 - fraction)
      let distance = radius + edge * headHalfWidth * fraction
      return CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
    }
    let tail = point(at: 0, edge: 0)
    let head = CGPoint(x: radius, y: 0)
    let path = CGMutablePath()
    path.move(to: tail)
    for index in 1...segments {
      path.addLine(to: point(at: index, edge: 1))
    }
    path.addArc(center: head, radius: headHalfWidth, startAngle: 0, endAngle: .pi, clockwise: false)
    for index in (0..<segments).reversed() {
      path.addLine(to: point(at: index, edge: -1))
    }
    path.closeSubpath()
    let colors = [compactAmber.withAlphaComponent(0).cgColor, compactAmber.withAlphaComponent(0.34).cgColor, compactAmber.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.54, 1])
    return (path, gradient, tail, head)
  }()

  private static func drawSpinner(in context: CGContext, center: CGPoint, angle: CGFloat, isChildStack: Bool = false) {
    let stroke = spinnerStroke
    guard let gradient = stroke.gradient else { return }
    context.saveGState()
    if isChildStack {
      compactGround.withAlphaComponent(0.76).setFill()
      UIBezierPath(ovalIn: CGRect(x: center.x - 3.3, y: center.y - 3.3, width: 6.6, height: 6.6)).fill()
    }
    context.translateBy(x: center.x, y: center.y)
    if isChildStack {
      let factor: CGFloat = 2.35 / 2.85
      context.scaleBy(x: factor, y: factor)
    }
    context.rotate(by: angle - .pi / 2)
    context.addPath(stroke.path)
    context.clip()
    context.drawLinearGradient(
      gradient, start: stroke.tail, end: stroke.head, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
  }

  private static func colorKey(_ color: UIColor) -> UInt32 {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    let rb = UInt32(max(0, min(255, Int((r * 255).rounded()))))
    let gb = UInt32(max(0, min(255, Int((g * 255).rounded()))))
    let bb = UInt32(max(0, min(255, Int((b * 255).rounded()))))
    let ab = UInt32(max(0, min(255, Int((a * 255).rounded()))))
    return (rb << 24) | (gb << 16) | (bb << 8) | ab
  }

  private static func cachedSymbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, color: UIColor) -> UIImage? {
    let key = SymbolCacheKey(
      name: name, sizeTenths: Int((pointSize * 10).rounded()),
      weightRaw: weight.rawValue, rgba: colorKey(color))
    if let cached = symbolCache[key] { return cached }
    let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal) else {
      return nil
    }
    if symbolCache.count >= 128 { symbolCache.removeAll(keepingCapacity: true) }
    symbolCache[key] = image
    return image
  }

  private static func cachedLucide(_ icon: Lucide, size: CGFloat, strokeWidth: CGFloat, color: UIColor) -> UIImage {
    let key = LucideCacheKey(
      name: icon.name, sizeTenths: Int((size * 10).rounded()),
      strokeTenths: Int((strokeWidth * 10).rounded()), rgba: colorKey(color))
    if let cached = lucideCache[key] { return cached }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
      let cg = context.cgContext
      cg.scaleBy(x: size / 24, y: size / 24)
      cg.addPath(icon.path)
      cg.setLineWidth(strokeWidth)
      cg.setLineCap(.round)
      cg.setLineJoin(.round)
      cg.setStrokeColor(color.cgColor)
      cg.strokePath()
    }.withRenderingMode(.alwaysOriginal)
    if lucideCache.count >= 128 { lucideCache.removeAll(keepingCapacity: true) }
    lucideCache[key] = image
    return image
  }

  private static func toolLucideIcon(for kind: TranscriptItem.ToolCall.ActivityKind?, running: Bool) -> Lucide {
    guard running, let kind else { return .terminal }
    switch kind {
    case .command: return .squareTerminal
    case .fileChange: return .pencil
    case .webSearch, .browser: return .globe
    case .search: return .search
    case .read: return .eye
    case .integration: return .plug
    case .subagent: return .bot
    case .plan: return .listChecks
    case .other: return .terminal
    }
  }

  private static func drawScaledIcon(_ icon: UIImage?, centerX: CGFloat, midY: CGFloat, opacity: CGFloat) {
    guard let icon, opacity > 0 else { return }
    let scale = 0.88 + 0.12 * opacity
    let width = icon.size.width * scale
    let height = icon.size.height * scale
    icon.draw(
      in: CGRect(x: centerX - width / 2, y: midY - height / 2, width: width, height: height),
      blendMode: .normal, alpha: opacity)
  }

  private static func drawCrossfadingToolIcon(
    base: UIImage?, globe: UIImage?, centerX: CGFloat, midY: CGFloat,
    startedAt: TimeInterval?, at time: TimeInterval, animated: Bool
  ) {
    let globeOpacity = globe == nil ? 0 : PiPWebSearchIndicator.globeOpacity(
      startedAt: startedAt, at: time, animated: animated)
    drawScaledIcon(base, centerX: centerX, midY: midY, opacity: 1 - globeOpacity)
    drawScaledIcon(globe, centerX: centerX, midY: midY, opacity: globeOpacity)
  }

  private static func draw(
    _ frame: PiPFrame, layout: PiPLayout, transition: PiPScrollTransition? = nil,
    progress: CGFloat = 1, spinnerAngle: CGFloat = 0, childSpinnerAngle: CGFloat = 0, at time: TimeInterval
  ) {
    let bounds = CGRect(origin: .zero, size: layout.size)
    let background = layout == .compact ? compactGround : frame.terminal ? TerminalText.background : ground
    background.setFill()
    UIRectFill(bounds)
    if layout == .compact {
      var unused: DynamicOverlayCapture? = nil
      drawCompact(
        frame, in: bounds, transition: transition, progress: progress,
        spinnerAngle: spinnerAngle, childSpinnerAngle: childSpinnerAngle, at: time, capture: &unused)
      return
    }
    let pad: CGFloat = 14

    // Header: a state dot, the session's name, its state word on the right.
    let dot = CGRect(x: pad, y: pad + 5, width: 8, height: 8)
    (frame.working ? amber : green).setFill()
    UIBezierPath(ovalIn: dot).fill()
    let status = NSAttributedString(
      string: frame.status,
      attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: UIColor(white: 1, alpha: 0.55)])
    let statusWidth = ceil(status.size().width)
    status.draw(at: CGPoint(x: bounds.maxX - pad - statusWidth, y: pad + 1))
    let title = NSAttributedString(
      string: frame.title,
      attributes: [
        .font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.white,
        .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }(),
      ])
    title.draw(in: CGRect(x: dot.maxX + 8, y: pad - 1, width: bounds.width - dot.maxX - 8 - statusWidth - pad * 2, height: 20))
    // Blended, not UIRectFill: that copies the colour in, alpha and all.
    UIColor(white: 1, alpha: 0.08).setFill()
    UIBezierPath(rect: CGRect(x: 0, y: pad + 26, width: bounds.width, height: 1)).fill()

    // Body: the newest lines, bottom-aligned, clipped at the top.
    let body = CGRect(x: pad, y: pad + 34, width: bounds.width - pad * 2, height: bounds.height - pad * 2 - 34)
    let text = NSMutableAttributedString()
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    paragraph.paragraphSpacing = frame.terminal ? 0 : 6
    for (index, line) in frame.lines.enumerated() {
      let font: UIFont
      let color: UIColor
      switch line.style {
      case .body: (font, color) = (.systemFont(ofSize: 13), UIColor(white: 1, alpha: 0.92))
      case .muted: (font, color) = (.italicSystemFont(ofSize: 12), UIColor(white: 1, alpha: 0.5))
      case .call: (font, color) = (.monospacedSystemFont(ofSize: 11, weight: .regular), UIColor(red: 0.48, green: 0.64, blue: 0.97, alpha: 1))
      case .terminal: (font, color) = (.monospacedSystemFont(ofSize: 10.5, weight: .regular), TerminalText.foreground)
      }
      text.append(
        NSAttributedString(
          string: line.text + (index == frame.lines.count - 1 ? "" : "\n"),
          attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
    }
    let needed = ceil(
      text.boundingRect(with: CGSize(width: body.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
        .height)
    guard let context = UIGraphicsGetCurrentContext() else { return }
    context.saveGState()
    context.clip(to: body)
    text.draw(
      with: CGRect(x: body.minX, y: body.maxY - needed, width: body.width, height: needed), options: [.usesLineFragmentOrigin],
      context: nil)
    context.restoreGState()
    // A soft fade where the oldest lines run under the header.
    if needed > body.height {
      let ground = frame.terminal ? TerminalText.background : Self.ground
      let colors = [ground.cgColor, ground.withAlphaComponent(0).cgColor] as CFArray
      if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.minY + 24), options: [])
      }
    }
  }

  private static func drawCompact(
    _ frame: PiPFrame, in bounds: CGRect, transition: PiPScrollTransition?,
    progress: CGFloat, spinnerAngle: CGFloat, childSpinnerAngle: CGFloat, at time: TimeInterval,
    capture: inout DynamicOverlayCapture
  ) {
    var optionalCapture: DynamicOverlayCapture? = capture
    drawCompact(
      frame, in: bounds, transition: transition, progress: progress,
      spinnerAngle: spinnerAngle, childSpinnerAngle: childSpinnerAngle, at: time, capture: &optionalCapture)
    if let updated = optionalCapture { capture = updated }
  }

  private static func drawCompact(
    _ frame: PiPFrame, in bounds: CGRect, transition: PiPScrollTransition?,
    progress: CGFloat, spinnerAngle: CGFloat, childSpinnerAngle: CGFloat, at time: TimeInterval,
    capture: inout DynamicOverlayCapture?
  ) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    let animatesIcons = !UIAccessibility.isReduceMotionEnabled

    // MARK: CoreText & SF Symbol Helpers
    func makeAttr(_ text: String, font: UIFont, color: UIColor, kern: CGFloat = 0) -> NSAttributedString {
      var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      if kern != 0 { attrs[.kern] = kern }
      return NSAttributedString(string: text, attributes: attrs)
    }
    func measureAttr(_ attr: NSAttributedString) -> CGFloat {
      ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)))
    }
    @discardableResult
    func drawText(
      _ attr: NSAttributedString, font: UIFont, atX x: CGFloat, midY: CGFloat,
      maxWidth: CGFloat? = nil, truncate: CTLineTruncationType = .middle,
      alignRight: Bool = false, exactGlyphCenter: Bool = false
    ) -> CGFloat {
      var line = CTLineCreateWithAttributedString(attr)
      var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      if let maxW = maxWidth, width > maxW, attr.length > 0 {
        let token = CTLineCreateWithAttributedString(
          NSAttributedString(string: "…", attributes: attr.attributes(at: 0, effectiveRange: nil)))
        if let truncated = CTLineCreateTruncatedLine(line, Double(maxW), truncate, token) {
          line = truncated
          width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
      }
      let baselineY: CGFloat
      if exactGlyphCenter {
        let gb = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        baselineY = midY + (gb.minY + gb.height / 2)
      } else {
        let hasCJK = attr.string.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        baselineY = midY + font.capHeight * (hasCJK ? 0.39 : 0.48)
      }
      context.saveGState()
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: alignRight ? (x - width) : x, y: baselineY)
      CTLineDraw(line, context)
      context.restoreGState()
      return ceil(width)
    }
    @discardableResult
    func drawSymbol(
      _ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight,
      color: UIColor, centerX: CGFloat, centerY: CGFloat
    ) -> CGFloat {
      guard let image = cachedSymbol(name, pointSize: pointSize, weight: weight, color: color) else { return 0 }
      let size = image.size
      image.draw(at: CGPoint(x: centerX - size.width / 2, y: centerY - size.height / 2))
      return size.width
    }

    // Empty / Unavailable state
    if frame.statusRows.isEmpty {
      let midY = bounds.midY
      let dotRect = CGRect(x: 17, y: midY - 3, width: 6, height: 6)
      if frame.statusAvailable {
        compactGreen.setFill()
        UIBezierPath(ovalIn: dotRect).fill()
      } else {
        UIColor(white: 1, alpha: 0.38).setStroke()
        let ring = UIBezierPath(ovalIn: dotRect)
        ring.lineWidth = 1.3
        ring.stroke()
      }
      let emptyFont = UIFont.systemFont(ofSize: 14, weight: .medium)
      let emptyColor = UIColor(white: 1, alpha: frame.statusAvailable ? 0.86 : 0.58)
      drawText(
        makeAttr(frame.title, font: emptyFont, color: emptyColor),
        font: emptyFont, atX: 31, midY: midY, maxWidth: bounds.width - 46, truncate: .end)
      return
    }

    // MARK: Plan B + Style 3 Geometry Constants (400×68 pt)
    let hasRail = (frame.scrollState?.activities.count ?? 0) > 2
    let rowTop: CGFloat = 4
    let rowHeight: CGFloat = 29
    let rowGap: CGFloat = 2
    let rowStride: CGFloat = rowHeight + rowGap // 31
    let accentBarX: CGFloat = 8.5
    let accentBarW: CGFloat = 2.5
    let accentBarH: CGFloat = 15
    let leadLogoX: CGFloat = 15.5
    let leadLogoSize: CGFloat = 18
    let nameX: CGFloat = 41
    let cardRight: CGFloat = hasRail ? 389.0 : 395.5
    // Keep balanced right breathing room both with and without the 2pt scroll rail.
    let contentRight: CGFloat = hasRail ? 383.5 : 389.0
    let rightBlockWidth: CGFloat = 58
    let stackRight: CGFloat = contentRight - rightBlockWidth - 11
    let scrollRailX: CGFloat = 393.5
    let scrollRailW: CGFloat = 2.0
    let coinSize: CGFloat = 15
    let coinStep: CGFloat = 10.5

    let nameSingleFont = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
    let nameStackedFont = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    let hostSubFont = UIFont.systemFont(ofSize: 10.0, weight: .medium)
    let tokFont = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    let toolFont = UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    let prominentToolFont = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    let elapsedSingleFont = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    let elapsedAttnFont = UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    let overflowFont = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)

    func tokenAttributed(_ row: PiPFrame.StatusLine, dimmed: Bool) -> NSAttributedString? {
      guard let total = row.totalTokens else { return nil }
      let formatted: String
      if row.tokenCountIsPartial {
        let step = total >= 1_000_000 ? 10_000 : total >= 1_000 ? 100 : 1
        formatted = ChatDockView.compact(total / step * step, millionDigits: 2)
      } else {
        formatted = ChatDockView.compact(total, millionDigits: 2)
      }
      let result = NSMutableAttributedString()
      if row.tokenCountIsPartial {
        result.append(makeAttr("≥", font: tokFont, color: UIColor(white: 1, alpha: dimmed ? 0.32 : 0.45)))
      }
      result.append(makeAttr(formatted, font: tokFont, color: UIColor(white: 1, alpha: dimmed ? 0.60 : 0.84)))
      return result
    }

    @discardableResult
    func drawMetric(_ attr: NSAttributedString, font: UIFont, midY: CGFloat, maxWidth: CGFloat) -> CGFloat {
      let measured = measureAttr(attr)
      guard measured > maxWidth else {
        return drawText(attr, font: font, atX: contentRight, midY: midY, alignRight: true)
      }
      let scale = maxWidth / measured
      context.saveGState()
      context.translateBy(x: contentRight, y: midY)
      context.scaleBy(x: scale, y: scale)
      drawText(attr, font: font, atX: 0, midY: 0, alignRight: true)
      context.restoreGState()
      return maxWidth
    }

    /// Draws the tool count and active Lucide category/web-search icon, returning the leftmost x drawn.
    func drawToolCount(_ count: String, for row: PiPFrame.StatusLine, prominent: Bool, midY: CGFloat) -> CGFloat {
      let font = prominent ? prominentToolFont : toolFont
      let iconSize: CGFloat = prominent ? 11.8 : 9.0
      let strokeWidth: CGFloat = prominent ? 2.15 : 2.25
      let running = row.toolRunning
      let textColor = running ? compactAmber.withAlphaComponent(0.92) : UIColor(white: 1, alpha: prominent ? 0.84 : 0.56)
      let iconColor = running ? compactAmber.withAlphaComponent(0.88) : UIColor(white: 1, alpha: prominent ? 0.64 : 0.44)
      let attr = NSMutableAttributedString(attributedString: makeAttr(count, font: font, color: textColor))
      if count.hasPrefix("≥") {
        attr.addAttribute(.foregroundColor, value: textColor.withAlphaComponent(running ? 0.72 : 0.44), range: NSRange(location: 0, length: 1))
      }
      let baseLucide = toolLucideIcon(for: row.activeToolKind, running: running)
      let baseIcon = cachedLucide(baseLucide, size: iconSize, strokeWidth: strokeWidth, color: iconColor)
      let globeIcon: UIImage? = baseLucide == .globe
        ? nil
        : cachedLucide(.globe, size: iconSize, strokeWidth: strokeWidth, color: iconColor)
      let iconWidth = max(baseIcon.size.width, globeIcon?.size.width ?? 0)
      let gap: CGFloat = 2.5
      let width = drawMetric(attr, font: font, midY: midY, maxWidth: rightBlockWidth - iconWidth - gap)
      let centerX = contentRight - width - gap - iconWidth / 2

      if let startedAt = row.webSearchStartedAt, baseLucide != .globe {
        if capture != nil {
          capture?.toolSlots.append(
            DynamicToolSlot(centerX: centerX, midY: midY, baseIcon: baseIcon, globeIcon: globeIcon, startedAt: startedAt))
        } else {
          drawCrossfadingToolIcon(
            base: baseIcon, globe: globeIcon, centerX: centerX, midY: midY,
            startedAt: startedAt, at: time, animated: animatesIcons)
        }
      } else {
        drawScaledIcon(baseIcon, centerX: centerX, midY: midY, opacity: 1)
      }
      return centerX - iconWidth / 2
    }

    struct StackLayout {
      let visible: [String?]
      let extra: Int
      let totalWidth: CGFloat
      let overflowWidth: CGFloat
    }
    func computeStack(_ types: [String?], maxVisible: Int) -> StackLayout {
      if types.isEmpty { return StackLayout(visible: [], extra: 0, totalWidth: 0, overflowWidth: 0) }
      let vis = Array(types.prefix(maxVisible))
      let extra = max(0, types.count - vis.count)
      if extra > 0 {
        let ovW: CGFloat = extra >= 10 ? 23.0 : 18.5
        return StackLayout(visible: vis, extra: extra, totalWidth: CGFloat(vis.count) * coinStep + ovW, overflowWidth: ovW)
      }
      return StackLayout(visible: vis, extra: 0, totalWidth: coinSize + CGFloat(vis.count - 1) * coinStep, overflowWidth: 0)
    }

    func drawRow(_ row: PiPFrame.StatusLine, at y: CGFloat, alpha: CGFloat = 1) {
      context.saveGState()
      context.setAlpha(alpha)
      let midY = y + rowHeight / 2
      let isAttention = row.activity != .working
      var cutoutBg = compactGround

      // 1. Attention Row (Style 3): Left-to-right directional spotlight gradient + crisp left beacon bar
      if isAttention {
        let isDecision = row.activity == .needsDecision
        let accent = isDecision ? decisionRed : answerOrange
        let cardRect = CGRect(x: 4.5, y: y, width: cardRight - 4.5, height: rowHeight)
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 11)
        context.saveGState()
        cardPath.addClip()
        let colors = [
          accent.withAlphaComponent(0.22).cgColor,
          accent.withAlphaComponent(0.09).cgColor,
          accent.withAlphaComponent(0.04).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
          context.drawLinearGradient(
            gradient, start: CGPoint(x: cardRect.minX, y: midY), end: CGPoint(x: cardRect.maxX, y: midY), options: [])
        }
        context.restoreGState()
        cutoutBg = isDecision ? decisionCutout : answerCutout

        let barRect = CGRect(x: accentBarX, y: midY - accentBarH / 2, width: accentBarW, height: accentBarH)
        accent.setFill()
        UIBezierPath(roundedRect: barRect, cornerRadius: accentBarW / 2).fill()
      }

      // 2. Lead logo with a work indicator overlapping its lower-right corner.
      let leadRect = CGRect(x: leadLogoX, y: midY - leadLogoSize / 2, width: leadLogoSize, height: leadLogoSize)
      let leadBackdrop = AgentMark.overlayBackdrop(for: row.agentType)
      context.saveGState()
      if leadBackdrop != .transparent {
        UIBezierPath(roundedRect: leadRect, cornerRadius: 4).addClip()
      }
      AgentMark.overlayImage(for: row.agentType, size: leadLogoSize).draw(in: leadRect)
      context.restoreGState()

      if !isAttention {
        let center = CGPoint(x: leadRect.maxX + 0.7, y: leadRect.maxY - 2)
        if row.leadWorking {
          if capture != nil {
            capture?.spinners.append(DynamicSpinnerSlot(center: center, isChildStack: false))
          } else {
            drawSpinner(in: context, center: center, angle: spinnerAngle)
          }
        } else {
          compactAmber.withAlphaComponent(0.78).setStroke()
          let ring = UIBezierPath(ovalIn: CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4))
          ring.lineWidth = 1.2
          ring.stroke()
        }
      }

      // 3. Right telemetry / status column (tracks exact leftmost x drawn so coinless rows can widen titles).
      let topMidY = midY - 6.0
      let botMidY = midY + 6.9
      var rightMetricMinX = contentRight
      if isAttention {
        let isDecision = row.activity == .needsDecision
        let glyphName = isDecision ? "hand.raised.fill" : "questionmark.bubble.fill"
        let glyphColor = isDecision ? decisionGlyph : answerGlyph
        if let tokenAttr = tokenAttributed(row, dimmed: true) {
          let tokW = drawMetric(tokenAttr, font: tokFont, midY: topMidY, maxWidth: rightBlockWidth)
          let glyphCenterX = contentRight - 6.5
          let glyphW = drawSymbol(glyphName, pointSize: 10.5, weight: .semibold, color: glyphColor, centerX: glyphCenterX, centerY: botMidY)
          rightMetricMinX = min(contentRight - tokW, glyphCenterX - glyphW / 2)
        } else if let elapsed = row.elapsedText {
          let elapsedAttr = makeAttr(elapsed, font: elapsedAttnFont, color: UIColor(white: 1, alpha: 0.52))
          let elW = drawMetric(elapsedAttr, font: elapsedAttnFont, midY: topMidY, maxWidth: rightBlockWidth)
          let glyphCenterX = contentRight - 6.5
          let glyphW = drawSymbol(glyphName, pointSize: 10.5, weight: .semibold, color: glyphColor, centerX: glyphCenterX, centerY: botMidY)
          rightMetricMinX = min(contentRight - elW, glyphCenterX - glyphW / 2)
        } else {
          let glyphCenterX = contentRight - 8.0
          let glyphW = drawSymbol(glyphName, pointSize: 14.0, weight: .semibold, color: glyphColor, centerX: glyphCenterX, centerY: midY)
          rightMetricMinX = glyphCenterX - glyphW / 2
        }
      } else {
        let tokenAttr = tokenAttributed(row, dimmed: false)
        if let tokenAttr {
          let tokW = drawMetric(tokenAttr, font: tokFont, midY: row.toolCount == nil ? midY : topMidY, maxWidth: rightBlockWidth)
          rightMetricMinX = min(rightMetricMinX, contentRight - tokW)
        }
        if let toolCount = row.toolCount {
          let toolMinX = drawToolCount(toolCount, for: row, prominent: tokenAttr == nil, midY: tokenAttr == nil ? midY : botMidY)
          rightMetricMinX = min(rightMetricMinX, toolMinX)
        } else if tokenAttr == nil, let elapsed = row.elapsedText {
          let elapsedAttr = makeAttr(elapsed, font: elapsedSingleFont, color: UIColor(white: 1, alpha: 0.58))
          let elW = drawMetric(elapsedAttr, font: elapsedSingleFont, midY: midY, maxWidth: rightBlockWidth)
          rightMetricMinX = min(rightMetricMinX, contentRight - elW)
        }
      }

      // 4. Optional inline Worker glyph
      var effectiveNameX = nameX
      if row.isWorker {
        let iconMidY = row.showsHostSubtitle ? (midY - 5.8) : midY
        drawSymbol(
          "arrow.triangle.branch", pointSize: 8.8, weight: .semibold,
          color: UIColor(white: 1, alpha: 0.44), centerX: effectiveNameX + 4.5, centerY: iconMidY)
        effectiveNameX += 12.5
      }

      // 5. Right-Aligned Subagent Brand Stack (spine locked at stackRight so multi-row stacks stay aligned)
      let activeNameFont = row.showsHostSubtitle ? nameStackedFont : nameSingleFont
      let fullNameW = measureAttr(makeAttr(row.agent, font: activeNameFont, color: .white, kern: -0.15))
      var stack = computeStack(row.childTypes, maxVisible: 3)
      let stackGap: CGFloat = stack.visible.isEmpty ? 0 : 12
      let availForName3 = stackRight - stack.totalWidth - stackGap - effectiveNameX
      if row.childTypes.count >= 4 && ((fullNameW - availForName3) > 20 || availForName3 < 115) {
        stack = computeStack(row.childTypes, maxVisible: 2)
      }
      let stackStartX = stackRight - stack.totalWidth
      if !stack.visible.isEmpty {
        let coinY = midY - coinSize / 2
        for (index, type) in stack.visible.enumerated() {
          let coinRect = CGRect(x: stackStartX + CGFloat(index) * coinStep, y: coinY, width: coinSize, height: coinSize)
          cutoutBg.setFill()
          UIBezierPath(ovalIn: coinRect.insetBy(dx: -1.15, dy: -1.15)).fill()
          let backdrop = AgentMark.overlayBackdrop(for: type)
          switch backdrop {
          case .lightOpaque:
            coinLight.setFill()
            UIBezierPath(ovalIn: coinRect).fill()
            context.saveGState()
            UIBezierPath(ovalIn: coinRect).addClip()
            AgentMark.overlayImage(for: type, size: coinSize - 4.2).draw(in: coinRect.insetBy(dx: 2.1, dy: 2.1))
            context.restoreGState()
          case .darkOpaque:
            coinDark.setFill()
            UIBezierPath(ovalIn: coinRect).fill()
            context.saveGState()
            UIBezierPath(ovalIn: coinRect).addClip()
            AgentMark.overlayImage(for: type, size: coinSize - 0.8).draw(in: coinRect.insetBy(dx: 0.4, dy: 0.4))
            context.restoreGState()
          case .transparent:
            coinDark.setFill()
            UIBezierPath(ovalIn: coinRect).fill()
            AgentMark.overlayImage(for: type, size: coinSize - 4.6).draw(in: coinRect.insetBy(dx: 2.3, dy: 2.3))
          }
        }
        if stack.extra > 0 {
          let pillRect = CGRect(x: stackStartX + CGFloat(stack.visible.count) * coinStep, y: coinY, width: stack.overflowWidth, height: coinSize)
          let cutRect = pillRect.insetBy(dx: -1.15, dy: -1.15)
          cutoutBg.setFill()
          UIBezierPath(roundedRect: cutRect, cornerRadius: cutRect.height / 2).fill()
          coinOverflow.setFill()
          UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2).fill()
          let plusAttr = makeAttr("+\(stack.extra)", font: overflowFont, color: UIColor(white: 1, alpha: 0.85))
          let plusW = measureAttr(plusAttr)
          drawText(plusAttr, font: overflowFont, atX: pillRect.midX - plusW / 2, midY: midY, exactGlyphCenter: true)
        }
        // B2: when the lead agent is idle/monitoring and only subagents are working, show one shared
        // micro-spinner at the lower-right edge of the stack so the row stays visually alive.
        if row.showsChildStackSpinner {
          let stackSpinnerCenter = CGPoint(x: stackRight + 0.6, y: midY + 5.8)
          if capture != nil {
            capture?.spinners.append(DynamicSpinnerSlot(center: stackSpinnerCenter, isChildStack: true))
          } else {
            drawSpinner(in: context, center: stackSpinnerCenter, angle: childSpinnerAngle, isChildStack: true)
          }
        }
      }

      // 6. Primary Identity (extends elastically into unused right space when no subagent stack is shown)
      let nameRightLimit: CGFloat
      if !stack.visible.isEmpty {
        nameRightLimit = stackStartX - 12
      } else if rightMetricMinX < contentRight {
        nameRightLimit = max(stackRight, rightMetricMinX - 12)
      } else {
        nameRightLimit = contentRight - 4
      }
      let nameMaxW = max(68, nameRightLimit - effectiveNameX)
      let nameColor = UIColor(white: 1, alpha: isAttention ? 1.0 : 0.95)
      if row.showsHostSubtitle {
        drawText(
          makeAttr(row.agent, font: nameStackedFont, color: nameColor, kern: -0.15),
          font: nameStackedFont, atX: effectiveNameX, midY: midY - 5.8, maxWidth: nameMaxW, truncate: .middle)
        let hostMaxW = max(68, nameRightLimit - nameX)
        drawText(
          makeAttr(row.host, font: hostSubFont, color: UIColor(white: 1, alpha: 0.48)),
          font: hostSubFont, atX: nameX, midY: midY + 6.8, maxWidth: hostMaxW, truncate: .middle)
      } else {
        drawText(
          makeAttr(row.agent, font: nameSingleFont, color: nameColor, kern: -0.15),
          font: nameSingleFont, atX: effectiveNameX, midY: midY, maxWidth: nameMaxW, truncate: .middle)
      }
      context.restoreGState()
    }

    func drawEdgeFeather(in clipRect: CGRect) {
      let cs = CGColorSpaceCreateDeviceRGB()
      let feather: CGFloat = 2.5
      if let topGrad = CGGradient(
        colorsSpace: cs, colors: [compactGround.withAlphaComponent(0.75).cgColor, compactGround.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]) {
        context.drawLinearGradient(topGrad, start: CGPoint(x: 0, y: clipRect.minY), end: CGPoint(x: 0, y: clipRect.minY + feather), options: [])
      }
      if let botGrad = CGGradient(
        colorsSpace: cs, colors: [compactGround.withAlphaComponent(0).cgColor, compactGround.withAlphaComponent(0.75).cgColor] as CFArray,
        locations: [0, 1]) {
        context.drawLinearGradient(botGrad, start: CGPoint(x: 0, y: clipRect.maxY - feather), end: CGPoint(x: 0, y: clipRect.maxY), options: [])
      }
    }

    // MARK: Row Rendering + Scrolling Transitions
    let eased = progress * progress * (3 - 2 * progress)
    let clipWidth: CGFloat = hasRail ? 389 : bounds.width
    if let transition, progress < 1 {
      switch transition.kind {
      case .perRow(let leavingFirst, let leavingSecond) where frame.statusRows.count == 2:
        // Row 1: independent scroll (split-zone) or static pin (Pin-1)
        if let leavingFirst {
          let row1Clip = CGRect(x: 0, y: rowTop, width: clipWidth, height: rowHeight)
          context.saveGState()
          context.clip(to: row1Clip)
          let leavingY = row1Clip.minY - rowStride * eased
          drawRow(leavingFirst, at: leavingY, alpha: max(0.20, 1 - eased * 0.80))
          drawRow(frame.statusRows[0].line, at: leavingY + rowStride, alpha: 0.25 + eased * 0.75)
          drawEdgeFeather(in: row1Clip)
          context.restoreGState()
        } else {
          drawRow(frame.statusRows[0].line, at: rowTop, alpha: 1)
        }
        // Row 2: independent scroll (Pin-1 / split-zone) or static hold (single working in split-zone)
        if let leavingSecond {
          let row2Clip = CGRect(x: 0, y: rowTop + rowStride, width: clipWidth, height: rowHeight)
          context.saveGState()
          context.clip(to: row2Clip)
          let leavingY = row2Clip.minY - rowStride * eased
          drawRow(leavingSecond, at: leavingY, alpha: max(0.20, 1 - eased * 0.80))
          drawRow(frame.statusRows[1].line, at: leavingY + rowStride, alpha: 0.25 + eased * 0.75)
          drawEdgeFeather(in: row2Clip)
          context.restoreGState()
        } else {
          drawRow(frame.statusRows[1].line, at: rowTop + rowStride, alpha: 1)
        }
      case .full(let leaving):
        let clipRect = CGRect(x: 0, y: rowTop, width: clipWidth, height: 2 * rowHeight + rowGap)
        context.saveGState()
        context.clip(to: clipRect)
        let startY = rowTop - rowStride * eased
        drawRow(leaving, at: startY, alpha: max(0.22, 1 - eased * 0.75))
        for (offset, row) in frame.statusRows.enumerated() {
          let rowAlpha: CGFloat = (offset == frame.statusRows.count - 1) ? (0.25 + eased * 0.75) : 1
          drawRow(row.line, at: startY + CGFloat(offset + 1) * rowStride, alpha: rowAlpha)
        }
        drawEdgeFeather(in: clipRect)
        context.restoreGState()
      default:
        let startY = rowTop + (frame.statusRows.count == 1 ? rowStride / 2 : 0)
        for (offset, row) in frame.statusRows.enumerated() {
          drawRow(row.line, at: startY + CGFloat(offset) * rowStride)
        }
      }
    } else {
      let startY = rowTop + (frame.statusRows.count == 1 ? rowStride / 2 : 0)
      for (offset, row) in frame.statusRows.enumerated() {
        drawRow(row.line, at: startY + CGFloat(offset) * rowStride)
      }
      if frame.statusRows.count == 2,
        frame.statusRows[0].line.activity == .working, frame.statusRows[1].line.activity == .working {
        UIColor(white: 1, alpha: 0.065).setFill()
        UIBezierPath(rect: CGRect(x: nameX, y: 33.75, width: contentRight - nameX, height: 0.5)).fill()
      }
    }

    // MARK: Right-Edge 2pt Scroll Indicator (shown only when >2 active groups)
    func drawAnimatedThumb(
      trackTop: CGFloat, trackHeight: CGFloat, thumbHeight: CGFloat,
      prevFrac: CGFloat?, targetFrac: CGFloat, color: UIColor
    ) {
      let clampedTarget = min(1, max(0, targetFrac))
      let span = max(0, trackHeight - thumbHeight)
      if progress < 1, let rawPrev = prevFrac {
        let clampedPrev = min(1, max(0, rawPrev))
        if clampedTarget > clampedPrev + 0.001 {
          let frac = clampedPrev + (clampedTarget - clampedPrev) * eased
          color.setFill()
          UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: trackTop + span * frac, width: scrollRailW, height: thumbHeight), cornerRadius: 1).fill()
          return
        } else if clampedTarget < clampedPrev - 0.001 {
          // Wraparound back to top: crossfade leaving bottom thumb into entering top thumb.
          color.withAlphaComponent(color.cgColor.alpha * (1 - eased)).setFill()
          UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: trackTop + span * clampedPrev, width: scrollRailW, height: thumbHeight), cornerRadius: 1).fill()
          color.withAlphaComponent(color.cgColor.alpha * eased).setFill()
          UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: trackTop + span * clampedTarget, width: scrollRailW, height: thumbHeight), cornerRadius: 1).fill()
          return
        }
      }
      color.setFill()
      UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: trackTop + span * clampedTarget, width: scrollRailW, height: thumbHeight), cornerRadius: 1).fill()
    }

    if let scroll = frame.scrollState, scroll.activities.count > 2 {
      let fromScroll = transition?.fromScroll
      if scroll.pinsFirstRow, let pinnedActivity = scroll.activities.first {
        let pinColor = pinnedActivity == .needsDecision ? decisionRed : answerOrange
        pinColor.setFill()
        UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: 12, width: scrollRailW, height: 7), cornerRadius: 1).fill()

        let lowerTop: CGFloat = 24
        let lowerHeight: CGFloat = 32
        UIColor(white: 1, alpha: 0.12).setFill()
        UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: lowerTop, width: scrollRailW, height: lowerHeight), cornerRadius: 1).fill()

        let workingCount = max(2, scroll.activities.count - 1)
        let activeWorking = max(0, min(workingCount - 1, (scroll.activeIndices.dropFirst().first ?? 1) - 1))
        let thumbHeight = max(9, lowerHeight / CGFloat(workingCount))
        let targetFrac = CGFloat(activeWorking) / CGFloat(max(1, workingCount - 1))
        let prevFrac: CGFloat? = if let fromScroll, fromScroll.pinsFirstRow, fromScroll.activities.count == scroll.activities.count {
          CGFloat(max(0, min(workingCount - 1, (fromScroll.activeIndices.dropFirst().first ?? 1) - 1))) / CGFloat(max(1, workingCount - 1))
        } else {
          nil
        }
        drawAnimatedThumb(
          trackTop: lowerTop, trackHeight: lowerHeight, thumbHeight: thumbHeight,
          prevFrac: prevFrac, targetFrac: targetFrac, color: UIColor(white: 1, alpha: 0.72))
      } else if let splitAt = scroll.splitAt, splitAt >= 2, splitAt < scroll.activities.count {
        // Split-Zone Rail: Upper Attention track (y=12..31) + Lower Working track (y=37..56)
        let topTrackTop: CGFloat = 12
        let topTrackH: CGFloat = 19
        UIColor(white: 1, alpha: 0.12).setFill()
        UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: topTrackTop, width: scrollRailW, height: topTrackH), cornerRadius: 1).fill()

        let activeTop = max(0, min(splitAt - 1, scroll.activeIndices.first ?? 0))
        let topThumbH = max(6, topTrackH / CGFloat(splitAt))
        let topTargetFrac = CGFloat(activeTop) / CGFloat(max(1, splitAt - 1))
        let topPrevFrac: CGFloat? = if let fromScroll, fromScroll.splitAt == splitAt {
          CGFloat(max(0, min(splitAt - 1, fromScroll.activeIndices.first ?? 0))) / CGFloat(max(1, splitAt - 1))
        } else {
          nil
        }
        let topColor = scroll.activities[activeTop] == .needsDecision ? decisionRed : answerOrange
        drawAnimatedThumb(
          trackTop: topTrackTop, trackHeight: topTrackH, thumbHeight: topThumbH,
          prevFrac: topPrevFrac, targetFrac: topTargetFrac, color: topColor)

        let botTrackTop: CGFloat = 37
        let botTrackH: CGFloat = 19
        let workingCount = max(1, scroll.activities.count - splitAt)
        if workingCount == 1 {
          UIColor(white: 1, alpha: 0.42).setFill()
          UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: botTrackTop, width: scrollRailW, height: botTrackH), cornerRadius: 1).fill()
        } else {
          UIColor(white: 1, alpha: 0.12).setFill()
          UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: botTrackTop, width: scrollRailW, height: botTrackH), cornerRadius: 1).fill()
          let activeBot = max(0, min(workingCount - 1, (scroll.activeIndices.dropFirst().first ?? splitAt) - splitAt))
          let botThumbH = max(6, botTrackH / CGFloat(workingCount))
          let botTargetFrac = CGFloat(activeBot) / CGFloat(max(1, workingCount - 1))
          let botPrevFrac: CGFloat? = if let fromScroll, fromScroll.splitAt == splitAt, fromScroll.activities.count == scroll.activities.count {
            CGFloat(max(0, min(workingCount - 1, (fromScroll.activeIndices.dropFirst().first ?? splitAt) - splitAt)))
              / CGFloat(max(1, workingCount - 1))
          } else {
            nil
          }
          drawAnimatedThumb(
            trackTop: botTrackTop, trackHeight: botTrackH, thumbHeight: botThumbH,
            prevFrac: botPrevFrac, targetFrac: botTargetFrac, color: UIColor(white: 1, alpha: 0.72))
        }
      } else {
        let trackTop: CGFloat = 12
        let trackHeight: CGFloat = 44
        UIColor(white: 1, alpha: 0.11).setFill()
        UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: trackTop, width: scrollRailW, height: trackHeight), cornerRadius: 1).fill()

        let count = CGFloat(scroll.activities.count)
        let firstActive = CGFloat(scroll.activeIndices.first ?? 0)
        let thumbHeight = max(12, trackHeight * (2 / count))
        let maxAnchor = max(1, count - 1)
        let targetFrac = firstActive / maxAnchor
        let prevFrac: CGFloat? = if let fromScroll, !fromScroll.pinsFirstRow, fromScroll.splitAt == nil,
          fromScroll.activities.count == scroll.activities.count {
          CGFloat(fromScroll.activeIndices.first ?? 0) / maxAnchor
        } else {
          nil
        }
        drawAnimatedThumb(
          trackTop: trackTop, trackHeight: trackHeight, thumbHeight: thumbHeight,
          prevFrac: prevFrac, targetFrac: targetFrac, color: UIColor(white: 1, alpha: 0.68))

        let visibleSet = Set(scroll.activeIndices)
        for (idx, act) in scroll.activities.enumerated() where act != .working && !visibleSet.contains(idx) {
          let tickY = trackTop + (trackHeight - 4.5) * (CGFloat(idx) / max(1, count - 1))
          (act == .needsDecision ? decisionRed : answerOrange).setFill()
          UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: tickY, width: scrollRailW, height: 4.5), cornerRadius: 1).fill()
        }
      }
    }
  }
}
