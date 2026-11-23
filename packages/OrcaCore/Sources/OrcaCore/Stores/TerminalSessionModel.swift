import Foundation

/// One terminal tab's stream, turned into what an emulator view needs: a screen to load, bytes to feed.
/// The view owns the emulator; this owns the subscription, replays and input.
@MainActor
public final class TerminalSessionModel {
  public enum Phase: Sendable, Equatable {
    case connecting
    case live
    case failed(String)
  }

  /// Clear the emulator and feed this: the whole screen and scrollback as escape sequences.
  public var onSnapshot: (([UInt8]) -> Void)?
  public var onOutput: (([UInt8]) -> Void)?
  /// The size the host PTY actually has, which can differ from what the phone asked for.
  public var onHostSize: ((_ cols: Int, _ rows: Int) -> Void)?
  public var onPhase: ((Phase) -> Void)?

  public private(set) var phase: Phase = .connecting {
    didSet {
      if phase != oldValue {
        onPhase?(phase)
      }
    }
  }

  public let handle: String
  private let api: HostAPI
  private var cols: Int
  private var rows: Int
  private var streamTask: Task<Void, Never>?
  private var resizeTask: Task<Void, Never>?
  private var subscriptionId: String?
  private var inputChain: Task<Void, Never>?

  public init(api: HostAPI, handle: String, cols: Int, rows: Int) {
    self.api = api
    self.handle = handle
    self.cols = cols
    self.rows = rows
  }

  public func start() {
    guard streamTask == nil else {
      return
    }
    streamTask = Task { [weak self] in
      var delay: Duration = .milliseconds(300)
      while !Task.isCancelled {
        guard let self else {
          return
        }
        let subscription = await self.api.terminal(handle: self.handle, cols: self.cols, rows: self.rows)
        self.subscriptionId = subscription.requestId
        var decoder: TerminalFrameDecoder?
        var failure: String?
        do {
          read: for try await frame in subscription.frames {
            switch frame {
            case .reply(let reply):
              // A fresh `subscribed` follows every replay after a reconnect, with a new stream id.
              if reply["type"]?.stringValue == "subscribed", let streamId = reply["streamId"]?.intValue {
                decoder = TerminalFrameDecoder(streamId: UInt32(truncatingIfNeeded: streamId))
                self.noteSize(reply)
              } else if reply["type"]?.stringValue == "scrollback", let serialized = reply["serialized"]?.stringValue {
                // An old host without the binary stream answers with the screen as JSON.
                self.loaded(Array(serialized.utf8), meta: reply)
              }
            case .binary(let bytes):
              guard let terminalFrame = TerminalFrame(bytes), let event = decoder?.decode(terminalFrame) else {
                continue
              }
              switch event {
              case .snapshot(let serialized, let meta):
                self.loaded(serialized, meta: meta)
                delay = .milliseconds(300)
              case .output(let output):
                self.onOutput?(output)
              case .resized(let meta):
                self.noteSize(meta)
              case .metadata:
                break
              case .failed(let message):
                // The screen can no longer be trusted; a new subscription brings a fresh snapshot.
                failure = message
                break read
              }
            }
          }
        } catch let error as RPCError {
          failure = error.message.isEmpty ? error.code : error.message
        } catch {
          failure = nil
        }
        await self.api.connection.unsubscribe(subscription.requestId)
        self.subscriptionId = nil
        if let failure, self.phase != .live {
          self.phase = .failed(failure)
        } else {
          self.phase = .connecting
        }
        guard (try? await Task.sleep(for: delay)) != nil else {
          return
        }
        delay = min(delay * 2, .seconds(8))
      }
    }
  }

  public func stop() {
    streamTask?.cancel()
    streamTask = nil
    resizeTask?.cancel()
    if let subscriptionId {
      let connection = api.connection
      Task { await connection.unsubscribe(subscriptionId) }
    }
    subscriptionId = nil
  }

  /// The view's grid changed. Reported after a short pause so a keyboard animation or rotation sends one size.
  public func resize(cols: Int, rows: Int) {
    guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else {
      return
    }
    self.cols = min(cols, 1000)
    self.rows = min(rows, 500)
    resizeTask?.cancel()
    resizeTask = Task { [weak self] in
      guard (try? await Task.sleep(for: .milliseconds(120))) != nil, let self, let subscriptionId = self.subscriptionId else {
        return
      }
      await self.api.updateTerminalViewport(handle: self.handle, subscriptionId: subscriptionId, cols: self.cols, rows: self.rows)
    }
  }

  /// Keystrokes and pastes, escape sequences included. Sends are chained so they reach the PTY in typed order.
  public func send(_ text: String, isQueryReply: Bool = false) {
    // Input is never queued across a dropped stream: stale keystrokes landing later would be worse than losing them.
    guard !text.isEmpty, phase == .live else {
      return
    }
    let previous = inputChain
    let api = api
    let handle = handle
    inputChain = Task {
      await previous?.value
      try? await api.sendTerminalInput(text, handle: handle, isQueryReply: isQueryReply)
    }
  }

  /// The grid last asked for.
  public var requestedGrid: (cols: Int, rows: Int) {
    (cols, rows)
  }

  public var hostAPI: HostAPI {
    api
  }

  private func loaded(_ serialized: [UInt8], meta: JSONValue) {
    noteSize(meta)
    onSnapshot?(serialized)
    phase = .live
  }

  private func noteSize(_ meta: JSONValue) {
    if let cols = meta["cols"]?.intValue, let rows = meta["rows"]?.intValue, cols > 0, rows > 0 {
      onHostSize?(cols, rows)
    }
  }
}
