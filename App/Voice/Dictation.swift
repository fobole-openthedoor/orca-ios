import AVFoundation
import Speech
import UIKit

/// Dictation on this phone: tap to listen, the words arrive as they are
/// recognised, tap again to stop. On-device recognition when the language supports it.
@MainActor
final class Dictation {
  static let shared = Dictation()

  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var onText: ((String) -> Void)?
  private var onEnd: (() -> Void)?
  private(set) var isListening = false

  private init() {}

  /// Asks for speech and microphone access the first time; false when either is refused.
  private func authorize() async -> Bool {
    let speech = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard speech == .authorized else { return false }
    return await AVAudioApplication.requestRecordPermission()
  }

  /// Starts listening; `onText` receives the whole transcript so far each time it changes.
  func start(onText: @escaping (String) -> Void, onEnd: @escaping () -> Void) async -> String? {
    stop()
    guard await authorize() else {
      return String(localized: "orcaios.dictation.denied", defaultValue: "Allow Microphone and Speech Recognition for Orca in Settings.")
    }
    let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    guard let recognizer, recognizer.isAvailable else {
      return String(localized: "orcaios.dictation.unavailable", defaultValue: "Dictation isn't available right now.")
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.addsPunctuation = true
      if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
      engine.prepare()
      try engine.start()
      self.request = request
      self.onText = onText
      self.onEnd = onEnd
      isListening = true
      task = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let text = result?.bestTranscription.formattedString
        let done = error != nil || result?.isFinal == true
        Task { @MainActor in
          guard let self else { return }
          if let text { self.onText?(text) }
          if done { self.stop() }
        }
      }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      return nil
    } catch {
      stop()
      return error.localizedDescription
    }
  }

  func stop() {
    guard isListening else { return }
    isListening = false
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    task?.finish()
    request = nil
    task = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    PiPCenter.shared.reclaimAudio()
    let end = onEnd
    onText = nil
    onEnd = nil
    end?()
  }
}
