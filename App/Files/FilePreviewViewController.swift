import OrcaCore
import QuickLook
import UIKit

/// A workspace file (files/MobileFilePreviewScreen.tsx): text and code in a monospaced view, images zoomable,
/// PDFs and audio/video copied to the phone and shown by Quick Look. Anything the phone can't show offers Share,
/// and the Share button in the bar exports any file.
final class FilePreviewViewController: UIViewController, UIScrollViewDelegate, QLPreviewControllerDataSource {
  enum Kind {
    case text, image, media

    /// mobile-artifact-kind.ts and mobile-file-media.ts: images by extension, PDFs and audio/video as media.
    init(path: String) {
      let ext = (path as NSString).pathExtension.lowercased()
      if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico"].contains(ext) {
        self = .image
      } else if [
        "pdf", "mp3", "wav", "m4a", "aac", "ogg", "oga", "flac", "opus", "mp4", "m4v", "mov", "webm",
      ].contains(ext) {
        self = .media
      } else {
        self = .text
      }
    }
  }

  private let session: HostSession
  private let worktreeId: String
  private let path: String
  private let kind: Kind
  private var loadedText: String?
  private var mediaURL: URL?
  private var loadTask: Task<Void, Never>?
  private var content: UIView?
  private var imageView: UIImageView?

  init(session: HostSession, worktreeId: String, path: String) {
    self.session = session
    self.worktreeId = worktreeId
    self.path = path
    kind = Kind(path: path)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    loadTask?.cancel()
    if let mediaURL { try? FileManager.default.removeItem(at: mediaURL.deletingLastPathComponent()) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = (path as NSString).lastPathComponent
    let folder = (path as NSString).deletingLastPathComponent
    navigationItem.subtitle = folder.isEmpty ? nil : folder
    navigationItem.largeTitleDisplayMode = .never
    view.backgroundColor = Palette.editorSurface
    let share = UIBarButtonItem(image: Lucide.share.image(size: 20), style: .plain, target: nil, action: nil)
    share.primaryAction = UIAction(
      title: String(localized: "files.fileShare.share", defaultValue: "Share"), image: Lucide.share.image(size: 20)
    ) { [weak self, weak share] _ in self?.share(from: share) }
    let more = UIBarButtonItem(
      image: Lucide.ellipsis.image(size: 20),
      menu: UIMenu(children: [
        UIAction(
          title: String(localized: "files.fileExplorerRowActions.copyName", defaultValue: "Copy Name"),
          image: Lucide.copy.image(size: 18)
        ) { [path] _ in UIPasteboard.general.string = (path as NSString).lastPathComponent },
        UIAction(
          title: String(localized: "files.fileExplorerRowActions.copyRelativePath", defaultValue: "Copy Relative Path"),
          image: Lucide.link.image(size: 18)
        ) { [path] _ in UIPasteboard.general.string = path },
      ]))
    navigationItem.rightBarButtonItems = [more, share]
    load()
  }

  private func share(from item: UIBarButtonItem?) {
    FileShare.share(
      session: session, worktreeId: worktreeId, path: path, fallbackText: loadedText, from: self, source: item)
  }

  // MARK: Loading

  private func load() {
    loadTask?.cancel()
    showLoading(
      kind == .media
        ? String(localized: "files.fileMediaPreview.loading", defaultValue: "Loading media...")
        : String(localized: "files.filePreviewScreen.loading", defaultValue: "Loading preview..."))
    let api = session.api
    let worktreeId = worktreeId
    let path = path
    switch kind {
    case .text, .image:
      let asImage = kind == .image
      loadTask = Task { [weak self] in
        do {
          let preview = try await api.readFilePreview(worktreeId: worktreeId, path: path, asImage: asImage)
          guard !Task.isCancelled, let self else { return }
          switch preview {
          case .text(let text, let truncated, let byteLength):
            showText(text, truncated: truncated, byteLength: byteLength)
          case .image(let data, _):
            if let image = UIImage(data: data) {
              showImage(image)
            } else {
              showUnavailable(
                String(localized: "files.filePreviewResponse.binaryUnavailable", defaultValue: "Binary preview unavailable"))
            }
          case .binary:
            showUnavailable(
              String(localized: "files.filePreviewResponse.binaryUnavailable", defaultValue: "Binary preview unavailable"))
          }
        } catch {
          guard !Task.isCancelled else { return }
          self?.showFailure(error)
        }
      }
    case .media:
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "preview-\(UUID().uuidString)", isDirectory: true)
      let destination = folder.appendingPathComponent((path as NSString).lastPathComponent)
      let report: @MainActor @Sendable (String) -> Void = { [weak self] in self?.showLoading($0) }
      loadTask = Task { [weak self] in
        do {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          try await api.downloadFile(worktreeId: worktreeId, path: path, to: destination) { read, total in
            let text = String(
              format: String(localized: "files.fileMediaPreview.downloading", defaultValue: "Downloading %1$@ of %2$@"),
              FileShare.byteText(read), FileShare.byteText(total))
            Task { @MainActor in report(text) }
          }
          guard !Task.isCancelled, let self else {
            try? FileManager.default.removeItem(at: folder)
            return
          }
          mediaURL = destination
          showQuickLook()
        } catch {
          try? FileManager.default.removeItem(at: folder)
          guard !Task.isCancelled else { return }
          self?.showFailure(error)
        }
      }
    }
  }

  private func replaceContent(with view: UIView?) {
    content?.removeFromSuperview()
    children.forEach {
      $0.willMove(toParent: nil)
      $0.view.removeFromSuperview()
      $0.removeFromParent()
    }
    content = view
    guard let view else { return }
    view.translatesAutoresizingMaskIntoConstraints = false
    self.view.addSubview(view)
    view.pin(to: self.view)
  }

  private func showLoading(_ text: String) {
    replaceContent(with: nil)
    var config = UIContentUnavailableConfiguration.loading()
    config.text = text
    contentUnavailableConfiguration = config
  }

  private func showText(_ text: String, truncated: Bool, byteLength: Int?) {
    loadedText = text
    contentUnavailableConfiguration = nil
    guard !text.isEmpty else {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = Lucide.fileText.image(size: 32)
      config.text = String(localized: "files.filePreviewBody.emptyFile", defaultValue: "Empty file")
      contentUnavailableConfiguration = config
      return
    }
    let textView = UITextView()
    textView.isEditable = false
    textView.backgroundColor = Palette.editorSurface
    textView.textColor = Palette.textPrimary
    textView.font = Typography.mono(12)
    textView.textContainerInset = UIEdgeInsets(
      top: Spacing.md, left: Spacing.md, bottom: Spacing.xl, right: Spacing.md)
    textView.alwaysBounceVertical = true
    textView.dataDetectorTypes = []
    textView.smartQuotesType = .no
    textView.accessibilityLabel = String(localized: "files.filePreviewSourceText.previewLabel", defaultValue: "File preview")
    var shown = text.replacingOccurrences(of: "\t", with: "    ")
    if truncated {
      let size = byteLength.map(FileShare.byteText)
        ?? String(localized: "files.filePreviewResponse.unknownSize", defaultValue: "unknown size")
      shown += "\n\n"
        + String(
          format: String(
            localized: "files.filePreviewSourceText.truncatedNote", defaultValue: "Preview truncated. File size: %1$@."),
          size)
    }
    textView.text = shown
    replaceContent(with: textView)
  }

  private func showImage(_ image: UIImage) {
    contentUnavailableConfiguration = nil
    let scroll = UIScrollView()
    scroll.delegate = self
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 6
    scroll.contentInsetAdjustmentBehavior = .always
    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.accessibilityLabel = String(
      format: String(localized: "files.filePreviewBody.imageLabel", defaultValue: "%1$@ image"),
      (path as NSString).lastPathComponent)
    scroll.addSubview(imageView)
    replaceContent(with: scroll)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scroll.safeAreaLayoutGuide.heightAnchor),
    ])
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
    doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
    self.imageView = imageView
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
    guard let scroll = gesture.view as? UIScrollView else { return }
    scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2.5, animated: true)
  }

  private func showQuickLook() {
    contentUnavailableConfiguration = nil
    replaceContent(with: nil)
    let preview = QLPreviewController()
    preview.dataSource = self
    addChild(preview)
    preview.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(preview.view)
    NSLayoutConstraint.activate([
      preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      preview.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    preview.didMove(toParent: self)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { mediaURL == nil ? 0 : 1 }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    (mediaURL ?? URL(fileURLWithPath: "/")) as NSURL
  }

  /// The file is there but this phone can't show it: say so and offer to share it.
  private func showUnavailable(_ message: String) {
    replaceContent(with: nil)
    var config = UIContentUnavailableConfiguration.empty()
    config.image = Lucide.file.image(size: 32)
    config.text = message
    var button = UIButton.Configuration.filled()
    button.title = String(localized: "files.fileShare.share", defaultValue: "Share")
    button.image = Lucide.share.image(size: 16)
    button.imagePadding = Spacing.sm
    config.button = button
    config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.share(from: nil) }
    contentUnavailableConfiguration = config
  }

  /// previewError in mobile-file-preview-response.ts: binary and oversized files can still be shared.
  private func showFailure(_ error: Error) {
    let raw = (error as? RPCError).map { "\($0.code) \($0.message)" } ?? "\(error)"
    let normalized = raw.lowercased()
    if normalized.contains("binary_file") {
      showUnavailable(
        String(localized: "files.filePreviewResponse.binaryUnavailable", defaultValue: "Binary preview unavailable"))
      return
    }
    if normalized.contains("file_too_large") || normalized.contains("too_large") || (error as? FileDownloadError) == .tooLarge {
      showUnavailable(
        String(localized: "files.filePreviewResponse.fileTooLarge", defaultValue: "File too large for mobile preview"))
      return
    }
    replaceContent(with: nil)
    var config = UIContentUnavailableConfiguration.empty()
    config.image = Lucide.file.image(size: 32)
    if ["enoent", "no such file", "not found", "does not exist"].contains(where: normalized.contains) {
      config.text = String(localized: "files.filePreviewResponse.fileNotFound", defaultValue: "File not found")
    } else if kind == .media {
      config.text = String(localized: "files.fileMediaPreview.loadFailed", defaultValue: "Unable to load media")
      config.secondaryText = (error as? RPCError)?.message ?? error.localizedDescription
    } else {
      config.text = String(localized: "files.filePreviewResponse.loadFailed", defaultValue: "Unable to load preview")
      config.secondaryText = (error as? RPCError)?.message
    }
    var retry = UIButton.Configuration.gray()
    retry.title = String(localized: "common.retry", defaultValue: "Retry")
    config.button = retry
    config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
    contentUnavailableConfiguration = config
  }
}
