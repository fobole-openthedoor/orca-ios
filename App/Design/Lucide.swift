import UIKit

/// A Lucide icon: SVG elements in a 24×24 box, stroked with round caps and joins and no fill,
/// as lucide-react-native draws them. `size` and `strokeWidth` mean what they mean there.
struct Lucide: Hashable {
  enum Element: Hashable {
    case path(String)
    case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)
    case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat, ry: CGFloat)
    case line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
    case polyline(String)
    case polygon(String)
  }

  let name: String
  let elements: [Element]

  static func == (lhs: Lucide, rhs: Lucide) -> Bool { lhs.name == rhs.name }
  func hash(into hasher: inout Hasher) { hasher.combine(name) }

  /// The outline in the 24×24 viewBox.
  var path: CGPath {
    if let cached = Lucide.pathCache[name] { return cached }
    let path = CGMutablePath()
    for element in elements {
      switch element {
      case .path(let d):
        SVGPathParser.append(d, to: path)
      case .circle(let cx, let cy, let r):
        path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
      case .ellipse(let cx, let cy, let rx, let ry):
        path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
      case .rect(let x, let y, let width, let height, let rx, let ry):
        let rect = CGRect(x: x, y: y, width: width, height: height)
        if rx > 0 || ry > 0 {
          path.addRoundedRect(
            in: rect, cornerWidth: min(rx, width / 2), cornerHeight: min(ry, height / 2))
        } else {
          path.addRect(rect)
        }
      case .line(let x1, let y1, let x2, let y2):
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
      case .polyline(let points), .polygon(let points):
        let values = SVGPathParser.numbers(in: points)
        var index = 0
        while index + 1 < values.count {
          let point = CGPoint(x: values[index], y: values[index + 1])
          if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
          index += 2
        }
        if case .polygon = element { path.closeSubpath() }
      }
    }
    Lucide.pathCache[name] = path
    return path
  }

  nonisolated(unsafe) private static var pathCache: [String: CGPath] = [:]

  /// The icon as a template image, for buttons and image views.
  func image(size: CGFloat, strokeWidth: CGFloat = 2) -> UIImage {
    let format = UIGraphicsImageRendererFormat.preferred()
    let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image {
      context in
      let cg = context.cgContext
      cg.scaleBy(x: size / 24, y: size / 24)
      cg.addPath(path)
      cg.setLineWidth(strokeWidth)
      cg.setLineCap(.round)
      cg.setLineJoin(.round)
      cg.setStrokeColor(UIColor.black.cgColor)
      cg.strokePath()
    }
    return image.withRenderingMode(.alwaysTemplate)
  }
}

/// Draws a Lucide icon with a shape layer, so colour and stroke can animate and the glyph stays sharp at any scale.
final class LucideView: UIView {
  private let shape = CAShapeLayer()

  var icon: Lucide { didSet { setNeedsLayout() } }
  var strokeWidth: CGFloat { didSet { setNeedsLayout() } }
  var color: UIColor { didSet { updateColor() } }

  init(_ icon: Lucide, size: CGFloat, strokeWidth: CGFloat = 2, color: UIColor = Palette.textPrimary) {
    self.icon = icon
    self.strokeWidth = strokeWidth
    self.color = color
    super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
    shape.fillColor = nil
    shape.lineCap = .round
    shape.lineJoin = .round
    layer.addSublayer(shape)
    isUserInteractionEnabled = false
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
    ])
    updateColor()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = bounds.width / 24
    var transform = CGAffineTransform(scaleX: scale, y: scale)
    shape.frame = bounds
    shape.path = icon.path.copy(using: &transform)
    // The SVG stroke width is in viewBox units, so it scales with the icon.
    shape.lineWidth = strokeWidth * scale
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    updateColor()
  }

  private func updateColor() {
    shape.strokeColor = color.resolvedColor(with: traitCollection).cgColor
  }
}

/// SVG path data → CGPath, covering every command Lucide uses, arcs included.
enum SVGPathParser {
  static func numbers(in text: String) -> [CGFloat] {
    var scanner = NumberScanner(Array(text.utf8))
    var result: [CGFloat] = []
    while let value = scanner.next() { result.append(value) }
    return result
  }

  static func append(_ d: String, to path: CGMutablePath) {
    let bytes = Array(d.utf8)
    var scanner = NumberScanner(bytes)
    var current = CGPoint.zero
    var start = CGPoint.zero
    var lastControl: CGPoint?
    var lastCommand: UInt8 = 0

    func isCommand(_ byte: UInt8) -> Bool {
      switch byte {
      case UInt8(ascii: "e"), UInt8(ascii: "E"): return false
      default: return (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
      }
    }

    while let command = scanner.nextCommand(isCommand) {
      let relative = command >= 97
      let upper = relative ? command - 32 : command
      var first = true
      repeat {
        let origin = relative ? current : .zero
        switch upper {
        case UInt8(ascii: "M"):
          guard let x = scanner.next(), let y = scanner.next() else { break }
          let point = CGPoint(x: origin.x + x, y: origin.y + y)
          if first {
            path.move(to: point)
            start = point
          } else {
            path.addLine(to: point)
          }
          current = point
          lastControl = nil
        case UInt8(ascii: "L"):
          guard let x = scanner.next(), let y = scanner.next() else { break }
          current = CGPoint(x: origin.x + x, y: origin.y + y)
          path.addLine(to: current)
          lastControl = nil
        case UInt8(ascii: "H"):
          guard let x = scanner.next() else { break }
          current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
          path.addLine(to: current)
          lastControl = nil
        case UInt8(ascii: "V"):
          guard let y = scanner.next() else { break }
          current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
          path.addLine(to: current)
          lastControl = nil
        case UInt8(ascii: "C"):
          guard let x1 = scanner.next(), let y1 = scanner.next(), let x2 = scanner.next(),
            let y2 = scanner.next(), let x = scanner.next(), let y = scanner.next()
          else { break }
          let c1 = CGPoint(x: origin.x + x1, y: origin.y + y1)
          let c2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
          current = CGPoint(x: origin.x + x, y: origin.y + y)
          path.addCurve(to: current, control1: c1, control2: c2)
          lastControl = c2
        case UInt8(ascii: "S"):
          guard let x2 = scanner.next(), let y2 = scanner.next(), let x = scanner.next(),
            let y = scanner.next()
          else { break }
          let reflectsCubic = [UInt8(ascii: "C"), UInt8(ascii: "S")].contains(lastCommand)
          let c1 =
            reflectsCubic && lastControl != nil
            ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
          let c2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
          current = CGPoint(x: origin.x + x, y: origin.y + y)
          path.addCurve(to: current, control1: c1, control2: c2)
          lastControl = c2
        case UInt8(ascii: "Q"):
          guard let x1 = scanner.next(), let y1 = scanner.next(), let x = scanner.next(),
            let y = scanner.next()
          else { break }
          let control = CGPoint(x: origin.x + x1, y: origin.y + y1)
          current = CGPoint(x: origin.x + x, y: origin.y + y)
          path.addQuadCurve(to: current, control: control)
          lastControl = control
        case UInt8(ascii: "T"):
          guard let x = scanner.next(), let y = scanner.next() else { break }
          let reflectsQuad = [UInt8(ascii: "Q"), UInt8(ascii: "T")].contains(lastCommand)
          let control =
            reflectsQuad && lastControl != nil
            ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
          current = CGPoint(x: origin.x + x, y: origin.y + y)
          path.addQuadCurve(to: current, control: control)
          lastControl = control
        case UInt8(ascii: "A"):
          guard let rx = scanner.next(), let ry = scanner.next(), let rotation = scanner.next(),
            let largeArc = scanner.nextFlag(), let sweep = scanner.nextFlag(), let x = scanner.next(),
            let y = scanner.next()
          else { break }
          let end = CGPoint(x: origin.x + x, y: origin.y + y)
          addArc(
            to: path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc,
            sweep: sweep)
          current = end
          lastControl = nil
        case UInt8(ascii: "Z"):
          path.closeSubpath()
          current = start
          lastControl = nil
        default:
          break
        }
        lastCommand = upper
        first = false
      } while upper != UInt8(ascii: "Z") && scanner.hasNumberAhead()
    }
  }

  /// The SVG endpoint arc (F.6.5), drawn as cubic Béziers of at most 90° each.
  private static func addArc(
    to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
    rotation: CGFloat, largeArc: Bool, sweep: Bool
  ) {
    var rx = abs(rxIn)
    var ry = abs(ryIn)
    if rx == 0 || ry == 0 || p0 == p1 {
      path.addLine(to: p1)
      return
    }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2
    let dy = (p0.y - p1.y) / 2
    let x1p = cosPhi * dx + sinPhi * dy
    let y1p = -sinPhi * dx + cosPhi * dy
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 {
      rx *= sqrt(lambda)
      ry *= sqrt(lambda)
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    var factor = sqrt(max(0, numerator / denominator))
    if largeArc == sweep { factor = -factor }
    let cxp = factor * rx * y1p / ry
    let cyp = -factor * ry * x1p / rx
    let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
    let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      let dot = ux * vx + uy * vy
      let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
      var result = acos(max(-1, min(1, dot / length)))
      if ux * vy - uy * vx < 0 { result = -result }
      return result
    }
    let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi }
    if sweep && delta < 0 { delta += 2 * .pi }

    let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
    let step = delta / CGFloat(segments)
    let kappa = 4 / 3 * tan(step / 4)
    var theta = theta1
    func point(_ t: CGFloat) -> CGPoint {
      CGPoint(
        x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
        y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
    }
    func derivative(_ t: CGFloat) -> CGPoint {
      CGPoint(
        x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
        y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
    }
    for _ in 0..<segments {
      let next = theta + step
      let a = point(theta)
      let b = point(next)
      let da = derivative(theta)
      let db = derivative(next)
      path.addCurve(
        to: b,
        control1: CGPoint(x: a.x + kappa * da.x, y: a.y + kappa * da.y),
        control2: CGPoint(x: b.x - kappa * db.x, y: b.y - kappa * db.y))
      theta = next
    }
  }
}

/// Reads SVG numbers, which may run together ("1.5.5", "-1-2") and flags, which may be a single digit.
private struct NumberScanner {
  private let bytes: [UInt8]
  private var index = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  private mutating func skipSeparators() {
    while index < bytes.count,
      bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",")
        || bytes[index] == 10 || bytes[index] == 9 || bytes[index] == 13
    {
      index += 1
    }
  }

  mutating func nextCommand(_ isCommand: (UInt8) -> Bool) -> UInt8? {
    skipSeparators()
    guard index < bytes.count, isCommand(bytes[index]) else {
      return nil
    }
    defer { index += 1 }
    return bytes[index]
  }

  func hasNumberAhead() -> Bool {
    var probe = index
    while probe < bytes.count,
      bytes[probe] == UInt8(ascii: " ") || bytes[probe] == UInt8(ascii: ",")
    {
      probe += 1
    }
    guard probe < bytes.count else { return false }
    let byte = bytes[probe]
    return (byte >= 48 && byte <= 57) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")
      || byte == UInt8(ascii: ".")
  }

  mutating func nextFlag() -> Bool? {
    skipSeparators()
    guard index < bytes.count else { return nil }
    let byte = bytes[index]
    guard byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else { return nil }
    index += 1
    return byte == UInt8(ascii: "1")
  }

  mutating func next() -> CGFloat? {
    skipSeparators()
    guard index < bytes.count else { return nil }
    let begin = index
    if bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
    var sawDot = false
    var sawDigit = false
    while index < bytes.count {
      let byte = bytes[index]
      if byte >= 48 && byte <= 57 {
        sawDigit = true
        index += 1
      } else if byte == UInt8(ascii: ".") && !sawDot {
        sawDot = true
        index += 1
      } else if (byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")) && sawDigit {
        index += 1
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
          index += 1
        }
      } else {
        break
      }
    }
    guard sawDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii),
      let value = Double(text)
    else {
      index = begin
      return nil
    }
    return CGFloat(value)
  }
}
