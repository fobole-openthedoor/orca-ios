import AVFoundation
import AVKit
import Observation
import OrcaCore
import UIKit

/// A session transcript or a status snapshot of the paired hosts.
struct PiPFrame: Equatable {
  enum Style: Equatable { case body, muted, call, terminal }
  struct StatusLine: Hashable {
    var agent: String
    let agentType: String?
    let isWorker: Bool
    let host: String
    var showsHostSubtitle = false
    var activity: WorkingAgent.Activity = .working
    var leadWorking = false
    var childTypes: [String?] = []
    var totalTokens: Int?
    var tokenCountIsPartial = false
    var toolCount: String?
    var toolRunning = false
  }
  struct ScrollState: Equatable {
    let activities: [WorkingAgent.Activity]
    let activeIndices: [Int]
    let pinsFirstRow: Bool
  }
  struct StatusRow: Equatable {
    let id: WorkingAgent.ID
    let line: StatusLine
  }

  var title: String
  var status: String
  var working: Bool
  var lines: [(text: String, style: Style)]
  /// A terminal's frame: monospaced on the terminal's ground.
  var terminal: Bool
  var statusRows: [StatusRow] = []
  var scrollState: ScrollState?
  var statusAvailable = true

  static func == (a: PiPFrame, b: PiPFrame) -> Bool {
    a.title == b.title && a.status == b.status && a.working == b.working
      && a.terminal == b.terminal && a.statusRows == b.statusRows && a.scrollState == b.scrollState
      && a.statusAvailable == b.statusAvailable
      && a.lines.elementsEqual(b.lines) { $0.text == $1.text && $0.style == $1.style }
  }
}

enum PiPLayout {
  case transcript, compact

  var size: CGSize {
    switch self {
    case .transcript: CGSize(width: 400, height: 300)
    case .compact: CGSize(width: 400, height: 68)
    }
  }
}

/// Keeps the app's host connections open while picture in picture is on screen.
@MainActor
final class PiPCenter: NSObject {
  static let shared = PiPCenter()

  /// Leaving the app opens picture in picture when the selected layout has active work.
  static var startsOnLeave: Bool {
    get { UserDefaults.standard.object(forKey: "orca.pip.auto") as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: "orca.pip.auto")
      shared.updateAutoStart()
    }
  }

  /// A chat in the window lists each command; off, a run of them reads as one line, as in the chat.
  static var showsCommands: Bool {
    get { UserDefaults.standard.bool(forKey: "orca.pip.commands") }
    set {
      UserDefaults.standard.set(newValue, forKey: "orca.pip.commands")
      shared.draw(force: true)
    }
  }

  static var usesCompactLayout: Bool {
    get { UserDefaults.standard.bool(forKey: "orca.pip.compact") }
    set {
      UserDefaults.standard.set(newValue, forKey: "orca.pip.compact")
      shared.refreshAttachment()
    }
  }

  private static var layout: PiPLayout { usesCompactLayout ? .compact : .transcript }

  /// Launch with ORCA_DEBUG_PIP=1 to write the frame the window would show to tmp/pip.png, every second
  /// (the simulator has no picture in picture to look at).
  private func dumpForDebugging() {
    guard ProcessInfo.processInfo.environment["ORCA_DEBUG_PIP"] == "1", debugTimer == nil else { return }
    debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let frame = self?.last ?? self?.frame()?.content else { return }
        let image = PiPRenderer.image(for: frame, layout: Self.layout)
        try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pip.png"))
      }
    }
  }
  private var debugTimer: Timer?

  private let host = UIView()
  private let layer = AVSampleBufferDisplayLayer()
  private weak var compactHost: UIView?
  private weak var sessionHost: UIView?
  private var transcriptFrame: (() -> PiPFrame?)?
  private var workStatus: PiPWorkStatus?
  private var rotation = WorkingAgentRotation()
  private var waitingAgents: Set<WorkingAgent.ID> = []
  private let telemetry = PiPAgentTelemetry()
  private var controller: AVPictureInPictureController?
  private var timer: Timer?
  private var last: PiPFrame?
  private var lastLayout: PiPLayout?
  private var transition: Task<Void, Never>?
  private var lastDrawn = Date.distantPast
  private let silence = SilentAudio()
  private(set) var isActive = false
  /// The system starts picture in picture on leaving only from media that plays; idle, the frames read as
  /// paused, so nothing opens. Read from the playback delegate, off the main actor.
  nonisolated(unsafe) private static var playing = false
  /// The window was opened from the session menu: it stays even while idle.
  private var openedByHand = false

  var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

  func attachCompact(to view: UIView) {
    compactHost = view
    refreshAttachment()
  }

  func attachTranscript(to view: UIView, source: @escaping () -> PiPFrame?) {
    sessionHost = view
    transcriptFrame = source
    if !Self.usesCompactLayout { refreshAttachment() }
  }

  func detachTranscript(from view: UIView) {
    guard sessionHost === view, !isActive || Self.usesCompactLayout else { return }
    sessionHost = nil
    transcriptFrame = nil
    if !Self.usesCompactLayout { refreshAttachment() }
  }

  /// The source layer must be in the live window for iOS to offer picture in picture.
  private func refreshAttachment() {
    dumpForDebugging()
    if !Self.usesCompactLayout || compactHost == nil { telemetry.follow([], model: AppModel.shared) }
    guard isSupported else { return }
    guard let view = Self.usesCompactLayout ? compactHost : sessionHost else {
      host.removeFromSuperview()
      cancelTransition()
      timer?.invalidate()
      timer = nil
      last = nil
      lastLayout = nil
      updateAutoStart()
      return
    }
    host.isUserInteractionEnabled = false
    host.alpha = 1
    host.frame = view.bounds
    host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    layer.frame = host.bounds
    layer.videoGravity = .resizeAspect
    if layer.superlayer == nil { host.layer.addSublayer(layer) }
    if host.superview !== view { view.insertSubview(host, at: 0) }
    if controller == nil {
      let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
      let controller = AVPictureInPictureController(contentSource: content)
      controller.delegate = self
      controller.requiresLinearPlayback = true
      self.controller = controller
    }
    if timer == nil { startTimer(interval: 1) }
    draw(force: true)
  }

  private func frame() -> (content: PiPFrame, didAdvance: Bool, scrollsOnlySecondRow: Bool)? {
    guard Self.usesCompactLayout else {
      guard let transcript = transcriptFrame?() else { return nil }
      return (transcript, false, false)
    }
    let status: PiPWorkStatus
    if let workStatus {
      status = workStatus
    } else {
      status = withObservationTracking {
        PiPWorkStatus(model: AppModel.shared)
      } onChange: { [weak self] in
        Task { @MainActor in
          self?.workStatus = nil
          if Self.usesCompactLayout { self?.draw(force: false) }
        }
      }
      workStatus = status
    }
    let time = ProcessInfo.processInfo.systemUptime
    let waiting = status.entries.filter { $0.activity != .working }.map(\.id)
    let newlyWaiting = waiting.first { !waitingAgents.contains($0) }
    waitingAgents = Set(waiting)
    let pinned = waiting.count == 1 && status.entries.count > 2 ? waiting.first : nil
    let page = rotation.page(
      in: status.entries.map(\.id), at: time, rotating: isActive,
      preferring: pinned == nil ? newlyWaiting : nil, pinned: pinned)
    let entries = page.indices.map { status.entries[$0] }
    if isActive {
      var targets = Set(entries.compactMap(\.session))
      if let next = page.nextIndex, let key = status.entries[next].session { targets.insert(key) }
      telemetry.follow(targets, model: AppModel.shared)
    }
    return (
      status.frame(showing: entries, page: page) { telemetry.reading($0) },
      page.didAdvance,
      page.scrollsOnlySecondRow
    )
  }

  /// Another feature (dictation) took the audio session and let it go: play again so leaving the app still
  /// opens picture in picture.
  func reclaimAudio() {
    guard host.superview != nil else { return }
    silence.stop()
    updateAutoStart()
  }

  /// Leaving opens the window only while the agent is working: there is nothing to watch otherwise.
  private func updateAutoStart() {
    let working = last?.working ?? false
    let attached = host.superview != nil
    let wanted = attached && Self.startsOnLeave && working
    if controller?.canStartPictureInPictureAutomaticallyFromInline != wanted {
      controller?.canStartPictureInPictureAutomaticallyFromInline = wanted
    }
    // Playing is what the system auto-starts from: only when leaving should open it, or the window is open
    // because the person asked.
    let playing = openedByHand || wanted
    if Self.playing != playing {
      Self.playing = playing
      controller?.invalidatePlaybackState()
    }
    // Keep an open overlay updating. The app-wide layout can release audio while it has nothing to show.
    if attached && (isActive || playing || !Self.usesCompactLayout) { silence.start() } else { silence.stop() }
  }

  /// The app is about to go: decide from what is on screen right now, not the last frame drawn.
  func appWillResignActive() {
    guard host.superview != nil else { return }
    draw(force: true)
    updateAutoStart()
  }

  /// Back in the app, the window goes: the session it showed is on screen again.
  func appBecameActive() {
    guard isActive else { return }
    controller?.stopPictureInPicture()
  }

  func start() {
    guard host.superview != nil else { return }
    openedByHand = true
    updateAutoStart()
    draw(force: true)
    controller?.startPictureInPicture()
  }

  func stop() {
    controller?.stopPictureInPicture()
  }

  private func startTimer(interval: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { PiPCenter.shared.draw(force: false) }
    }
  }

  /// Draws a new frame when the content changed, and at least every few seconds so the layer stays live.
  private func draw(force: Bool) {
    guard host.superview != nil else { return }
    guard let (frame, didAdvance, scrollsOnlySecondRow) = frame() else {
      if last != nil {
        last = nil
        cancelTransition()
        layer.flushAndRemoveImage()
      }
      updateAutoStart()
      return
    }
    let layout = Self.layout
    let now = Date()
    guard force || frame != last || layout != lastLayout || now.timeIntervalSince(lastDrawn) > 4 else { return }
    let previous = layout == .compact && lastLayout == .compact ? last?.statusRows : nil
    if lastLayout != layout { layer.flushAndRemoveImage() }
    last = frame
    lastLayout = layout
    lastDrawn = now
    updateAutoStart()
    let animate = isActive && !UIAccessibility.isReduceMotionEnabled && layout == .compact
    // Update telemetry during the animation without interrupting the rows that are already moving.
    if animate, transition != nil, previous?.map(\.id) == frame.statusRows.map(\.id) { return }
    cancelTransition()
    if animate, didAdvance, let previous, previous.count == 2, frame.statusRows.count == 2 {
      if scrollsOnlySecondRow, previous[0].id == frame.statusRows[0].id, previous[1].id != frame.statusRows[1].id {
        scroll(leaving: previous[1].line, onlySecondRow: true)
        return
      }
      if !scrollsOnlySecondRow, previous[1].id == frame.statusRows[0].id {
        scroll(leaving: previous[0].line, onlySecondRow: false)
        return
      }
    }
    enqueue(frame, layout: layout)
  }

  private func cancelTransition() {
    transition?.cancel()
    transition = nil
  }

  private func scroll(leaving line: PiPFrame.StatusLine, onlySecondRow: Bool) {
    transition = Task { [weak self] in
      let start = ProcessInfo.processInfo.systemUptime
      let duration: TimeInterval = 0.3
      while !Task.isCancelled, let self, let frame = last {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let progress = min(CGFloat(elapsed / duration), 1)
        enqueue(frame, layout: .compact, leaving: line, onlySecondRow: onlySecondRow, progress: progress)
        if progress == 1 {
          transition = nil
          return
        }
        if (try? await Task.sleep(for: .milliseconds(33))) == nil { return }
      }
    }
  }

  private func enqueue(
    _ frame: PiPFrame, layout: PiPLayout, leaving: PiPFrame.StatusLine? = nil,
    onlySecondRow: Bool = false, progress: CGFloat = 1
  ) {
    guard let buffer = PiPRenderer.sampleBuffer(
      for: frame, layout: layout, leaving: leaving, onlySecondRow: onlySecondRow, progress: progress)
    else { return }
    if layer.status == .failed { layer.flush() }
    layer.enqueue(buffer)
  }
}

extension PiPCenter: AVPictureInPictureControllerDelegate {
  nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      isActive = true
      updateAutoStart()
      startTimer(interval: 0.5)
      // Opened on its own when it shouldn't have (the setting is off, or nothing runs): close it again.
      if !openedByHand, !Self.startsOnLeave || !(last?.working ?? false) { controller.stopPictureInPicture() }
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      isActive = false
      telemetry.follow([], model: AppModel.shared)
      cancelTransition()
      openedByHand = false
      updateAutoStart()
      if host.superview != nil { startTimer(interval: 1) }
    }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
  ) {
    MainActor.assumeIsolated {
      openedByHand = false
      updateAutoStart()
    }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
  ) {
    completion(true)
  }
}

extension PiPCenter: AVPictureInPictureSampleBufferPlaybackDelegate {
  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

  /// Live: no start, no end, nothing to scrub.
  nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    !PiPCenter.playing
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void
  ) {
    completion()
  }
}

/// A silent, mixable playback session: the system keeps an app that plays running in the background, which
/// keeps the picture-in-picture window and the desktop connection live. Other audio keeps playing.
private final class SilentAudio {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var running = false

  func start() {
    guard !running else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
      try session.setActive(true)
      let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
      if player.engine == nil {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
      }
      engine.mainMixerNode.outputVolume = 0
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
      buffer.frameLength = buffer.frameCapacity
      try engine.start()
      player.scheduleBuffer(buffer, at: nil, options: .loops)
      player.play()
      running = true
    } catch {
      running = false
    }
  }

  func stop() {
    guard running else { return }
    player.stop()
    engine.stop()
    running = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
