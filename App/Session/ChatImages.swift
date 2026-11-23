import OrcaCore
import UIKit

/// Reads the images a chat's messages point at from the host, two at a time as the official chat does,
/// and keeps them for the session. A path the host won't send stays nil and its thumbnail a placeholder.
@MainActor
final class ChatImageLoader {
  private let api: HostAPI
  private let worktreeId: String
  private var images: [String: UIImage] = [:]
  private var failed: Set<String> = []
  private var waiting: [String: [CheckedContinuation<UIImage?, Never>]] = [:]
  private var queue: [String] = []
  private var running = 0

  init(api: HostAPI, worktreeId: String) {
    self.api = api
    self.worktreeId = worktreeId
  }

  /// Images read once stay on the phone, so a chat opened again (or offline) shows them at once.
  private static let folder: URL = {
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("orca-chat-images", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }()

  private func diskURL(_ path: String) -> URL {
    let key = (worktreeId + "|" + path).utf8.reduce(into: UInt64(14_695_981_039_346_656_037)) { hash, byte in
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return Self.folder.appendingPathComponent(String(key, radix: 16))
  }

  func cached(_ path: String) -> UIImage? {
    if let image = images[path] { return image }
    guard let data = try? Data(contentsOf: diskURL(path)), let image = UIImage(data: data) else { return nil }
    images[path] = image
    return image
  }

  /// An image this phone uploaded, kept under the path its message names.
  func remember(_ path: String, data: Data) {
    guard images[path] == nil, let image = UIImage(data: data) else { return }
    images[path] = image
    try? data.write(to: diskURL(path), options: .atomic)
    failed.remove(path)
  }

  func image(_ path: String) async -> UIImage? {
    if let image = cached(path) { return image }
    if failed.contains(path) { return nil }
    return await withCheckedContinuation { continuation in
      if waiting[path] == nil {
        waiting[path] = []
        queue.append(path)
      }
      waiting[path]?.append(continuation)
      pump()
    }
  }

  private func pump() {
    while running < 2, !queue.isEmpty {
      let path = queue.removeFirst()
      running += 1
      Task {
        let data = try? await api.readChatImage(worktreeId: worktreeId, path: path)
        let image = data.flatMap { UIImage(data: $0) }
        if let data, image != nil { try? data.write(to: diskURL(path), options: .atomic) }
        if let image { images[path] = image } else { failed.insert(path) }
        running -= 1
        waiting.removeValue(forKey: path)?.forEach { $0.resume(returning: image) }
        pump()
      }
    }
  }
}

/// A message's images (imageThumb in mobile-native-chat-message-styles.ts): 200 × 150 on the raised fill
/// with a hairline edge, one under another, filled and cropped so no bars show; the viewer shows the
/// whole picture. Tapping one opens it.
final class ChatImageStack: UIStackView {
  var onOpen: ((Int) -> Void)?
  private var loads: [Task<Void, Never>] = []

  init() {
    super.init(frame: .zero)
    axis = .vertical
    alignment = .leading
    spacing = Spacing.sm
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Each image is on the phone already (a send in flight) or read from the host as it shows.
  func show(_ images: [ImageViewerController.Source]) {
    loads.forEach { $0.cancel() }
    loads = []
    arrangedSubviews.forEach { $0.removeFromSuperview() }
    isHidden = images.isEmpty
    for (index, source) in images.enumerated() {
      let thumb = UIImageView()
      thumb.contentMode = .scaleAspectFill
      thumb.backgroundColor = Palette.bgRaised
      thumb.layer.cornerRadius = Radius.surface
      thumb.layer.cornerCurve = .continuous
      thumb.layer.borderWidth = 1 / UIScreen.main.scale
      thumb.layer.borderColor = Palette.borderSubtle.cgColor
      thumb.clipsToBounds = true
      thumb.isUserInteractionEnabled = true
      thumb.isAccessibilityElement = true
      thumb.accessibilityTraits = [.image, .button]
      thumb.accessibilityLabel = String(localized: "chat.nativeChatProse.attachedImage", defaultValue: "Attached image")
      thumb.accessibilityHint = String(localized: "chat.nativeChatProse.openImageHint", defaultValue: "Opens the image full size")
      thumb.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        thumb.widthAnchor.constraint(equalToConstant: 200), thumb.heightAnchor.constraint(equalToConstant: 150),
      ])
      thumb.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
      thumb.tag = index
      addArrangedSubview(thumb)
      switch source {
      case .image(let image): thumb.image = image
      case .load(let load):
        loads.append(Task { [weak thumb] in
          let image = await load()
          guard !Task.isCancelled else { return }
          thumb?.image = image
        })
      }
    }
  }

  @objc private func tapped(_ tap: UITapGestureRecognizer) {
    guard let index = tap.view?.tag else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    onOpen?(index)
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    arrangedSubviews.forEach { $0.layer.borderColor = Palette.borderSubtle.resolvedColor(with: traitCollection).cgColor }
  }
}

/// What a run's reads showed the agent: its images under the run's line, on the turn's thread.
final class ViewedImagesView: UIView {
  let stack = ChatImageStack()
  private var rails: TimelineRails?

  init() {
    super.init(frame: .zero)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg + 23),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.lg),
    ])
    rails = TimelineRails(in: self, iconSize: 0, centeredOn: centerYAnchor)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The thread runs straight through: images sit between activity rows.
  func connect(up: Bool, down: Bool) { rails?.show(up: up, down: down) }
}
