import AVFoundation
import AVKit
import UIKit

/// What a picture-in-picture frame shows: a session's name and state, and the tail of what is happening in
/// it (a chat's latest words and calls, or a terminal's last lines).
struct PiPFrame: Equatable {
  enum Style: Equatable { case body, muted, call, terminal }

  var title: String
  var status: String
  var working: Bool
  var lines: [(text: String, style: Style)]
  /// A terminal's frame: monospaced on the terminal's ground.
  var terminal: Bool

  static func == (a: PiPFrame, b: PiPFrame) -> Bool {
    a.title == b.title && a.status == b.status && a.working == b.working && a.terminal == b.terminal
      && a.lines.map(\.text) == b.lines.map(\.text)
  }
}

/// Keeps watching a session after leaving the app: the system's picture-in-picture window plays frames drawn
/// here from the session on screen, a few times a second, and the app keeps running (and its connection to
/// the desktop open) while the window shows. Leaving the app starts it on its own when the setting is on;
/// the session's ⋯ menu starts it at once.
@MainActor
final class PiPCenter: NSObject {
  static let shared = PiPCenter()

  /// Leaving the app with a session on screen opens the picture-in-picture window.
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

  /// The frame for the session on screen; nil when there is nothing to show.
  var source: (() -> PiPFrame?)? {
    didSet {
      draw(force: true)
      dumpForDebugging()
    }
  }

  /// Launch with ORCA_DEBUG_PIP=1 to write the frame the window would show to tmp/pip.png, every second
  /// while a session is open (the simulator has no picture in picture to look at).
  private func dumpForDebugging() {
    guard ProcessInfo.processInfo.environment["ORCA_DEBUG_PIP"] == "1", debugTimer == nil else { return }
    debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let frame = self?.source?(), let image = PiPRenderer.image(for: frame, size: Self.size) else { return }
        try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pip.png"))
      }
    }
  }
  private var debugTimer: Timer?

  private let host = UIView()
  private let layer = AVSampleBufferDisplayLayer()
  private var controller: AVPictureInPictureController?
  private var timer: Timer?
  private var last: PiPFrame?
  private var lastDrawn = Date.distantPast
  private let silence = SilentAudio()
  private(set) var isActive = false
  /// The system starts picture in picture on leaving only from media that plays; idle, the frames read as
  /// paused, so nothing opens. Read from the playback delegate, off the main actor.
  nonisolated(unsafe) private static var playing = false
  /// The window was opened from the session menu: it stays even while idle.
  private var openedByHand = false

  /// The window's picture: 4:3, drawn at 2× for a sharp PiP window.
  private static let size = CGSize(width: 400, height: 300)

  var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

  /// Puts the (invisible) video layer behind `view`'s content: the system starts picture in picture only
  /// from a layer that is on screen.
  func attach(to view: UIView) {
    guard isSupported else { return }
    host.isUserInteractionEnabled = false
    host.alpha = 1
    host.frame = view.bounds
    host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    layer.frame = host.bounds
    layer.videoGravity = .resizeAspect
    if layer.superlayer == nil { host.layer.addSublayer(layer) }
    view.insertSubview(host, at: 0)
    if controller == nil {
      let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
      let controller = AVPictureInPictureController(contentSource: content)
      controller.delegate = self
      controller.requiresLinearPlayback = true
      self.controller = controller
    }
    // The system only starts automatically from "playing" media, so the audio session plays (silently,
    // mixed with whatever else is playing) while a session is on screen.
    silence.start()
    startTimer(interval: 1)
    draw(force: true)
  }

  func detach(from view: UIView) {
    guard host.superview === view, !isActive else { return }
    host.removeFromSuperview()
    source = nil
    timer?.invalidate()
    timer = nil
    silence.stop()
  }

  /// Another feature (dictation) took the audio session and let it go: play again so leaving the app still
  /// opens picture in picture.
  func reclaimAudio() {
    guard host.superview != nil else { return }
    silence.stop()
    silence.start()
  }

  /// Leaving opens the window only while the agent is working: there is nothing to watch otherwise.
  private func updateAutoStart() {
    let working = last?.working ?? false
    let wanted = Self.startsOnLeave && working
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
    guard let frame = source?() else { return }
    let now = Date()
    guard force || frame != last || now.timeIntervalSince(lastDrawn) > 4 else { return }
    last = frame
    lastDrawn = now
    updateAutoStart()
    guard let buffer = PiPRenderer.sampleBuffer(for: frame, size: Self.size) else { return }
    if layer.status == .failed { layer.flush() }
    layer.enqueue(buffer)
  }
}

extension PiPCenter: AVPictureInPictureControllerDelegate {
  nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      isActive = true
      startTimer(interval: 0.5)
      // Opened on its own when it shouldn't have (the setting is off, or nothing runs): close it again.
      if !openedByHand, !Self.startsOnLeave || !(last?.working ?? false) { controller.stopPictureInPicture() }
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      isActive = false
      openedByHand = false
      updateAutoStart()
      startTimer(interval: 1)
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
