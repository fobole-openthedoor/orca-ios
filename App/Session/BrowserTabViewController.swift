import OrcaCore
import UIKit

/// A desktop browser tab (browser/MobileBrowserPane.tsx): the page streams from the desktop as JPEG frames
/// (`browser.screencast`), and taps, drags and typing go back as page commands. Above it, back, forward,
/// reload, the address and the web/mobile view switch; under it, click modifiers, keys and a line to type.
final class BrowserTabViewController: UIViewController, WorkspaceContent, UITextFieldDelegate, UIGestureRecognizerDelegate {
  private enum Modifier: String, CaseIterable {
    case cmd, ctrl, alt, shift
    var label: String { rawValue == "cmd" ? "Cmd" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
  }

  private let api: HostAPI
  private let worktreeId: String
  private let streamingSupported: Bool?
  private var page: BrowserTabState

  private let toolbar = UIView()
  private let backButton = BrowserTabViewController.toolbarButton(.chevronLeft)
  private let forwardButton = BrowserTabViewController.toolbarButton(.chevronRight)
  private let reloadButton = BrowserTabViewController.toolbarButton(.refreshCw)
  private let address = UITextField()
  private let progress = UIProgressView(progressViewStyle: .bar)
  private var modeButtons: [BrowserViewMode: UIButton] = [:]
  private let viewport = UIView()
  private let frameBox = UIView()
  private let frameImage = UIImageView()
  private let overlay = UIStackView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let errorLabel = StreamErrorLabel()
  private let failure = UIStackView()
  private let failureTitle = TextLabel(size: 16, weight: .semibold, alignment: .center, lines: 0)
  private let failureText = TextLabel(size: Typography.bodySize, color: Palette.textSecondary, alignment: .center, lines: 0)
  private var modifierButtons: [Modifier: UIButton] = [:]
  private var keyButtons: [UIButton] = []
  private let input = UITextField()
  private let sendButton = UIButton(type: .system)

  private var viewMode: BrowserViewMode
  private var modifiers: [Modifier] = []
  private var metadata: BrowserFrameMetadata?
  private var zoom = BrowserFrameGeometry.Zoom.none
  private var streamTask: Task<Void, Never>?
  private var startupTimer: Task<Void, Never>?
  private var streamedSize: CGSize = .zero
  private var subscriptionId: String?
  private var busy = false
  private var hasFrame = false
  private var error: String?
  private var dialogShown = false
  private var foregroundObservers: [NSObjectProtocol] = []
  /// One wheel on the wire at a time; drags while it runs add up into the next.
  private var wheelInFlight = false
  private var pendingWheel: (x: Double, y: Double, dx: Double, dy: Double)?
  private var lastWheel: (translation: CGPoint, at: Date) = (.zero, .distantPast)
  private var panZoomStart: BrowserFrameGeometry.Zoom?
  private var pinchStart: BrowserFrameGeometry.Zoom?

  init(api: HostAPI, worktreeId: String, tab: BrowserTabState, streamingSupported: Bool?) {
    self.api = api
    self.worktreeId = worktreeId
    self.page = tab
    self.streamingSupported = streamingSupported
    viewMode = BrowserViewMode.initial(for: tab.url)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    streamTask?.cancel()
    startupTimer?.cancel()
    foregroundObservers.forEach(NotificationCenter.default.removeObserver)
  }

  func close() {
    streamTask?.cancel()
    streamTask = nil
    startupTimer?.cancel()
  }

  private var controlsDisabled: Bool { page.pageId == nil || streamingSupported != true }

  // MARK: Layout

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    buildToolbar()
    buildViewport()
    let dock = buildDock()
    for part in [toolbar, viewport, dock] {
      part.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(part)
    }
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      viewport.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      viewport.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      viewport.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      viewport.bottomAnchor.constraint(equalTo: dock.topAnchor),
      dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // The dock rides the keyboard; without one it sits on the home indicator's inset.
      dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])
    let center = NotificationCenter.default
    foregroundObservers = [
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.stopStream() }
      },
      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.restartStream() }
      },
    ]
    apply(page)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutFrame()
    // A new pane size asks the host for frames that fit it.
    if viewport.bounds.size != streamedSize, viewport.bounds.width > 0 {
      restartStream()
    }
  }

  private static func toolbarButton(_ icon: Lucide) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = icon.image(size: 15)
    configuration.contentInsets = .zero
    configuration.background.cornerRadius = Radius.control
    let button = UIButton(configuration: configuration)
    button.tintColor = Palette.textSecondary
    button.configurationUpdateHandler = { button in
      button.configuration?.background.backgroundColor = button.isHighlighted ? Palette.bgRaised : .clear
      button.alpha = button.isEnabled ? 1 : 0.35
    }
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 26), button.heightAnchor.constraint(equalToConstant: 26),
    ])
    return button
  }

  private func buildToolbar() {
    toolbar.backgroundColor = Palette.bgPanel
    backButton.accessibilityLabel = String(localized: "common.back", defaultValue: "Back")
    backButton.addAction(UIAction { [weak self] _ in self?.navigate("browser.back") }, for: .touchUpInside)
    forwardButton.accessibilityLabel = String(localized: "browser.paneView.forward", defaultValue: "Forward")
    forwardButton.addAction(UIAction { [weak self] _ in self?.navigate("browser.forward") }, for: .touchUpInside)
    reloadButton.accessibilityLabel = String(localized: "browser.paneView.reload", defaultValue: "Reload")
    reloadButton.addAction(UIAction { [weak self] _ in self?.navigate("browser.reload") }, for: .touchUpInside)

    address.font = Typography.font(16)
    address.textColor = Palette.textPrimary
    address.backgroundColor = Palette.composerSurface
    address.layer.borderWidth = 1
    address.layer.borderColor = Palette.inputBorder.cgColor
    address.layer.cornerRadius = Radius.control
    address.leftView = UIView(frame: CGRect(x: 0, y: 0, width: Spacing.md, height: 1))
    address.leftViewMode = .always
    address.rightView = UIView(frame: CGRect(x: 0, y: 0, width: Spacing.md, height: 1))
    address.rightViewMode = .always
    address.attributedPlaceholder = NSAttributedString(
      string: String(localized: "browser.addressField.urlPlaceholder", defaultValue: "URL"),
      attributes: [.foregroundColor: Palette.textMuted])
    address.keyboardType = .URL
    address.autocapitalizationType = .none
    address.autocorrectionType = .no
    address.returnKeyType = .go
    address.clearButtonMode = .whileEditing
    address.delegate = self
    address.translatesAutoresizingMaskIntoConstraints = false
    address.heightAnchor.constraint(equalToConstant: 28).isActive = true
    // The page's load shows as a thin line under the address.
    progress.progressTintColor = Palette.accentBlue
    progress.trackTintColor = .clear
    progress.translatesAutoresizingMaskIntoConstraints = false
    address.addSubview(progress)
    NSLayoutConstraint.activate([
      progress.leadingAnchor.constraint(equalTo: address.leadingAnchor, constant: Radius.control / 2),
      progress.trailingAnchor.constraint(equalTo: address.trailingAnchor, constant: -Radius.control / 2),
      progress.bottomAnchor.constraint(equalTo: address.bottomAnchor, constant: -1),
      progress.heightAnchor.constraint(equalToConstant: 2),
    ])

    let modes = UIStackView()
    modes.backgroundColor = Palette.bgRaised
    modes.layer.cornerRadius = Radius.control
    modes.isLayoutMarginsRelativeArrangement = true
    modes.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
    for (mode, icon, label) in [
      (BrowserViewMode.web, Lucide.monitor, String(localized: "browser.viewModeSwitch.webView", defaultValue: "Show web website view")),
      (.mobile, .smartphone, String(localized: "browser.viewModeSwitch.mobileView", defaultValue: "Show mobile website view")),
    ] {
      var configuration = UIButton.Configuration.plain()
      configuration.image = icon.image(size: 14)
      configuration.contentInsets = .zero
      configuration.background.cornerRadius = Radius.control
      let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.select(mode) })
      button.accessibilityLabel = label
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 32), button.heightAnchor.constraint(equalToConstant: 24),
      ])
      modeButtons[mode] = button
      modes.addArrangedSubview(button)
    }

    let row = UIStackView(arrangedSubviews: [backButton, forwardButton, reloadButton, address, modes])
    row.alignment = .center
    row.spacing = Spacing.xs
    row.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(row)
    let border = Hairline()
    border.heightAnchor.constraint(equalToConstant: 1).priority = .required
    toolbar.addSubview(border)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: Spacing.sm),
      row.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -Spacing.sm),
      row.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 2),
      row.bottomAnchor.constraint(equalTo: border.topAnchor, constant: -2),
      toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
      border.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
      border.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
      border.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
    ])
  }

  private func buildViewport() {
    viewport.backgroundColor = Palette.bgBase
    viewport.clipsToBounds = true
    frameBox.clipsToBounds = true
    frameImage.contentMode = .scaleToFill
    frameImage.backgroundColor = Palette.bgBase
    frameBox.addSubview(frameImage)
    viewport.addSubview(frameBox)

    let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
    press.minimumPressDuration = 0.55
    let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    pan.maximumNumberOfTouches = 1
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    tap.require(toFail: press)
    for recognizer in [tap, press, pan, pinch] as [UIGestureRecognizer] {
      recognizer.delegate = self
      viewport.addGestureRecognizer(recognizer)
    }

    overlay.axis = .vertical
    overlay.alignment = .center
    overlay.spacing = Spacing.sm
    overlay.isUserInteractionEnabled = false
    overlay.backgroundColor = UIColor(red: 13 / 255, green: 15 / 255, blue: 24 / 255, alpha: 0.2)
    overlay.isLayoutMarginsRelativeArrangement = true
    overlay.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: Spacing.xl, leading: Spacing.xl, bottom: Spacing.xl, trailing: Spacing.xl)
    spinner.color = Palette.textSecondary
    errorLabel.font = Typography.font(13)
    errorLabel.textColor = Palette.textPrimary
    errorLabel.textAlignment = .center
    errorLabel.numberOfLines = 0
    errorLabel.backgroundColor = Palette.bgPanel
    errorLabel.layer.borderWidth = 1
    errorLabel.layer.borderColor = Palette.borderSubtle.cgColor
    errorLabel.layer.cornerRadius = Radius.surface
    errorLabel.clipsToBounds = true
    let centered = UIStackView(arrangedSubviews: [spinner, errorLabel])
    centered.axis = .vertical
    centered.alignment = .center
    centered.spacing = Spacing.sm
    overlay.addArrangedSubview(UIView())
    overlay.addArrangedSubview(centered)
    overlay.addArrangedSubview(UIView())
    overlay.distribution = .equalCentering
    viewport.addSubview(overlay)
    overlay.pin(to: viewport)

    // A page that failed to load: what went wrong, and Retry for the address that failed.
    var retry = UIButton.Configuration.filled()
    retry.title = String(localized: "browser.loadFailure.retry", defaultValue: "Retry")
    retry.baseBackgroundColor = Palette.textPrimary
    retry.baseForegroundColor = Palette.bgBase
    retry.cornerStyle = .fixed
    retry.background.cornerRadius = Radius.control
    let retryButton = UIButton(configuration: retry, primaryAction: UIAction { [weak self] _ in self?.retryFailedLoad() })
    failure.addArrangedSubview(failureTitle)
    failure.addArrangedSubview(failureText)
    failure.addArrangedSubview(retryButton)
    failure.axis = .vertical
    failure.alignment = .center
    failure.spacing = Spacing.sm
    failure.setCustomSpacing(Spacing.lg, after: failureText)
    failure.isLayoutMarginsRelativeArrangement = true
    failure.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: Spacing.xl, leading: Spacing.xl, bottom: Spacing.xl, trailing: Spacing.xl)
    failure.backgroundColor = Palette.bgBase
    failure.translatesAutoresizingMaskIntoConstraints = false
    viewport.addSubview(failure)
    NSLayoutConstraint.activate([
      failure.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
      failure.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
      failure.centerYAnchor.constraint(equalTo: viewport.centerYAnchor),
    ])
  }

  private func keyButton(_ title: String, action: @escaping () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: Typography.mono(12)]))
    configuration.baseBackgroundColor = Palette.bgRaised
    configuration.baseForegroundColor = Palette.textSecondary
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = Radius.control
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm)
    let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
    ])
    return button
  }

  private func buildDock() -> UIView {
    let dock = UIView()
    dock.backgroundColor = Palette.bgPanel
    let border = Hairline()
    dock.addSubview(border)

    let modifierRow = UIStackView()
    for modifier in Modifier.allCases {
      let button = keyButton(modifier.label) { [weak self] in self?.toggle(modifier) }
      button.accessibilityLabel = String(
        format: String(localized: "browser.pointerModifiers.clickModifier", defaultValue: "%1$@ click modifier"), modifier.label)
      modifierButtons[modifier] = button
      modifierRow.addArrangedSubview(button)
    }
    let keyRow = UIStackView()
    for key in ["Enter", "Backspace", "Tab", "Escape"] {
      let title = key == "Backspace" ? "⌫" : key == "Escape" ? "Esc" : key
      let button = keyButton(title) { [weak self] in self?.sendKey(key) }
      keyButtons.append(button)
      keyRow.addArrangedSubview(button)
    }
    for row in [modifierRow, keyRow] {
      row.spacing = Spacing.xs
      row.addArrangedSubview(UIView())
    }

    input.font = Typography.mono(16)
    input.textColor = Palette.textPrimary
    input.backgroundColor = Palette.composerSurface
    input.layer.borderWidth = 1
    input.layer.borderColor = Palette.inputBorder.cgColor
    input.layer.cornerRadius = Radius.control
    input.leftView = UIView(frame: CGRect(x: 0, y: 0, width: Spacing.md, height: 1))
    input.leftViewMode = .always
    input.attributedPlaceholder = NSAttributedString(
      string: String(localized: "browser.paneView.keyboardPlaceholder", defaultValue: "Type on page…"),
      attributes: [.foregroundColor: Palette.textMuted])
    input.autocapitalizationType = .none
    input.autocorrectionType = .no
    input.returnKeyType = .send
    input.delegate = self
    input.addAction(UIAction { [weak self] _ in self?.updateControls() }, for: .editingChanged)
    var send = UIButton.Configuration.filled()
    send.image = Lucide.arrowUp.image(size: 18)
    send.baseBackgroundColor = Palette.bgRaised
    send.baseForegroundColor = Palette.textSecondary
    send.cornerStyle = .fixed
    send.background.cornerRadius = Radius.control
    sendButton.configuration = send
    sendButton.accessibilityLabel = String(localized: "browser.paneView.sendText", defaultValue: "Send text to browser")
    sendButton.addAction(UIAction { [weak self] _ in self?.sendText() }, for: .touchUpInside)
    let inputRow = UIStackView(arrangedSubviews: [input, sendButton])
    inputRow.spacing = Spacing.sm
    inputRow.alignment = .center
    NSLayoutConstraint.activate([
      input.heightAnchor.constraint(equalToConstant: 34),
      sendButton.widthAnchor.constraint(equalToConstant: 34),
      sendButton.heightAnchor.constraint(equalToConstant: 34),
    ])

    let column = UIStackView(arrangedSubviews: [modifierRow, keyRow, inputRow])
    column.axis = .vertical
    column.spacing = Spacing.xs
    column.setCustomSpacing(Spacing.xs, after: keyRow)
    column.isLayoutMarginsRelativeArrangement = true
    column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.xs, leading: Spacing.sm, bottom: Spacing.xs + 2, trailing: Spacing.sm)
    inputRow.isLayoutMarginsRelativeArrangement = true
    inputRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: Spacing.md - Spacing.sm, bottom: 0, trailing: Spacing.md - Spacing.sm)
    column.translatesAutoresizingMaskIntoConstraints = false
    dock.addSubview(column)
    NSLayoutConstraint.activate([
      border.topAnchor.constraint(equalTo: dock.topAnchor),
      border.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
      border.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
      column.topAnchor.constraint(equalTo: border.bottomAnchor),
      column.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
      column.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
    ])
    return dock
  }

  // MARK: State

  /// The tab as the desktop now describes it: its address, whether it can go back or forward, and how it loads.
  func apply(_ next: BrowserTabState) {
    let pageChanged = next.pageId != page.pageId
    let urlChanged = next.url != page.url
    page = next
    guard isViewLoaded else { return }
    if !address.isFirstResponder { address.text = BrowserURL.display(next.url) }
    if urlChanged { resetZoom() }
    if pageChanged {
      viewMode = BrowserViewMode.initial(for: next.url)
      restartStream()
    }
    updateControls()
  }

  private func updateControls() {
    let disabled = controlsDisabled
    backButton.isEnabled = !disabled && page.canGoBack
    forwardButton.isEnabled = !disabled && page.canGoForward
    reloadButton.isEnabled = !disabled
    address.isEnabled = !disabled
    for (mode, button) in modeButtons {
      let selected = mode == viewMode
      button.configuration?.background.backgroundColor = selected ? Palette.textPrimary : .clear
      button.tintColor = selected ? Palette.bgBase : Palette.textSecondary
      button.isEnabled = !disabled
      button.alpha = disabled ? 0.35 : 1
      button.isSelected = selected
    }
    for (modifier, button) in modifierButtons {
      let selected = modifiers.contains(modifier)
      button.configuration?.baseBackgroundColor = selected ? Palette.textPrimary : Palette.bgRaised
      button.configuration?.baseForegroundColor = selected ? Palette.bgBase : Palette.textSecondary
      button.isEnabled = !disabled
      button.alpha = disabled ? 0.35 : 1
    }
    for button in keyButtons {
      button.isEnabled = !disabled
      button.alpha = disabled ? 0.35 : 1
    }
    input.isEnabled = !disabled
    let canSend = !disabled && !(input.text ?? "").isEmpty
    sendButton.isEnabled = canSend
    sendButton.alpha = canSend ? 1 : 0.35
    progress.isHidden = !page.loading
    progress.setProgress(page.loading ? 0.6 : 0, animated: false)
    if let loadError = page.loadError {
      failure.isHidden = false
      let host = URL(string: loadError.validatedUrl)?.host() ?? URL(string: page.url)?.host() ?? ""
      failureTitle.text = host.isEmpty ? loadError.description : host
      failureText.text = host.isEmpty ? nil : loadError.description
      failureText.isHidden = host.isEmpty
    } else {
      failure.isHidden = true
    }
    spinner.isHidden = !(busy || (!hasFrame && error == nil))
    if spinner.isHidden { spinner.stopAnimating() } else { spinner.startAnimating() }
    errorLabel.text = error
    errorLabel.isHidden = error == nil
    overlay.isHidden = hasFrame && !busy && error == nil
  }

  private func setError(_ message: String?) {
    // A selector that moved mid-navigation is transient; the frames on screen still serve.
    if let message, message.lowercased().contains("selector_not_found") || message.lowercased().contains("selector not found") {
      return
    }
    error = message
    updateControls()
  }

  private func select(_ mode: BrowserViewMode) {
    guard mode != viewMode else { return }
    Haptics.select()
    viewMode = mode
    resetZoom()
    restartStream()
  }

  private func toggle(_ modifier: Modifier) {
    if let index = modifiers.firstIndex(of: modifier) {
      modifiers.remove(at: index)
    } else {
      modifiers.append(modifier)
    }
    updateControls()
  }

  // MARK: Stream

  private func stopStream() {
    streamTask?.cancel()
    streamTask = nil
    startupTimer?.cancel()
    subscriptionId = nil
    streamedSize = .zero
  }

  private func restartStream() {
    stopStream()
    guard isViewLoaded, UIApplication.shared.applicationState != .background else { return }
    let size = viewport.bounds.size
    streamedSize = size
    error = nil
    guard streamingSupported == true, let pageId = page.pageId,
      let request = BrowserScreencastRequest.params(
        width: size.width, height: size.height, pixelRatio: view.traitCollection.displayScale, mode: viewMode)
    else {
      busy = false
      if streamingSupported == false {
        // Every host new enough to pair streams when it has a browser window, so a refusal means it has none.
        error = String(localized: "browser.stream.hostCannotStream", defaultValue: "This host can't stream browser tabs here.")
      } else if streamingSupported == nil {
        error = String(localized: "browser.stream.checking", defaultValue: "Checking desktop browser streaming support.")
      } else if page.pageId == nil {
        error = String(localized: "browser.stream.pageUnavailable", defaultValue: "Browser page is not available yet.")
      }
      updateControls()
      return
    }
    busy = true
    updateControls()
    startupTimer = Task { [weak self] in
      guard (try? await Task.sleep(for: .seconds(15))) != nil, let self else { return }
      self.busy = false
      self.setError(String(localized: "browser.stream.timedOut", defaultValue: "Browser stream timed out."))
    }
    let api = api
    let worktreeId = worktreeId
    streamTask = Task { [weak self] in
      let subscription = await api.browserScreencast(worktreeId: worktreeId, pageId: pageId, request: request)
      do {
        for try await frame in subscription.frames {
          guard let self, !Task.isCancelled else { return }
          switch frame {
          case .reply(let reply):
            self.handle(BrowserScreencastEvent(reply))
          case .binary(let bytes):
            guard let decoded = BrowserScreencastFrame(bytes) else { continue }
            self.startupTimer?.cancel()
            if let subscriptionId = self.subscriptionId {
              Task { await api.browserScreencastAck(worktreeId: worktreeId, subscriptionId: subscriptionId, seq: decoded.seq) }
            }
            await self.show(decoded)
          }
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.busy = false
        self.setError((error as? RPCError)?.message ?? error.localizedDescription)
      }
    }
  }

  private func handle(_ event: BrowserScreencastEvent) {
    switch event {
    case .ready(let subscriptionId, let frameAck, let url):
      startupTimer?.cancel()
      // Hosts that don't count frames never echo frameAck; they get no acks.
      self.subscriptionId = frameAck ? subscriptionId : nil
      busy = false
      if let url, !address.isFirstResponder {
        if url != page.url { resetZoom() }
        address.text = BrowserURL.display(url)
      }
      updateControls()
    case .end:
      startupTimer?.cancel()
      busy = false
      updateControls()
    case .dialog(let type, let message, let defaultText, let origin):
      showDialog(type: type, message: message, defaultText: defaultText, origin: origin)
    case .dialogClosed:
      if dialogShown, let alert = presentedViewController as? UIAlertController {
        dialogShown = false
        alert.dismiss(animated: true)
      }
    case .error(let message):
      startupTimer?.cancel()
      busy = false
      setError(message)
    case .other:
      break
    }
  }

  /// Decodes off the main thread, then swaps the picture in; the newest frame always wins.
  private func show(_ frame: BrowserScreencastFrame) async {
    let image = await Task.detached(priority: .userInitiated) { UIImage(data: frame.image)?.preparingForDisplay() }.value
    guard let image, !Task.isCancelled else { return }
    frameImage.image = image
    if metadata != frame.metadata {
      metadata = frame.metadata
      layoutFrame()
    }
    if !hasFrame || busy {
      hasFrame = true
      busy = false
      updateControls()
    }
  }

  // MARK: Geometry

  private var geometry: BrowserFrameGeometry? {
    BrowserFrameGeometry(width: viewport.bounds.width, height: viewport.bounds.height, metadata: metadata)
  }

  private func layoutFrame() {
    guard let geometry else { return }
    zoom = geometry.clamped(zoom)
    frameBox.transform = .identity
    frameBox.frame = CGRect(x: geometry.offsetX, y: geometry.offsetY, width: geometry.renderedWidth, height: geometry.renderedHeight)
    frameImage.frame = frameBox.bounds
    frameBox.transform = CGAffineTransform(translationX: zoom.offsetX, y: zoom.offsetY).scaledBy(x: zoom.scale, y: zoom.scale)
  }

  private func resetZoom() {
    zoom = .none
    layoutFrame()
  }

  // MARK: Input

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // A dialog or a failed load holds the page; nothing reaches it past them.
    !dialogShown && failure.isHidden
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
  }

  private func pagePoint(_ point: CGPoint) -> (x: Double, y: Double)? {
    geometry?.pagePoint(x: point.x, y: point.y, zoom: zoom)
  }

  @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
    guard let point = pagePoint(recognizer.location(in: viewport)) else { return }
    click(point, button: "left")
  }

  @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began, let point = pagePoint(recognizer.location(in: viewport)) else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    click(point, button: "right")
    Toast.shared.show("Right click")
  }

  @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
    let translation = recognizer.translation(in: viewport)
    switch recognizer.state {
    case .began:
      panZoomStart = zoom.scale > BrowserFrameGeometry.minZoom ? zoom : nil
      lastWheel = (.zero, .distantPast)
    case .changed:
      // Zoomed in, a drag moves the picture; at 1× it scrolls the page.
      if let start = panZoomStart, let geometry {
        zoom = geometry.clamped(.init(scale: start.scale, offsetX: start.offsetX + translation.x, offsetY: start.offsetY + translation.y))
        layoutFrame()
        return
      }
      let now = Date()
      guard now.timeIntervalSince(lastWheel.at) >= 0.07 else { return }
      let dx = translation.x - lastWheel.translation.x
      let dy = translation.y - lastWheel.translation.y
      guard abs(dx) + abs(dy) >= 8, let point = pagePoint(recognizer.location(in: viewport)), let geometry else { return }
      lastWheel = (translation, now)
      let delta = geometry.wheelDelta(screenDx: dx, screenDy: dy, zoomScale: zoom.scale)
      guard abs(delta.dx) >= 1 || abs(delta.dy) >= 1 else { return }
      if let pending = pendingWheel {
        pendingWheel = (point.x, point.y, pending.dx + delta.dx, pending.dy + delta.dy)
      } else {
        pendingWheel = (point.x, point.y, delta.dx, delta.dy)
      }
      flushWheel()
    default:
      panZoomStart = nil
    }
  }

  @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
    guard let geometry else { return }
    switch recognizer.state {
    case .began:
      pinchStart = zoom
    case .changed:
      guard let start = pinchStart else { return }
      // The point under the fingers stays under them.
      let center = recognizer.location(in: viewport)
      let baseX = geometry.offsetX + geometry.renderedWidth / 2
      let baseY = geometry.offsetY + geometry.renderedHeight / 2
      let anchorX = (center.x - baseX - start.offsetX) / start.scale
      let anchorY = (center.y - baseY - start.offsetY) / start.scale
      let scale = min(BrowserFrameGeometry.maxZoom, max(BrowserFrameGeometry.minZoom, start.scale * recognizer.scale))
      zoom = geometry.clamped(.init(scale: scale, offsetX: center.x - baseX - anchorX * scale, offsetY: center.y - baseY - anchorY * scale))
      layoutFrame()
    default:
      pinchStart = nil
    }
  }

  private func flushWheel() {
    guard !wheelInFlight, let wheel = pendingWheel, let pageId = page.pageId else { return }
    pendingWheel = nil
    wheelInFlight = true
    let api = api
    let worktreeId = worktreeId
    Task { [weak self] in
      // Scroll bursts race navigation; a failed wheel is dropped rather than shown.
      _ = try? await api.browserCommand(
        "browser.mouseMove", worktreeId: worktreeId, pageId: pageId, ["x": .number(wheel.x), "y": .number(wheel.y)])
      _ = try? await api.browserCommand(
        "browser.mouseWheel", worktreeId: worktreeId, pageId: pageId, ["dx": .number(wheel.dx), "dy": .number(wheel.dy)])
      self?.wheelInFlight = false
      self?.flushWheel()
    }
  }

  private func click(_ point: (x: Double, y: Double), button: String) {
    guard let pageId = page.pageId, !controlsDisabled else { return }
    let api = api
    let worktreeId = worktreeId
    let modifiers = modifiers
    var fields: [String: JSONValue] = [
      "x": .number(point.x), "y": .number(point.y), "button": .string(button),
      "modifiers": .array(modifiers.map { .string($0.rawValue) }),
    ]
    if button == "left", let geometry {
      fields["radius"] = .number(geometry.clickRadius(zoomScale: zoom.scale))
    }
    Task {
      do {
        try await api.browserCommand("browser.mouseClick", worktreeId: worktreeId, pageId: pageId, fields, timeout: .seconds(5))
      } catch is RPCError where modifiers.isEmpty {
        // A host without mouseClick: the same press as move, down and up. A timed-out click may still run,
        // so only a refusal is replayed.
        let base: [String: JSONValue] = ["button": .string(button)]
        _ = try? await api.browserCommand(
          "browser.mouseMove", worktreeId: worktreeId, pageId: pageId, ["x": .number(point.x), "y": .number(point.y)])
        _ = try? await api.browserCommand("browser.mouseDown", worktreeId: worktreeId, pageId: pageId, base)
        _ = try? await api.browserCommand("browser.mouseUp", worktreeId: worktreeId, pageId: pageId, base)
      } catch {}
    }
  }

  private func navigate(_ method: String) {
    guard let pageId = page.pageId, !controlsDisabled else { return }
    Haptics.select()
    let api = api
    let worktreeId = worktreeId
    Task { _ = try? await api.browserCommand(method, worktreeId: worktreeId, pageId: pageId) }
  }

  private func go(to url: String) {
    guard let pageId = page.pageId, !controlsDisabled else { return }
    busy = true
    updateControls()
    let api = api
    let worktreeId = worktreeId
    Task { [weak self] in
      do {
        let settled = try await api.browserGoto(worktreeId: worktreeId, pageId: pageId, url: url)
        guard let self else { return }
        self.busy = false
        if let settled {
          self.address.text = BrowserURL.display(settled)
          self.resetZoom()
        }
        self.setError(nil)
      } catch {
        self?.busy = false
        self?.setError((error as? RPCError)?.message ?? "Browser command failed")
      }
    }
  }

  /// As desktop's streamed pane: reloading the host's error page only refreshes it, so load the failed URL again.
  private func retryFailedLoad() {
    let url = page.loadError?.validatedUrl ?? ""
    go(to: url.isEmpty ? page.url : url)
  }

  private func sendKey(_ key: String) {
    guard let pageId = page.pageId, !controlsDisabled else { return }
    let api = api
    let worktreeId = worktreeId
    Task { _ = try? await api.browserCommand("browser.keypress", worktreeId: worktreeId, pageId: pageId, ["key": .string(key)]) }
  }

  private func sendText() {
    let text = input.text ?? ""
    guard !text.isEmpty, let pageId = page.pageId, !controlsDisabled else { return }
    input.text = ""
    updateControls()
    let api = api
    let worktreeId = worktreeId
    Task { [weak self] in
      do {
        try await api.browserCommand("browser.keyboardInsertText", worktreeId: worktreeId, pageId: pageId, ["text": .string(text)])
        Toast.shared.show(String(localized: "browser.useBrowserCommands.sent", defaultValue: "Sent"))
      } catch {
        guard let self else { return }
        // The draft comes back so nothing typed is lost.
        self.input.text = text + (self.input.text ?? "")
        self.updateControls()
        if !(error is RPCError) {
          Toast.shared.show(
            String(
              localized: "browser.useBrowserCommands.deliveryUnconfirmed",
              defaultValue: "Delivery unconfirmed — check page before retrying"), kind: .error)
        }
      }
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === address {
      guard let url = BrowserURL.normalize(address.text ?? "") else {
        setError(String(localized: "browser.pane.invalidUrl", defaultValue: "Enter a valid URL."))
        return false
      }
      textField.resignFirstResponder()
      go(to: url)
    } else {
      sendText()
    }
    return true
  }

  func textFieldDidEndEditing(_ textField: UITextField) {
    // Leaving the address without going restores where the page is.
    if textField === address { address.text = BrowserURL.display(page.url) }
  }

  func textFieldDidBeginEditing(_ textField: UITextField) {
    if textField === address { textField.selectAll(nil) }
  }

  // MARK: Dialogs

  /// The page's alert, confirm or prompt, answered on the page; the host's `dialogClosed` takes it away.
  private func showDialog(type: String, message: String, defaultText: String, origin: String?) {
    guard !dialogShown, presentedViewController == nil else { return }
    let title =
      origin.map {
        String(format: String(localized: "browser.paneView.dialogTitleWithOrigin", defaultValue: "%1$@ says"), $0)
      } ?? String(localized: "browser.paneView.dialogTitleNoOrigin", defaultValue: "This page says")
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    if type == "prompt" {
      alert.addTextField { field in
        field.text = defaultText
        field.accessibilityLabel = String(localized: "browser.paneView.dialogAnswer", defaultValue: "Answer")
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
      }
    }
    if type != "alert" {
      alert.addAction(
        UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel) { [weak self] _ in
          self?.answerDialog("browser.dialogDismiss", text: nil)
        })
    }
    alert.addAction(
      UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default) { [weak self, weak alert] _ in
        self?.answerDialog("browser.dialogAccept", text: type == "prompt" ? alert?.textFields?.first?.text ?? "" : nil)
      })
    dialogShown = true
    present(alert, animated: true)
  }

  private func answerDialog(_ method: String, text: String?) {
    dialogShown = false
    guard let pageId = page.pageId else { return }
    let api = api
    let worktreeId = worktreeId
    Task {
      do {
        try await api.browserCommand(
          method, worktreeId: worktreeId, pageId: pageId, text.map { ["text": .string($0)] } ?? [:], timeout: .seconds(5))
      } catch {
        Toast.shared.show(
          String(localized: "browser.useBrowserCommands.dialogAnswerFailed", defaultValue: "That answer did not reach the page."),
          kind: .error)
      }
    }
  }
}

/// A label with room around its text, for the stream's error card.
private final class StreamErrorLabel: UILabel {
  private let insets = UIEdgeInsets(top: Spacing.sm, left: Spacing.md, bottom: Spacing.sm, right: Spacing.md)

  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
  }

  override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
    let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
    return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
  }
}
