import AVFoundation
import ImageIO
import OrcaCore
import UIKit
import UniformTypeIdentifiers

/// Turns what the user pastes, drops or picks into attachments. Every source ends up here.
enum AttachmentIntake {
  /// At or past either bound, pasted text becomes a file instead of flooding the composer.
  static let longTextCharacters = 2000
  static let longTextLines = 15

  static func shouldPromotePastedText(_ text: String) -> Bool {
    text.count >= longTextCharacters || text.split(separator: "\n", omittingEmptySubsequences: false).count > longTextLines
  }

  /// Whether any provider carries a file or an image, decided without reading the pasteboard's contents.
  static func canAttach(_ providers: [NSItemProvider]) -> Bool {
    providers.contains { transferType(for: $0) != nil }
  }

  /// The type to load a provider as, or nil when it is text and belongs in the editor.
  static func transferType(for provider: NSItemProvider) -> UTType? {
    let types = provider.registeredContentTypes
    if let image = types.first(where: { $0.conforms(to: .image) }) {
      return image
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      return .image
    }
    // Safari selections and copied links are text, whatever else rides along.
    if types.contains(where: { $0.conforms(to: .webArchive) }) {
      return nil
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      return .fileURL
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      return nil
    }
    // UIKit synthesises RTF beside copied HTML; without these exclusions a copied paragraph would arrive as a file.
    return types.first { type in
      !type.conforms(to: .directory) && !type.conforms(to: .url) && !type.conforms(to: .text)
        && !type.conforms(to: .rtf) && !type.conforms(to: .rtfd) && !type.conforms(to: .flatRTFD)
        && !type.conforms(to: .webArchive) && type.conforms(to: .data)
    }
  }

  /// Loads every attachable provider, keeping pasteboard order.
  static func load(_ providers: [NSItemProvider]) async -> [OutgoingAttachment] {
    var loaded: [(Int, OutgoingAttachment)] = []
    await withTaskGroup(of: (Int, OutgoingAttachment?).self) { group in
      for (index, provider) in providers.enumerated() {
        guard let type = transferType(for: provider) else {
          continue
        }
        group.addTask {
          (index, await load(provider, as: type))
        }
      }
      for await (index, attachment) in group {
        if let attachment {
          loaded.append((index, attachment))
        }
      }
    }
    return loaded.sorted { $0.0 < $1.0 }.map(\.1)
  }

  private static func load(_ provider: NSItemProvider, as type: UTType) async -> OutgoingAttachment? {
    if type == .fileURL {
      let url: URL? = await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
          continuation.resume(returning: object as? URL)
        }
      }
      return url.flatMap { attachment(fromFile: $0, suggestedName: provider.suggestedName) }
    }
    return await withCheckedContinuation { continuation in
      // The URL handed over is only valid inside this callback, so the bytes are read here.
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        continuation.resume(returning: url.flatMap { attachment(fromFile: $0, suggestedName: provider.suggestedName, type: type) })
      }
    }
  }

  static func attachment(fromFile url: URL, suggestedName: String? = nil, type: UTType? = nil) -> OutgoingAttachment? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        url.stopAccessingSecurityScopedResource()
      }
    }
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
      let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= AttachmentLimits.maxFileBytes
    else {
      return nil
    }
    let resolved = type ?? UTType(filenameExtension: url.pathExtension) ?? .data
    var name = suggestedName ?? url.lastPathComponent
    if (name as NSString).pathExtension.isEmpty {
      let fileExtension = url.pathExtension.isEmpty ? resolved.preferredFilenameExtension : url.pathExtension
      if let fileExtension, !fileExtension.isEmpty {
        name += "." + fileExtension
      }
    }
    if resolved.conforms(to: .image) || UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true {
      return image(data, name: name)
    }
    return OutgoingAttachment(kind: .file, name: name, data: data)
  }

  /// An image as agents can read it. PNG, JPEG, GIF and WebP within the size cap go as they are;
  /// anything else (HEIC from the camera, oversized shots) is redrawn as a JPEG.
  static func image(_ data: Data, name: String) -> OutgoingAttachment? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let identifier = CGImageSourceGetType(source) as String? else {
      return nil
    }
    let passthrough: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier]
    if passthrough.contains(identifier), data.count <= 5 * 1024 * 1024 {
      return OutgoingAttachment(kind: .image, name: name, data: data)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 2048,
    ]
    guard
      let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let jpeg = UIImage(cgImage: scaled).jpegData(compressionQuality: 0.85)
    else {
      return nil
    }
    let base = (name as NSString).deletingPathExtension
    return OutgoingAttachment(kind: .image, name: (base.isEmpty ? "Image" : base) + ".jpg", data: jpeg)
  }

  static func textFile(_ text: String) -> OutgoingAttachment {
    OutgoingAttachment(kind: .file, name: "Pasted Text.txt", data: Data(text.utf8))
  }

  /// A small preview for a chip or a pending bubble.
  static func thumbnail(for attachment: OutgoingAttachment, maxPixel: CGFloat = 320) -> UIImage? {
    if isVideo(attachment) { return videoFrame(attachment, maxPixel: maxPixel) }
    guard attachment.kind == .image, let source = CGImageSourceCreateWithData(attachment.data as CFData, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
  }

  static func isVideo(_ attachment: OutgoingAttachment) -> Bool {
    UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.conforms(to: .movie) == true
  }

  /// A video's first frame, read from a scratch copy of its bytes.
  private static func videoFrame(_ attachment: OutgoingAttachment, maxPixel: CGFloat) -> UIImage? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension((attachment.name as NSString).pathExtension)
    guard (try? attachment.data.write(to: url)) != nil else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
    return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map { UIImage(cgImage: $0) }
  }
}
