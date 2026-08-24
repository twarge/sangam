import Foundation
import JitsiBridge

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// What the bridge channel reports back to its owner: a parsed colibri message
/// from the bridge, or the channel dying.
public enum BridgeChannelEvent: Sendable {
  case message(ColibriMessage)
  /// The socket failed or was closed by the far side. The bridge's control
  /// messages stop with it, so the owner must at least know — a silently dead
  /// channel looks identical to a healthy quiet one.
  case closed(reason: String)
}

/// The Jitsi Videobridge "colibri" bridge channel — a WebSocket, advertised in
/// the session-initiate transport, over which the client tells the bridge which
/// remote video it wants (receiver video constraints) and receives the bridge's
/// control messages (forwarded sources, sender constraints, dominant speaker…).
///
/// It is required for receiving: a modern videobridge forwards a remote's video
/// only once the client has asked for it here. Without the channel, every
/// remote tile is black even though the Jingle session negotiated fine.
public actor BridgeChannel {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let onEvent: @Sendable (BridgeChannelEvent) -> Void
  private let parser = ColibriParser()
  private var receiveTask: Task<Void, Never>?
  private var closed = false

  public init(url: URL, onEvent: @escaping @Sendable (BridgeChannelEvent) -> Void = { _ in }) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    session = URLSession(configuration: configuration)
    task = session.webSocketTask(with: url)
    self.onEvent = onEvent
  }

  public func open() {
    guard !closed else { return }
    task.resume()
    receiveTask = Task { [weak self] in await self?.readLoop() }
  }

  /// Sends receiver video constraints. Queued by `URLSessionWebSocketTask`
  /// until the connection opens, so it is safe to call right after `open()`.
  public func send(_ constraints: ReceiverVideoConstraints) async throws {
    try await send(raw: constraints.encoded())
  }

  /// Sends a pre-encoded colibri message — an endpoint message carrying a
  /// reaction, say. Queued until the connection opens.
  public func send(raw data: Data) async throws {
    guard let text = String(data: data, encoding: .utf8) else { return }
    try await task.send(.string(text))
  }

  public func close() {
    guard !closed else { return }
    closed = true
    receiveTask?.cancel()
    receiveTask = nil
    task.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
  }

  private func readLoop() async {
    while !Task.isCancelled {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await task.receive()
      } catch {
        if !closed { onEvent(.closed(reason: error.localizedDescription)) }
        return
      }
      let data: Data? =
        switch message {
        case .string(let text): text.data(using: .utf8)
        case .data(let data): data
        @unknown default: nil
        }
      guard let data, let parsed = try? parser.parse(data) else { continue }
      onEvent(.message(parsed))
    }
  }
}
