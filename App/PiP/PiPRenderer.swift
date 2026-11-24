import CoreMedia
import CoreText
import UIKit

/// Draws a session transcript or a two-row agent status strip into a picture-in-picture frame.
enum PiPRenderer {
  static func sampleBuffer(
    for frame: PiPFrame, layout: PiPLayout, leaving: PiPFrame.StatusLine? = nil,
    onlySecondRow: Bool = false, progress: CGFloat = 1
  ) -> CMSampleBuffer? {
    let size = layout.size
    let scale: CGFloat = layout == .compact ? 3 : 2
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    guard
      CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        == kCVReturnSuccess, let pixelBuffer
    else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    // UIKit drawing, top-left origin, in points.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    UIGraphicsPushContext(context)
    draw(frame, layout: layout, leaving: leaving, onlySecondRow: onlySecondRow, progress: progress)
    UIGraphicsPopContext()

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
  static func image(for frame: PiPFrame, layout: PiPLayout) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    if layout == .compact {
      format.scale = 3
      format.opaque = true
    }
    return UIGraphicsImageRenderer(size: layout.size, format: format).image { _ in
      draw(frame, layout: layout)
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

  private static func draw(
    _ frame: PiPFrame, layout: PiPLayout, leaving: PiPFrame.StatusLine? = nil,
    onlySecondRow: Bool = false, progress: CGFloat = 1
  ) {
    let bounds = CGRect(origin: .zero, size: layout.size)
    let background = layout == .compact ? compactGround : frame.terminal ? TerminalText.background : ground
    background.setFill()
    UIRectFill(bounds)
    if layout == .compact {
      drawCompact(frame, in: bounds, leaving: leaving, onlySecondRow: onlySecondRow, progress: progress)
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
    _ frame: PiPFrame, in bounds: CGRect, leaving: PiPFrame.StatusLine?,
    onlySecondRow: Bool, progress: CGFloat
  ) {
    guard let context = UIGraphicsGetCurrentContext() else { return }

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
      let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
      guard let image = UIImage(systemName: name, withConfiguration: config)?
        .withTintColor(color, renderingMode: .alwaysOriginal) else { return pointSize }
      let size = image.size
      image.draw(in: CGRect(x: centerX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height))
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
    let stackRight: CGFloat = 315
    let rightBlockWidth: CGFloat = 58
    let contentRight: CGFloat = 386
    let scrollRailX: CGFloat = 393.5
    let scrollRailW: CGFloat = 2.0
    let coinSize: CGFloat = 15
    let coinStep: CGFloat = 10.5

    let hasRail = (frame.scrollState?.activities.count ?? 0) > 2

    let nameSingleFont = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
    let nameStackedFont = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    let hostSubFont = UIFont.systemFont(ofSize: 10.0, weight: .medium)
    let tokFont = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    let toolFont = UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
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

    func drawTokenLine(_ attr: NSAttributedString, atMidY midY: CGFloat) {
      let measured = measureAttr(attr)
      if measured > rightBlockWidth {
        let scale = rightBlockWidth / measured
        let scaledFont = UIFont.monospacedDigitSystemFont(ofSize: tokFont.pointSize * scale, weight: .semibold)
        let scaled = NSMutableAttributedString(attributedString: attr)
        scaled.addAttribute(.font, value: scaledFont, range: NSRange(location: 0, length: scaled.length))
        drawText(scaled, font: scaledFont, atX: contentRight, midY: midY, alignRight: true)
      } else {
        drawText(attr, font: tokFont, atX: contentRight, midY: midY, alignRight: true)
      }
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
        let cardRight: CGFloat = hasRail ? 389.0 : 395.5
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

      // 2. Lead Brand Logo (18×18) + Docked Presence Dot (working rows only; attention rows use left bar)
      let leadRect = CGRect(x: leadLogoX, y: midY - leadLogoSize / 2, width: leadLogoSize, height: leadLogoSize)
      let leadBackdrop = AgentMark.overlayBackdrop(for: row.agentType)
      context.saveGState()
      if leadBackdrop != .transparent {
        UIBezierPath(roundedRect: leadRect, cornerRadius: 4).addClip()
      }
      AgentMark.overlayImage(for: row.agentType, size: leadLogoSize).draw(in: leadRect)
      context.restoreGState()

      if !isAttention {
        let center = CGPoint(x: leadRect.maxX - 1.5, y: leadRect.maxY - 2.0)
        cutoutBg.setFill()
        UIBezierPath(ovalIn: CGRect(x: center.x - 3.6, y: center.y - 3.6, width: 7.2, height: 7.2)).fill()
        if row.leadWorking {
          compactAmber.setFill()
          UIBezierPath(ovalIn: CGRect(x: center.x - 2.4, y: center.y - 2.4, width: 4.8, height: 4.8)).fill()
        } else {
          compactAmber.withAlphaComponent(0.78).setStroke()
          let ring = UIBezierPath(ovalIn: CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4))
          ring.lineWidth = 1.2
          ring.stroke()
        }
      }

      // 3. Far-Right 58pt Column (Style 3: Token + semantic glyph on attention; Token + tools on working)
      let topMidY = midY - 6.0
      let botMidY = midY + 6.9
      if isAttention {
        let isDecision = row.activity == .needsDecision
        let glyphName = isDecision ? "hand.raised.fill" : "questionmark.bubble.fill"
        let glyphColor = isDecision ? decisionGlyph : answerGlyph
        if let tokenAttr = tokenAttributed(row, dimmed: true) {
          drawTokenLine(tokenAttr, atMidY: topMidY)
          drawSymbol(glyphName, pointSize: 10.5, weight: .semibold, color: glyphColor, centerX: contentRight - 6.5, centerY: botMidY)
        } else {
          // No token telemetry available on this attention row (e.g. terminal): center the status glyph cleanly.
          drawSymbol(glyphName, pointSize: 14.0, weight: .semibold, color: glyphColor, centerX: contentRight - 8.0, centerY: midY)
        }
      } else {
        if let tokenAttr = tokenAttributed(row, dimmed: false) {
          drawTokenLine(tokenAttr, atMidY: topMidY)
        } else {
          drawText(makeAttr("—", font: tokFont, color: UIColor(white: 1, alpha: 0.28)), font: tokFont, atX: contentRight, midY: topMidY, alignRight: true)
        }
        let toolText = row.toolCount ?? "—"
        let hasTool = row.toolCount != nil
        let textColor = row.toolRunning ? compactAmber.withAlphaComponent(0.92) : UIColor(white: 1, alpha: hasTool ? 0.56 : 0.26)
        let iconColor = row.toolRunning ? compactAmber.withAlphaComponent(0.86) : UIColor(white: 1, alpha: hasTool ? 0.40 : 0.22)
        let toolAttr = NSMutableAttributedString()
        if toolText.hasPrefix("≥") {
          toolAttr.append(makeAttr("≥", font: toolFont, color: textColor.withAlphaComponent(row.toolRunning ? 0.72 : 0.44)))
          toolAttr.append(makeAttr(String(toolText.dropFirst()), font: toolFont, color: textColor))
        } else {
          toolAttr.append(makeAttr(toolText, font: toolFont, color: textColor))
        }
        let toolW = drawText(toolAttr, font: toolFont, atX: contentRight, midY: botMidY, alignRight: true)
        drawSymbol("wrench.fill", pointSize: 7.8, weight: .medium, color: iconColor, centerX: contentRight - toolW - 5.5, centerY: botMidY)
      }

      // 4. Optional inline Worker glyph (zero conflict with working presence dot or attention bar)
      var effectiveNameX = nameX
      if row.isWorker {
        let iconMidY = row.showsHostSubtitle ? (midY - 5.8) : midY
        drawSymbol(
          "arrow.triangle.branch", pointSize: 8.8, weight: .semibold,
          color: UIColor(white: 1, alpha: 0.44), centerX: effectiveNameX + 4.5, centerY: iconMidY)
        effectiveNameX += 12.5
      }

      // 5. Right-Aligned Subagent Brand Stack (spine permanently locked at x = 315)
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
      }

      // 6. Primary Identity (Single-line default; 2-line with quiet host ONLY on cross-host same-name conflict)
      let nameRightLimit = stack.visible.isEmpty ? stackRight : (stackStartX - 12)
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
      if let topGrad = CGGradient(
        colorsSpace: cs, colors: [compactGround.withAlphaComponent(0.75).cgColor, compactGround.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]) {
        context.drawLinearGradient(topGrad, start: CGPoint(x: 0, y: clipRect.minY), end: CGPoint(x: 0, y: clipRect.minY + 4), options: [])
      }
      if let botGrad = CGGradient(
        colorsSpace: cs, colors: [compactGround.withAlphaComponent(0).cgColor, compactGround.withAlphaComponent(0.75).cgColor] as CFArray,
        locations: [0, 1]) {
        context.drawLinearGradient(botGrad, start: CGPoint(x: 0, y: clipRect.maxY - 4), end: CGPoint(x: 0, y: clipRect.maxY), options: [])
      }
    }

    // MARK: Row Rendering + Scrolling Transitions
    let eased = progress * progress * (3 - 2 * progress)
    if let leaving, progress < 1, onlySecondRow, frame.statusRows.count == 2 {
      // Pin-1-Attention in Row 1 + independent Row 2 scrolling inside lower 29pt clip rect.
      drawRow(frame.statusRows[0].line, at: rowTop, alpha: 1)
      let row2Clip = CGRect(x: 0, y: rowTop + rowStride, width: hasRail ? 389 : bounds.width, height: rowHeight)
      context.saveGState()
      context.clip(to: row2Clip)
      let leavingY = row2Clip.minY - rowStride * eased
      drawRow(leaving, at: leavingY, alpha: max(0.20, 1 - eased * 0.80))
      drawRow(frame.statusRows[1].line, at: leavingY + rowStride, alpha: 0.25 + eased * 0.75)
      drawEdgeFeather(in: row2Clip)
      context.restoreGState()
    } else if let leaving, progress < 1 {
      // Full-height 2-row scroll (0 or >=2 attention groups).
      let clipRect = CGRect(x: 0, y: rowTop, width: hasRail ? 389 : bounds.width, height: 2 * rowHeight + rowGap)
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
    if let scroll = frame.scrollState, scroll.activities.count > 2 {
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
        let displayFrac: CGFloat
        if progress < 1 && activeWorking > 0 {
          let prevFrac = CGFloat(activeWorking - 1) / CGFloat(max(1, workingCount - 1))
          displayFrac = prevFrac + (targetFrac - prevFrac) * eased
        } else {
          displayFrac = targetFrac
        }
        let thumbY = lowerTop + (lowerHeight - thumbHeight) * min(1, max(0, displayFrac))
        UIColor(white: 1, alpha: 0.72).setFill()
        UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: thumbY, width: scrollRailW, height: thumbHeight), cornerRadius: 1).fill()
      } else {
        let trackTop: CGFloat = 12
        let trackHeight: CGFloat = 44
        UIColor(white: 1, alpha: 0.11).setFill()
        UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: trackTop, width: scrollRailW, height: trackHeight), cornerRadius: 1).fill()

        let count = CGFloat(scroll.activities.count)
        let firstActive = CGFloat(scroll.activeIndices.first ?? 0)
        let thumbHeight = max(12, trackHeight * (2 / count))
        let maxAnchor = max(1, count - 1)
        let thumbY = trackTop + (trackHeight - thumbHeight) * min(1, firstActive / maxAnchor)
        UIColor(white: 1, alpha: 0.68).setFill()
        UIBezierPath(roundedRect: CGRect(x: scrollRailX, y: thumbY, width: scrollRailW, height: thumbHeight), cornerRadius: 1).fill()

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
