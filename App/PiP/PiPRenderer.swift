import CoreMedia
import UIKit

/// Draws a `PiPFrame` into a video frame: the session's name and state across the top, then its newest
/// lines filling the rest from the bottom up, as a chat or terminal reads while it runs.
enum PiPRenderer {
  static func sampleBuffer(for frame: PiPFrame, size: CGSize) -> CMSampleBuffer? {
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
    draw(frame, in: CGRect(origin: .zero, size: size))
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
  static func image(for frame: PiPFrame, size: CGSize) -> UIImage? {
    UIGraphicsImageRenderer(size: size).image { _ in draw(frame, in: CGRect(origin: .zero, size: size)) }
  }

  private static let ground = UIColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1)
  private static let green = UIColor(red: 0.30, green: 0.80, blue: 0.47, alpha: 1)
  private static let amber = UIColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1)

  private static func draw(_ frame: PiPFrame, in bounds: CGRect) {
    (frame.terminal ? TerminalText.background : ground).setFill()
    UIRectFill(bounds)
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
}
