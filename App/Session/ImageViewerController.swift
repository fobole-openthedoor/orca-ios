import Photos
import UIKit

/// Full-screen images (MobileImageViewer.tsx): pinch and double-tap zoom, swipe sideways through every
/// image in the chat, drag up or down to close. Close and the image's actions sit at the top as glass
/// buttons; a single tap hides them.
final class ImageViewerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
  UIGestureRecognizerDelegate
{
  /// One image in the set: already on the phone, or read from the host when its page comes up.
  enum Source {
    case image(UIImage)
    case load(() async -> UIImage?)
  }

  private let sources: [Source]
  private var index: Int
  private let pages = UIPageViewController(
    transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 20])
  private let backdrop = UIView()
  private let closeButton = UIButton(configuration: .glass())
  private let actionsButton = UIButton(configuration: .glass())
  private let counter = UILabel()
  private var chrome: [UIView] { [closeButton, actionsButton, counter] }
  private var chromeHidden = false
  private let dismissPan = UIPanGestureRecognizer()

  init(sources: [Source], index: Int) {
    self.sources = sources
    self.index = min(max(0, index), max(0, sources.count - 1))
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var prefersStatusBarHidden: Bool { chromeHidden }
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    backdrop.backgroundColor = .black
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backdrop)
    backdrop.pin(to: view)

    pages.dataSource = sources.count > 1 ? self : nil
    pages.delegate = self
    pages.setViewControllers([page(at: index)], direction: .forward, animated: false)
    addChild(pages)
    pages.view.backgroundColor = .clear
    pages.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pages.view)
    pages.view.pin(to: view)
    pages.didMove(toParent: self)

    closeButton.configuration?.image = Lucide.x.image(size: 20, strokeWidth: 2)
    closeButton.configuration?.baseForegroundColor = .white
    closeButton.configuration?.cornerStyle = .capsule
    closeButton.accessibilityLabel = String(localized: "chat.nativeChatImageViewer.closeImage", defaultValue: "Close image")
    closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

    actionsButton.configuration?.image = Lucide.ellipsis.image(size: 20, strokeWidth: 2)
    actionsButton.configuration?.baseForegroundColor = .white
    actionsButton.configuration?.cornerStyle = .capsule
    actionsButton.accessibilityLabel = String(localized: "chat.nativeChatImageViewer.imageActions", defaultValue: "Image actions")
    actionsButton.showsMenuAsPrimaryAction = true
    actionsButton.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.actions() ?? []) }
    ])

    counter.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    counter.textColor = .white
    counter.isHidden = sources.count < 2

    for button in [closeButton, actionsButton] {
      button.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(button)
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 44), button.heightAnchor.constraint(equalToConstant: 44),
      ])
    }
    counter.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(counter)
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: Spacing.sm),
      closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Spacing.lg),
      actionsButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
      actionsButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -Spacing.sm),
      counter.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      counter.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Spacing.lg + 4),
    ])
    updateCounter()

    // Each page makes this wait for its double tap as it loads (ZoomImagePage.onDoubleTapReady).
    view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleChrome)))
    dismissPan.addTarget(self, action: #selector(dragged(_:)))
    dismissPan.delegate = self
    view.addGestureRecognizer(dismissPan)
  }

  // MARK: Pages

  private func page(at index: Int) -> ZoomImagePage {
    let page = ZoomImagePage(source: sources[index])
    page.index = index
    page.onDoubleTapReady = { [weak self] doubleTap in
      self?.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
        .filter { $0.numberOfTapsRequired == 1 }.forEach { $0.require(toFail: doubleTap) }
    }
    return page
  }

  private var currentPage: ZoomImagePage? { pages.viewControllers?.first as? ZoomImagePage }

  func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController)
    -> UIViewController?
  {
    guard let at = (viewController as? ZoomImagePage)?.index, at > 0 else { return nil }
    return page(at: at - 1)
  }

  func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController)
    -> UIViewController?
  {
    guard let at = (viewController as? ZoomImagePage)?.index, at + 1 < sources.count else { return nil }
    return page(at: at + 1)
  }

  func pageViewController(
    _ controller: UIPageViewController, didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController], transitionCompleted completed: Bool
  ) {
    guard completed, let at = currentPage?.index else { return }
    index = at
    updateCounter()
  }

  private func updateCounter() {
    counter.text = "\(index + 1) / \(sources.count)"
  }

  // MARK: Chrome

  @objc private func toggleChrome() {
    chromeHidden.toggle()
    UIView.animate(withDuration: 0.2) {
      self.chrome.forEach { $0.alpha = self.chromeHidden ? 0 : 1 }
      self.setNeedsStatusBarAppearanceUpdate()
    }
    setNeedsUpdateOfHomeIndicatorAutoHidden()
  }

  private func actions() -> [UIMenuElement] {
    guard let image = currentPage?.image else { return [] }
    return [
      UIAction(
        title: String(localized: "chat.nativeChatImageViewer.copyImage", defaultValue: "Copy image"),
        image: Lucide.copy.image(size: 18)
      ) { _ in
        UIPasteboard.general.image = image
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      },
      UIAction(
        title: String(localized: "chat.nativeChatImageViewer.saveImage", defaultValue: "Save image"),
        image: Lucide.download.image(size: 18)
      ) { [weak self] _ in self?.save(image) },
      UIAction(
        title: String(localized: "chat.nativeChatImageViewer.share", defaultValue: "Share…"),
        image: Lucide.share.image(size: 18)
      ) { [weak self] _ in
        let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = self?.actionsButton
        self?.present(share, animated: true)
      },
    ]
  }

  private func save(_ image: UIImage) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        Task { @MainActor [weak self] in
          self?.alert(String(localized: "chat.nativeChatImageViewer.photosAccessDenied", defaultValue: "Allow Orca to add photos in Settings"))
        }
        return
      }
      PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: image) }) { ok, _ in
        Task { @MainActor [weak self] in
          if ok {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
          } else {
            self?.alert(String(localized: "chat.nativeChatImageViewer.saveFailed", defaultValue: "Couldn't save image"))
          }
        }
      }
    }
  }

  private func alert(_ message: String) {
    let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  // MARK: Drag to close

  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard recognizer === dismissPan else { return true }
    // Only a mostly vertical drag on an image that isn't zoomed in; sideways belongs to paging.
    guard currentPage?.isZoomed == false else { return false }
    let velocity = dismissPan.velocity(in: view)
    return abs(velocity.y) > abs(velocity.x) * 1.2
  }

  func gestureRecognizer(
    _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    // The unzoomed image's own scroll view has nothing to scroll; let it ride along.
    recognizer === dismissPan && other.view is UIScrollView && other.view !== pagesScrollView
  }

  private var pagesScrollView: UIScrollView? { pages.view.subviews.first { $0 is UIScrollView } as? UIScrollView }

  @objc private func dragged(_ pan: UIPanGestureRecognizer) {
    guard let pageView = currentPage?.view else { return }
    let offset = pan.translation(in: view).y
    let progress = min(1, abs(offset) / (view.bounds.height / 2))
    switch pan.state {
    case .began:
      pagesScrollView?.isScrollEnabled = false
    case .changed:
      let scale = 1 - progress * 0.25
      pageView.transform = CGAffineTransform(translationX: pan.translation(in: view).x * 0.5, y: offset).scaledBy(x: scale, y: scale)
      backdrop.alpha = 1 - progress
      chrome.forEach { $0.alpha = chromeHidden ? 0 : 1 - progress * 2 }
    case .ended, .cancelled, .failed:
      pagesScrollView?.isScrollEnabled = true
      let velocity = pan.velocity(in: view).y
      let closes = pan.state == .ended && (abs(offset) > 110 || abs(velocity) > 900) && (offset == 0 || velocity * offset >= 0)
      if closes {
        let direction: CGFloat = (offset == 0 ? velocity : offset) < 0 ? -1 : 1
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
          pageView.transform = pageView.transform.translatedBy(x: 0, y: direction * self.view.bounds.height)
          self.backdrop.alpha = 0
          self.chrome.forEach { $0.alpha = 0 }
        } completion: { _ in
          self.dismiss(animated: false)
        }
      } else {
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
          pageView.transform = .identity
          self.backdrop.alpha = 1
          self.chrome.forEach { $0.alpha = self.chromeHidden ? 0 : 1 }
        }
      }
    default: break
    }
  }
}

/// One image in the viewer: fits the screen, pinches to 4×, double-tap zooms to where you tapped.
private final class ZoomImagePage: UIViewController, UIScrollViewDelegate {
  var index = 0
  /// The viewer's single tap, which hides the chrome, has to wait for this page's double tap.
  var onDoubleTapReady: ((UITapGestureRecognizer) -> Void)?
  private let source: ImageViewerController.Source
  private let scroll = UIScrollView()
  private let imageView = UIImageView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var loadTask: Task<Void, Never>?
  private(set) var image: UIImage?

  var isZoomed: Bool { scroll.zoomScale > scroll.minimumZoomScale + 0.01 }

  init(source: ImageViewerController.Source) {
    self.source = source
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { loadTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    scroll.delegate = self
    scroll.maximumZoomScale = 4
    scroll.showsVerticalScrollIndicator = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.frame = view.bounds
    scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(scroll)
    imageView.contentMode = .scaleAspectFit
    imageView.accessibilityIgnoresInvertColors = true
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = String(localized: "chat.nativeChatProse.attachedImage", defaultValue: "Attached image")
    scroll.addSubview(imageView)
    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
    onDoubleTapReady?(doubleTap)

    switch source {
    case .image(let image): show(image)
    case .load(let load):
      spinner.startAnimating()
      loadTask = Task { [weak self] in
        let image = await load()
        guard let self, !Task.isCancelled else { return }
        self.spinner.stopAnimating()
        if let image { self.show(image) } else { self.showUnavailable() }
      }
    }
  }

  private func show(_ image: UIImage) {
    self.image = image
    imageView.image = image
    view.setNeedsLayout()
  }

  /// The host wouldn't send this one (too large, or gone): say so instead of a blank page.
  private func showUnavailable() {
    let icon = LucideView(.image, size: 28, strokeWidth: 1.8, color: UIColor.white.withAlphaComponent(0.5))
    let label = TextLabel(
      String(localized: "orcaios.imageViewer.unavailable", defaultValue: "Couldn't load this image"), size: 15,
      color: UIColor.white.withAlphaComponent(0.6))
    let stack = UIStackView(arrangedSubviews: [icon, label])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = Spacing.sm
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let size = image?.size, size.width > 0, size.height > 0, scroll.zoomScale == scroll.minimumZoomScale else { return }
    let bounds = scroll.bounds.size
    let fit = min(bounds.width / size.width, bounds.height / size.height)
    imageView.frame = CGRect(x: 0, y: 0, width: size.width * fit, height: size.height * fit)
    scroll.contentSize = imageView.frame.size
    center()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

  /// Keeps an image smaller than the screen in the middle of it.
  private func center() {
    let bounds = scroll.bounds.size
    let content = scroll.contentSize
    scroll.contentInset = UIEdgeInsets(
      top: max(0, (bounds.height - content.height) / 2), left: max(0, (bounds.width - content.width) / 2),
      bottom: 0, right: 0)
  }

  @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
    guard image != nil else { return }
    if isZoomed {
      scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
      return
    }
    let point = tap.location(in: imageView)
    let scale: CGFloat = 2.5
    let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
    scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
  }
}
