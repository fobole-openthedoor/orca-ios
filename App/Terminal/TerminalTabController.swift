import GhosttyTerminal
import OrcaCore
import PhotosUI
import UIKit

/// One terminal tab. Ghostty draws and handles touch, keyboard and IME; the host owns the PTY.
/// The emulator's grid is always the host PTY's grid: the phone asks for what fits, and frames the view
/// to whatever the host confirms. The keyboard never resizes the PTY; the screen slides up instead.
final class TerminalTabController: UIViewController, WorkspaceContent, TerminalSurfaceGridResizeDelegate,
  TerminalSurfaceOpenURLHandlingDelegate, TerminalSurfaceClipboardConfirmationDelegate
{
  private let api: HostAPI
  private let handle: String
  private let sendsQueryReplies: Bool
  private var model: TerminalSessionModel?

  private let container = UIView()
  private let terminal = OrcaTerminalView(frame: .zero)
  private let ghostty: GhosttyTerminal.TerminalController
  /// The surface holds the session unretained, so this controller keeps it alive for the view's lifetime.
  private var session: InMemoryTerminalSession!
  private let statusPill = GlassSurface(interactive: false, visible: false)
  private let statusLabel = UILabel()
  private let statusSpinner = UIActivityIndicatorView(style: .medium)
  private let failureCard = UIView()
  private let failureLabel = UILabel()

  /// Device pixels per cell, from the surface's own metrics.
  private var cellPixels = CGSize.zero
  private var scale: CGFloat { view.window?.screen.nativeScale ?? traitCollection.displayScale }
  /// The grid the host last confirmed.
  private var hostGrid: (cols: Int, rows: Int)?
  /// The grid the engine has applied, as its IO thread reported it.
  private var appliedGrid: (cols: Int, rows: Int)?
  /// A snapshot waits until the engine has the host's grid, or it would be parsed at the old width and reflowed.
  private var pendingSnapshot: [UInt8]?
  private var heldOutput: [[UInt8]] = []
  private var snapshotDeadline: Task<Void, Never>?
  private var refit: Task<Void, Never>?
  private var keyboardVisible = false
  private var fullHeight: CGFloat = 0
  private var observers: [NSObjectProtocol] = []
  #if DEBUG
    private var debugTyped = false
  #endif

  /// The desktop's palette for this terminal, so its background also paints the area around the grid.
  private let colors: [String: String]?

  private let matchesTranscript: Bool

  init(api: HostAPI, handle: String, sendsQueryReplies: Bool, colors: [String: String]? = nil, matchesTranscript: Bool = false) {
    self.colors = colors
    self.matchesTranscript = matchesTranscript
    self.api = api
    self.handle = handle
    self.sendsQueryReplies = sendsQueryReplies
    let fontSize = TerminalAppearance.fontSize
    ghostty = GhosttyTerminal.TerminalController(
      configSource: .none, theme: TerminalAppearance.theme(colors: colors),
      terminalConfiguration: TerminalAppearance.configuration(fontSize: fontSize, colors: colors))
    super.init(nibName: nil, bundle: nil)
    session = InMemoryTerminalSession(
      write: { [weak self] data in
        DispatchQueue.main.async { self?.emulatorWrote(data) }
      },
      resize: { [weak self] viewport in
        DispatchQueue.main.async { self?.emulatorApplied(cols: Int(viewport.columns), rows: Int(viewport.rows)) }
      },
      suppressesPixelOnlyResizes: true)
    terminal.delegate = self
    terminal.controller = ghostty
    terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: fontSize)
    // iGhostVT's bar, less Paste: the bar's own Paste key cannot be routed through the upload of images.
    terminal.inputAccessoryItems = TerminalInputAccessoryItem.defaultItems.filter { $0 != .paste }
    terminal.onPaste = { [weak self] in self?.pasteFromPasteboard() ?? false }
  }

  /// The terminal's visible rows for picture in picture, trailing blank rows dropped.
  func pipLines() -> [String] {
    var rows = (session?.readViewportText() ?? "").components(separatedBy: "\n").map {
      $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
    while rows.last?.isEmpty == true { rows.removeLast() }
    return rows
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    updateBackground()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
      self.updateBackground()
    }

    container.clipsToBounds = true
    container.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(container)
    terminal.backgroundColor = .clear
    terminal.isOpaque = false
    container.addSubview(terminal)
    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      container.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
    ])
    buildStatusViews()
    buildDock()

    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.keyboardChanged(visible: true) }
    })
    // A hardware keyboard shows only the key bar, which may arrive as a frame change rather than a show.
    observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) {
      [weak self] note in
      let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
      MainActor.assumeIsolated {
        guard let self, let screen = self.view.window?.screen else { return }
        let visible = end.height > 0 && end.minY < screen.bounds.height
        if visible != self.keyboardVisible { self.keyboardChanged(visible: visible) }
      }
    })
    observers.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.keyboardChanged(visible: false) }
    })
    // A screen that sat in the background is not trusted: a fresh subscription brings a fresh snapshot.
    observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.restart() }
    })
  }

  private func updateBackground() {
    let ground = TerminalAppearance.background(for: traitCollection, colors: colors)
    view.backgroundColor = ground
    if matchesTranscript { dock.backgroundColor = ground }
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if !keyboardVisible {
      fullHeight = container.bounds.height
    }
    // Until the host has answered, the view fills the container so the surface can report its cells.
    if hostGrid == nil, terminal.bounds.size != container.bounds.size {
      terminal.frame = container.bounds
    }
    scheduleRefit()
    layoutTerminal()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    terminal.setSurfaceVisible(true)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    terminal.setSurfaceVisible(false)
  }

  func close() {
    refit?.cancel()
    snapshotDeadline?.cancel()
    model?.stop()
    model = nil
  }

  // MARK: Stream

  private func start(cols: Int, rows: Int) {
    guard model == nil else {
      return
    }
    let model = TerminalSessionModel(api: api, handle: handle, cols: cols, rows: rows)
    model.onSnapshot = { [weak self] serialized in
      self?.load(serialized)
    }
    model.onOutput = { [weak self] bytes in
      self?.output(bytes)
    }
    model.onHostSize = { [weak self] cols, rows in
      self?.hostGrid = (cols, rows)
      self?.layoutTerminal()
      self?.replayIfReady()
    }
    model.onPhase = { [weak self] phase in
      self?.show(phase)
    }
    self.model = model
    show(model.phase)
    model.start()
  }

  private func restart() {
    guard view.window != nil, let model else {
      return
    }
    let grid = model.requestedGrid
    close()
    start(cols: grid.cols, rows: grid.rows)
  }

  private func load(_ serialized: [UInt8]) {
    pendingSnapshot = serialized
    heldOutput = []
    snapshotDeadline?.cancel()
    // Should the engine never report the grid (it already had it), the screen is not held for long.
    snapshotDeadline = Task { [weak self] in
      guard (try? await Task.sleep(for: .milliseconds(300))) != nil else {
        return
      }
      self?.replay()
    }
    replayIfReady()
  }

  private func replayIfReady() {
    guard pendingSnapshot != nil, let hostGrid, let appliedGrid, hostGrid == appliedGrid else {
      return
    }
    replay()
  }

  /// One write, so the renderer goes from the old screen to the new one without drawing the blank between.
  /// Queries inside a replay are not answered.
  private func replay() {
    guard let snapshot = pendingSnapshot else {
      return
    }
    pendingSnapshot = nil
    snapshotDeadline?.cancel()
    session.discardPendingOutput()
    session.receiveReplay(Data("\u{1b}c\u{1b}[3J".utf8) + Data(snapshot))
    for chunk in heldOutput {
      session.receive(Data(chunk))
    }
    heldOutput = []
  }

  private func output(_ bytes: [UInt8]) {
    if pendingSnapshot != nil {
      heldOutput.append(bytes)
    } else {
      session.receive(Data(bytes))
    }
  }

  private func emulatorApplied(cols: Int, rows: Int) {
    appliedGrid = (cols, rows)
    replayIfReady()
  }

  /// Keystrokes, pastes and mouse reports are the user's; the rest are the engine answering a program.
  private func emulatorWrote(_ data: Data) {
    // Legacy mouse reports are not valid UTF-8 and cannot travel as text.
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
      return
    }
    if TerminalQueryReply.isReply(text) {
      // A host that cannot order replies apart from typing gets none, as the official client does.
      if sendsQueryReplies {
        model?.send(text, isQueryReply: true)
      }
    } else {
      // A modifier armed on the key row applies to the key typed next.
      model?.send(dock.apply(text))
    }
  }

  // MARK: Sizing

  func terminalDidResize(_ size: TerminalGridMetrics) {
    guard size.cellWidthPixels > 0, size.cellHeightPixels > 0 else {
      return
    }
    let cell = CGSize(width: CGFloat(size.cellWidthPixels), height: CGFloat(size.cellHeightPixels))
    let cellChanged = cell != cellPixels
    cellPixels = cell
    if model == nil, let grid = requestedGrid() {
      start(cols: grid.cols, rows: grid.rows)
    } else if cellChanged {
      // A pinch or Cmd-plus changed the cell: ask for what now fits, and re-frame when the host answers.
      if let size = terminal.fontSize {
        TerminalAppearance.fontSize = size
      }
      scheduleRefit()
      layoutTerminal()
    }
  }

  /// The grid the visible area can hold. While the keyboard is up the height is not trusted: the keyboard
  /// must not resize the PTY, so the last full-height answer stands.
  private func requestedGrid() -> (cols: Int, rows: Int)? {
    guard cellPixels.width > 0, container.bounds.width > 0 else {
      return nil
    }
    let height = keyboardVisible ? fullHeight : container.bounds.height
    return TerminalInput.grid(
      width: Double(container.bounds.width * scale), height: Double(height * scale),
      cellWidth: Double(cellPixels.width), cellHeight: Double(cellPixels.height))
  }

  private func scheduleRefit() {
    guard model != nil else {
      return
    }
    refit?.cancel()
    refit = Task { [weak self] in
      // One answer per burst of layout passes: a rotation or split-view drag sends a single size.
      guard (try? await Task.sleep(for: .milliseconds(150))) != nil, let self, let grid = self.requestedGrid() else {
        return
      }
      self.model?.resize(cols: grid.cols, rows: grid.rows)
    }
  }

  /// Frames the view to exactly the host's grid, scaled down when the desktop's grid is wider than the phone.
  private func layoutTerminal() {
    guard cellPixels.width > 0, let grid = hostGrid else {
      return
    }
    // Half a pixel over, so the surface's rounding down cannot lose a column.
    let size = CGSize(
      width: (CGFloat(grid.cols) * cellPixels.width + 0.5) / scale,
      height: (CGFloat(grid.rows) * cellPixels.height + 0.5) / scale)
    var factor = min(1, container.bounds.width / size.width)
    if factor >= 0.95 {
      factor = 1
    }
    terminal.transform = .identity
    if terminal.bounds.size != size {
      terminal.frame = CGRect(origin: .zero, size: size)
    }
    terminal.layer.anchorPoint = .zero
    terminal.layer.position = .zero
    terminal.transform = CGAffineTransform(scaleX: factor, y: factor)
    liftForKeyboard()
  }

  /// With the keyboard up, slides the screen so the cursor's row stays in view.
  private func liftForKeyboard() {
    let visible = container.bounds.height
    let factor = terminal.transform.a
    let height = terminal.bounds.height * factor
    var offset: CGFloat = 0
    if height > visible {
      let cursorBottom = (terminal.caretRect(for: terminal.beginningOfDocument).maxY + cellPixels.height / scale) * factor
      offset = max(visible - height, min(0, visible - cursorBottom))
    }
    if abs(terminal.layer.position.y - offset) > 0.5 {
      terminal.layer.position.y = offset
    }
  }

  private let dock = TerminalDock()
  private var aboveDock: NSLayoutConstraint?

  /// The resting key row and Live input field, under the terminal while the keyboard is down.
  private func buildDock() {
    view.addSubview(dock)
    let aboveDock = container.bottomAnchor.constraint(equalTo: dock.topAnchor)
    aboveDock.priority = .defaultHigh
    self.aboveDock = aboveDock
    let onKeyboard = container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
    onKeyboard.priority = .defaultLow
    NSLayoutConstraint.activate([
      onKeyboard,
      dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      dock.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      aboveDock,
    ])
    dock.onKey = { [weak self] text in self?.model?.send(text) }
    // Text goes through Ghostty so a shell sees it bracketed; an image is uploaded and its host path typed.
    dock.onPasteText = { [weak self] text in self?.terminal.pasteWithProtection(text: text) }
    dock.onPasteImage = { [weak self] data in
      guard let self, let image = UIImage(data: data) else { return }
      self.uploadAndType(image)
    }
    dock.onDictated = { [weak self] text in self?.terminal.pasteWithProtection(text: text) }
    dock.onError = { message in Toast.shared.show(message, kind: .error) }
    dock.onImage = { [weak self] in self?.pickImage() }
    dock.onShowKeyboard = { [weak self] in
      guard let self, self.terminal.becomeFirstResponder() else { return }
      self.keyboardChanged(visible: true)
    }
  }

  private func keyboardChanged(visible: Bool) {
    dock.isHidden = visible
    aboveDock?.isActive = !visible
    keyboardVisible = visible
    view.layoutIfNeeded()
    liftForKeyboard()
  }

  // MARK: Paste

  /// Images go to the host first and their host path is typed. Text is left to Ghostty, which brackets it.
  private func pasteFromPasteboard() -> Bool {
    let pasteboard = UIPasteboard.general
    guard pasteboard.hasImages, !pasteboard.hasStrings, !pasteboard.hasURLs, let image = pasteboard.image else {
      return false
    }
    uploadAndType(image)
    return true
  }

  /// The dock's image button: a photo from the library, uploaded and typed as its host path.
  private func pickImage() {
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 1
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    present(picker, animated: true)
  }

  /// Uploads an image to the host and types its path, escaped for the shell.
  private func uploadAndType(_ image: UIImage) {
    guard let data = image.pngData(), let attachment = AttachmentIntake.image(data, name: "image.png") else {
      return
    }
    showStatus(L("Uploading image…"), spinning: true)
    let api = api
    Task { [weak self] in
      do {
        let path = try await api.uploadImage(attachment.data, fileName: attachment.name, connectionId: nil)
        guard let self else {
          return
        }
        self.hideStatus()
        self.terminal.pasteWithProtection(text: Self.shellEscaped(path) + " ")
      } catch {
        self?.hideStatus()
        Toast.shared.show(L("The image could not be uploaded"), kind: .error)
      }
    }
  }

  /// A path as a shell reads it, each sensitive character behind a backslash (Ghostty's own rule).
  static func shellEscaped(_ path: String) -> String {
    let sensitive: Set<Character> = [
      "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`", "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]
    return path.reduce(into: "") { out, character in
      if sensitive.contains(character) {
        out.append("\\")
      }
      out.append(character)
    }
  }

  // MARK: Links and clipboard

  func terminalShouldHandleOpenURL(_ url: String, kind: TerminalOpenURLKind) -> Bool {
    guard let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased() ?? "") else {
      return false
    }
    UIApplication.shared.open(link)
    return true
  }

  func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
    let title: String
    let message: String
    let preview = Self.preview(request.contents)
    switch request.kind {
    case .paste:
      title = L("Paste Unsafe Text?")
      message = String(format: L("This text contains line breaks or hidden characters that the program may run as commands: %@"), preview)
    case .osc52Read:
      title = L("Allow Clipboard Access?")
      message = String(format: L("A program in this terminal wants to read the clipboard: %@"), preview)
    case .osc52Write:
      title = L("Allow Clipboard Change?")
      message = String(format: L("A program in this terminal wants to replace the clipboard with: %@"), preview)
    }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("Deny"), style: .cancel) { _ in request.respond(allow: false) })
    let allow = UIAlertAction(title: L("Allow"), style: .default) { _ in request.respond(allow: true) }
    alert.addAction(allow)
    alert.preferredAction = allow
    present(alert, animated: true)
  }

  private static func preview(_ contents: String) -> String {
    let flat = contents.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ")
    return "“" + (flat.count > 120 ? String(flat.prefix(120)) + "…" : flat) + "”"
  }

  // MARK: Status

  private func buildStatusViews() {
    statusPill.cornerConfiguration = .capsule()
    statusPill.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .dynamic(15, weight: .medium)
    statusSpinner.hidesWhenStopped = true
    let row = UIStackView(arrangedSubviews: [statusSpinner, statusLabel])
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    statusPill.contentView.addSubview(row)
    view.addSubview(statusPill)

    failureCard.backgroundColor = UIColor.black.withAlphaComponent(0.25)
    failureCard.isHidden = true
    failureCard.translatesAutoresizingMaskIntoConstraints = false
    let card = GlassSurface()
    card.cornerConfiguration = .corners(radius: .fixed(24))
    card.translatesAutoresizingMaskIntoConstraints = false
    let title = UILabel()
    title.text = L("Terminal Unavailable")
    title.font = .dynamic(17, weight: .semibold)
    failureLabel.font = .dynamic(15)
    failureLabel.textColor = .secondaryLabel
    failureLabel.numberOfLines = 0
    let retry = UIButton(configuration: .orcaProminent(), primaryAction: UIAction(title: L("Retry")) { [weak self] _ in
      self?.failureCard.isHidden = true
      self?.restart()
    })
    let stack = UIStackView(arrangedSubviews: [title, failureLabel, retry])
    stack.axis = .vertical
    stack.spacing = 12
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.contentView.addSubview(stack)
    failureCard.addSubview(card)
    view.addSubview(failureCard)

    NSLayoutConstraint.activate([
      statusPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusPill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      row.topAnchor.constraint(equalTo: statusPill.contentView.topAnchor, constant: 12),
      row.bottomAnchor.constraint(equalTo: statusPill.contentView.bottomAnchor, constant: -12),
      row.leadingAnchor.constraint(equalTo: statusPill.contentView.leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: statusPill.contentView.trailingAnchor, constant: -16),
      failureCard.topAnchor.constraint(equalTo: view.topAnchor),
      failureCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      failureCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      failureCard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      card.centerYAnchor.constraint(equalTo: failureCard.centerYAnchor),
      card.leadingAnchor.constraint(equalTo: failureCard.leadingAnchor, constant: 24),
      card.trailingAnchor.constraint(equalTo: failureCard.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -20),
      stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
    ])
  }

  private func show(_ phase: TerminalSessionModel.Phase) {
    switch phase {
    case .connecting:
      showStatus(L("Connecting…"), spinning: true)
    case .live:
      hideStatus()
      failureCard.isHidden = true
      #if DEBUG
        // Simulator verification: type a line once, as nothing can press keys there.
        if let typed = ProcessInfo.processInfo.environment["ORCA_DEBUG_TYPE"], !debugTyped {
          debugTyped = true
          Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            self?.model?.send(typed.replacingOccurrences(of: "\\r", with: "\r"))
          }
        }
      #endif
    case .failed(let reason):
      hideStatus()
      failureLabel.text = reason
      failureCard.isHidden = false
      _ = terminal.resignFirstResponder()
    }
  }

  private func showStatus(_ text: String, spinning: Bool) {
    statusLabel.text = text
    spinning ? statusSpinner.startAnimating() : statusSpinner.stopAnimating()
    statusPill.setVisible(true, animated: true)
  }

  private func hideStatus() {
    statusPill.setVisible(false, animated: true)
  }
}

extension TerminalTabController: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      guard let image = object as? UIImage else { return }
      DispatchQueue.main.async { self?.uploadAndType(image) }
    }
  }
}
