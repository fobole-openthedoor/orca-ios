// Puts an official screenshot, ours, and their difference side by side, and prints how many pixels differ.
// Usage: swift scripts/compare.swift <official.png> <ours.png> <out.png> [--crop-top <px>]
// The status bar differs between runs (clock, the back-to-app chip), so the top 150 px are ignored by default.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
  FileHandle.standardError.write("usage: compare.swift <official.png> <ours.png> <out.png> [--crop-top px]\n".data(using: .utf8)!)
  exit(1)
}
var cropTop = 150
if let index = arguments.firstIndex(of: "--crop-top"), index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
  cropTop = value
}

func load(_ path: String) -> CGImage {
  guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
  else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(1)
  }
  return cg
}

func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
  var data = [UInt8](repeating: 0, count: width * height * 4)
  let context = CGContext(
    data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return data
}

let official = load(arguments[1])
let ours = load(arguments[2])
let width = official.width
let height = official.height
let a = pixels(official, width: width, height: height)
let b = pixels(ours, width: width, height: height)
var diff = [UInt8](repeating: 0, count: width * height * 4)
var differing = 0
var compared = 0
for y in 0..<height {
  // CGContext rows run bottom-up.
  let fromTop = height - 1 - y
  for x in 0..<width {
    let i = (y * width + x) * 4
    let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
    let counted = fromTop >= cropTop
    if counted { compared += 1 }
    if counted && delta > 24 {
      differing += 1
      diff[i] = 255
      diff[i + 1] = 0
      diff[i + 2] = 64
      diff[i + 3] = 255
    } else {
      // Ours, faded, so the red marks read against the layout.
      diff[i] = UInt8(255 - (255 - Int(b[i])) / 4)
      diff[i + 1] = UInt8(255 - (255 - Int(b[i + 1])) / 4)
      diff[i + 2] = UInt8(255 - (255 - Int(b[i + 2])) / 4)
      diff[i + 3] = 255
    }
  }
}

let gap = 24
let out = CGContext(
  data: nil, width: width * 3 + gap * 2, height: height, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
out.fill(CGRect(x: 0, y: 0, width: width * 3 + gap * 2, height: height))
out.draw(official, in: CGRect(x: 0, y: 0, width: width, height: height))
out.draw(ours, in: CGRect(x: width + gap, y: 0, width: width, height: height))
let diffContext = CGContext(
  data: &diff, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.draw(diffContext.makeImage()!, in: CGRect(x: (width + gap) * 2, y: 0, width: width, height: height))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[3]))
print(String(format: "%.2f%% of pixels differ (%d of %d)", Double(differing) * 100 / Double(compared), differing, compared))
