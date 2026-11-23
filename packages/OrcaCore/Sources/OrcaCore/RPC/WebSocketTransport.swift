import Foundation

public enum WebSocketMessage: Sendable, Equatable {
  case text(String)
  case binary([UInt8])
}

/// The peer closed the socket with a code, which a relay cell uses to say why.
public struct WebSocketClosedError: Error, Sendable, Equatable {
  public let code: Int

  public init(code: Int) {
    self.code = code
  }
}

/// One open socket. `send` must queue in call order: sealed frames carry ordered counters.
public protocol WebSocketTransport: Sendable {
  func send(_ message: WebSocketMessage, completion: @escaping @Sendable (Error?) -> Void)
  func receive() async throws -> WebSocketMessage
  func close()
}

public protocol WebSocketDialer: Sendable {
  func dial(_ url: URL) -> any WebSocketTransport
}

/// The system WebSocket, used everywhere outside tests.
public struct URLSessionWebSocketDialer: WebSocketDialer {
  private let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func dial(_ url: URL) -> any WebSocketTransport {
    let task = session.webSocketTask(with: url)
    // Terminal scrollback and transcript snapshots arrive as single large frames.
    task.maximumMessageSize = 64 * 1024 * 1024
    task.resume()
    return Socket(task: task)
  }

  private struct Socket: WebSocketTransport {
    let task: URLSessionWebSocketTask

    func send(_ message: WebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
      switch message {
      case .text(let text):
        task.send(.string(text), completionHandler: completion)
      case .binary(let bytes):
        task.send(.data(Data(bytes)), completionHandler: completion)
      }
    }

    func receive() async throws -> WebSocketMessage {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await task.receive()
      } catch {
        if task.closeCode != .invalid {
          throw WebSocketClosedError(code: task.closeCode.rawValue)
        }
        throw error
      }
      switch message {
      case .string(let text):
        return .text(text)
      case .data(let data):
        return .binary(Array(data))
      @unknown default:
        throw URLError(.cannotParseResponse)
      }
    }

    func close() {
      task.cancel(with: .normalClosure, reason: nil)
    }
  }
}
