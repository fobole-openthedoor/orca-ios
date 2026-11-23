import CoreMedia
import UIKit

/// Draws a `PiPFrame` into a video frame: the session's name and state across the top, then its newest
/// lines filling the rest from the bottom up, as a chat or terminal reads while it runs.
enum PiPRenderer {
  static func sampleBuffer(
    for frame: PiPFrame, layout: PiPLayout, previous: [PiPFrame.StatusLine]? = nil, progress: CGFloat = 1
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
    draw(frame, layout: layout, previous: previous, progress: progress)
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
    _ frame: PiPFrame, layout: PiPLayout, previous: [PiPFrame.StatusLine]? = nil, progress: CGFloat = 1
  ) {
    let bounds = CGRect(origin: .zero, size: layout.size)
    (frame.terminal ? TerminalText.background : ground).setFill()
    UIRectFill(bounds)
    if layout == .compact {
      drawCompact(frame, in: bounds, previous: previous, progress: progress)
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

  private static func drawCompact(_ frame: PiPFrame, in bounds: CGRect, previous: [PiPFrame.StatusLine]?, progress: CGFloat) {
    let padding: CGFloat = 17
    let labelX = padding + 15
    let right = bounds.maxX - padding
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let middle = NSMutableParagraphStyle()
    middle.lineBreakMode = .byTruncatingMiddle
    let head = NSMutableParagraphStyle()
    head.lineBreakMode = .byTruncatingHead
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
    let dividerX = right - summaryWidth - 11
    let firstY: CGFloat = 21
    let rowHeight: CGFloat = 37
    let metricsFont = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    func metric(_ text: String, color: UIColor, width: CGFloat) -> NSAttributedString {
      let normal = label(text, font: metricsFont, color: color)
      let scale = min(1, (width - 2) / max(1, ceil(normal.size().width)))
      return scale < 1 ? label(text, font: metricsFont.withSize(metricsFont.pointSize * scale), color: color) : normal
    }
    func symbol(_ name: String, color: UIColor, at x: CGFloat, y: CGFloat, width: CGFloat, alpha: CGFloat = 1) {
      UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: width, weight: .medium))?
        .withTintColor(color, renderingMode: .alwaysOriginal)
        .draw(in: CGRect(x: x, y: y, width: width, height: 10), blendMode: .normal, alpha: alpha)
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
    UIBezierPath(rect: CGRect(x: dividerX, y: firstY, width: 1, height: 62)).fill()

    // Fade the page together. The summary stays readable throughout.
    let rows = progress < 0.5 ? previous ?? frame.statusRows : frame.statusRows
    let alpha = previous == nil ? 1 : abs(progress * 2 - 1)
    let agentsRight = dividerX - 10
    let toolWidth: CGFloat = 42
    let rateWidth: CGFloat = 60
    let namesRight = agentsRight - toolWidth - rateWidth - 8
    for (offset, row) in rows.enumerated() {
      let y = firstY + CGFloat(offset) * rowHeight
      dot(at: y + 9, color: amber.withAlphaComponent(alpha))
      let host = label(row.host, font: .systemFont(ofSize: 13, weight: .medium),
        color: muted.withAlphaComponent(0.7 * alpha), truncation: middle)
      let hostWidth = min(ceil(host.size().width), (namesRight - labelX) * 0.32)
      let hostX = namesRight - hostWidth
      host.draw(in: CGRect(x: hostX, y: y + 4, width: hostWidth, height: 24))
      let nameColor = UIColor(white: 1, alpha: 0.94 * alpha)
      let nameFont = UIFont.systemFont(ofSize: 17, weight: .medium)
      let name = label(row.agent, font: nameFont, color: nameColor, truncation: middle)
      let nameWidth = max(0, hostX - labelX - 7)
      var nameRect = CGRect(x: labelX, y: y + 2, width: nameWidth, height: 26)
      if name.size().width > nameWidth, let separator = row.agent.range(of: " · ") {
        let provider = label(String(row.agent[..<separator.lowerBound]), font: nameFont, color: nameColor)
        let providerWidth = ceil(provider.size().width) + 3
        if providerWidth < nameWidth * 0.75 {
          provider.draw(in: CGRect(x: labelX, y: y + 2, width: providerWidth, height: 26))
          nameRect.origin.x += providerWidth
          nameRect.size.width -= providerWidth
          label(String(row.agent[separator.lowerBound...]), font: nameFont, color: nameColor, truncation: head).draw(in: nameRect)
        } else {
          name.draw(in: nameRect)
        }
      } else {
        name.draw(in: nameRect)
      }

      let rateX = namesRight + 8
      let hasOutput = (row.rate ?? 0) > 0
      let rateColor = hasOutput ? green.withAlphaComponent(0.94 * alpha) : muted.withAlphaComponent(0.58 * alpha)
      let rate = metric(row.rate.map { "≈\($0) t/s" } ?? "—", color: rateColor, width: rateWidth - 4)
      let rateSize = min(rateWidth - 4, ceil(rate.size().width) + 1)
      rate.draw(in: CGRect(x: rateX + rateWidth - rateSize - 4, y: y + 4, width: rateSize, height: 23))
      let toolColor = row.toolRunning ? amber : UIColor(white: 1, alpha: row.toolCount == nil ? 0.45 : 0.8)
      let call = metric(row.toolCount ?? "—", color: toolColor.withAlphaComponent(toolColor.cgColor.alpha * alpha), width: toolWidth - 14)
      let callSize = min(toolWidth - 14, ceil(call.size().width) + 1)
      call.draw(in: CGRect(x: agentsRight - callSize, y: y + 4, width: callSize, height: 23))
      symbol("wrench.fill", color: toolColor, at: agentsRight - callSize - 13, y: y + 7, width: 10, alpha: alpha)
    }
  }
}
