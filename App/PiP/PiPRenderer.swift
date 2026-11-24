import CoreMedia
import UIKit

/// Draws a `PiPFrame` into a video frame: the session's name and state across the top, then its newest
/// lines filling the rest from the bottom up, as a chat or terminal reads while it runs.
enum PiPRenderer {
  static func sampleBuffer(
    for frame: PiPFrame, layout: PiPLayout, leaving: PiPFrame.StatusLine? = nil, progress: CGFloat = 1
  ) -> CMSampleBuffer? {
    let size = layout.size
    let scale: CGFloat = 2
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
    draw(frame, layout: layout, leaving: leaving, progress: progress)
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
    UIGraphicsImageRenderer(size: layout.size).image { _ in draw(frame, layout: layout) }
  }

  private static let ground = UIColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1)
  private static let green = UIColor(red: 0.30, green: 0.80, blue: 0.47, alpha: 1)
  private static let amber = UIColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1)

  private static func draw(
    _ frame: PiPFrame, layout: PiPLayout, leaving: PiPFrame.StatusLine? = nil, progress: CGFloat = 1
  ) {
    let bounds = CGRect(origin: .zero, size: layout.size)
    (frame.terminal ? TerminalText.background : ground).setFill()
    UIRectFill(bounds)
    if layout == .compact {
      drawCompact(frame, in: bounds, leaving: leaving, progress: progress)
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

  private static func drawCompact(_ frame: PiPFrame, in bounds: CGRect, leaving: PiPFrame.StatusLine?, progress: CGFloat) {
    let padding: CGFloat = 9
    let labelX = padding + 12
    let right = bounds.maxX - padding
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let middle = NSMutableParagraphStyle()
    middle.lineBreakMode = .byTruncatingMiddle
    func label(_ text: String, font: UIFont, color: UIColor, truncation: NSParagraphStyle? = nil) -> NSAttributedString {
      NSAttributedString(
        string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: truncation ?? paragraph])
    }
    func dot(at y: CGFloat, color: UIColor) {
      color.setFill()
      UIBezierPath(ovalIn: CGRect(x: padding, y: y, width: 7, height: 7)).fill()
    }
    if frame.statusRows.isEmpty {
      dot(at: bounds.midY - 4, color: green)
      label(frame.title, font: .systemFont(ofSize: 21, weight: .medium), color: .white)
        .draw(in: CGRect(x: labelX, y: bounds.midY - 13, width: right - labelX, height: 28))
      return
    }

    let muted = UIColor(white: 1, alpha: 0.58)
    let summaryWidth: CGFloat = 38
    let dividerX = right - summaryWidth - 5
    let rowHeight: CGFloat = 27
    let firstY = (bounds.height - 2 * rowHeight) / 2
    let metricsFont = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    func metric(_ text: String, color: UIColor, width: CGFloat) -> NSAttributedString {
      let normal = label(text, font: metricsFont, color: color)
      let scale = min(1, (width - 2) / max(1, ceil(normal.size().width)))
      return scale < 1 ? label(text, font: metricsFont.withSize(metricsFont.pointSize * scale), color: color) : normal
    }
    func symbol(_ name: String, color: UIColor, at x: CGFloat, y: CGFloat, width: CGFloat) {
      UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: width, weight: .medium))?
        .withTintColor(color, renderingMode: .alwaysOriginal)
        .draw(in: CGRect(x: x, y: y, width: width, height: 10))
    }
    if let counts = frame.fleetCounts {
      let totals = [(counts.agents, "person.2.fill", amber), (counts.hosts, "desktopcomputer", muted)]
      for (offset, total) in totals.enumerated() {
        let y = firstY + CGFloat(offset) * rowHeight
        let stat = metric(String(total.0), color: total.2, width: summaryWidth - 15)
        let width = min(summaryWidth - 15, ceil(stat.size().width) + 1)
        symbol(total.1, color: total.2, at: right - width - 15, y: y + 7, width: 12)
        stat.draw(in: CGRect(x: right - width, y: y + 4, width: width, height: 23))
      }
    }
    UIColor(white: 1, alpha: 0.15).setFill()
    UIBezierPath(rect: CGRect(x: dividerX, y: firstY + 1, width: 1, height: 2 * rowHeight - 2)).fill()

    let agentsRight = dividerX - 7
    let toolWidth: CGFloat = 42
    let tokenWidth: CGFloat = 54
    let namesRight = agentsRight - toolWidth - tokenWidth - 8
    let markSize: CGFloat = 16
    let nameFont = UIFont.systemFont(ofSize: 16, weight: .medium, width: .condensed)
    let nameColor = UIColor(white: 1, alpha: 0.94)
    func drawRow(_ row: PiPFrame.StatusLine, at y: CGFloat) {
      let role: Lucide? = switch row.agentRole {
      case .subagent: .cornerDownRight
      case .worker: .workflow
      case nil: nil
      }
      dot(at: y + (role == nil ? 9 : 5), color: amber)
      if let role {
        role.image(size: 9).withTintColor(muted, renderingMode: .alwaysOriginal)
          .draw(in: CGRect(x: padding - 1, y: y + 14, width: 9, height: 9))
      }
      let host = label(row.host, font: .systemFont(ofSize: 13, weight: .medium),
        color: muted.withAlphaComponent(0.7), truncation: middle)
      let hostWidth = min(ceil(host.size().width), (namesRight - labelX) * 0.32)
      let hostX = namesRight - hostWidth
      host.draw(in: CGRect(x: hostX, y: y + 4, width: hostWidth, height: 24))
      let mark = AgentMark.icon(for: row.agentType)
      let icon = mark?.image(size: markSize) ?? Lucide.bot.image(size: markSize)
      let renderedIcon = mark?.color == nil ? icon.withTintColor(.white, renderingMode: .alwaysOriginal) : icon
      renderedIcon.draw(in: CGRect(x: labelX, y: y + 4, width: markSize, height: markSize))
      let nameX = labelX + markSize + 4
      let name = label(row.agent, font: nameFont, color: nameColor, truncation: middle)
      name.draw(in: CGRect(x: nameX, y: y + 3, width: max(0, hostX - nameX - 6), height: 25))

      let tokenColor = UIColor(white: 1, alpha: row.totalTokens == nil ? 0.4 : 0.84)
      let tokenText = row.totalTokens.map { ChatDockView.compact($0, millionDigits: 2) } ?? "—"
      let tokens = metric(tokenText, color: tokenColor, width: tokenWidth - 4)
      let tokenSize = min(tokenWidth - 4, ceil(tokens.size().width) + 1)
      tokens.draw(in: CGRect(x: agentsRight - toolWidth - tokenSize - 4, y: y + 4, width: tokenSize, height: 23))
      let toolColor = row.toolRunning ? amber : UIColor(white: 1, alpha: row.toolCount == nil ? 0.45 : 0.8)
      let call = metric(row.toolCount ?? "—", color: toolColor, width: toolWidth - 14)
      let callSize = min(toolWidth - 14, ceil(call.size().width) + 1)
      call.draw(in: CGRect(x: agentsRight - callSize, y: y + 4, width: callSize, height: 23))
      symbol("wrench.fill", color: toolColor, at: agentsRight - callSize - 13, y: y + 7, width: 10)
    }

    // Only the agent columns scroll. Clip them at the two row edges and leave the fleet summary fixed.
    if let leaving, progress < 1, let context = UIGraphicsGetCurrentContext() {
      context.saveGState()
      context.clip(to: CGRect(x: 0, y: firstY, width: dividerX, height: 2 * rowHeight))
      let eased = progress * progress * (3 - 2 * progress)
      let start = firstY - rowHeight * eased
      drawRow(leaving, at: start)
      for (offset, row) in frame.statusRows.enumerated() {
        drawRow(row.line, at: start + CGFloat(offset + 1) * rowHeight)
      }
      context.restoreGState()
    } else {
      let start = firstY + (frame.statusRows.count == 1 ? rowHeight / 2 : 0)
      for (offset, row) in frame.statusRows.enumerated() {
        drawRow(row.line, at: start + CGFloat(offset) * rowHeight)
      }
    }
  }
}
