import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum XMPPWebSocketMessage: Equatable, Sendable {
  case text(String)
  case data(Data)
}

public protocol XMPPTextSocket: Sendable {
  func start() async throws
  func send(_ text: String) async throws
  func receive() async throws -> XMPPWebSocketMessage
  func close() async
}

public actor URLSessionXMPPTextSocket: XMPPTextSocket {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let openObserver: WebSocketOpenObserver
  private let preflightURL: URL?

  public init(url: URL, preflightURL: URL? = nil) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    let observer = WebSocketOpenObserver()
    openObserver = observer
    self.preflightURL = preflightURL
    session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
    task = session.webSocketTask(with: url, protocols: ["xmpp"])
  }

  public func start() async throws {
    if let preflightURL {
      _ = try await session.data(from: preflightURL)
    }
    task.resume()
    try await openObserver.waitUntilOpen()
  }

  public func send(_ text: String) async throws {
    try await task.send(.string(text))
  }

  public func receive() async throws -> XMPPWebSocketMessage {
    switch try await task.receive() {
    case .string(let text):
      .text(text)
    case .data(let data):
      .data(data)
    @unknown default:
      throw XMPPTransportError.unsupportedFrame
    }
  }

  public func close() {
    task.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
  }
}

public enum XMPPTransportError: Error, Equatable, Sendable {
  case notConnected
  case alreadyConnected
  case unsupportedFrame
  case frameTooLarge(limit: Int)
}

extension XMPPTransportError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConnected:
      return "The connection to the Jitsi server is not open."
    case .alreadyConnected:
      return "The connection to the Jitsi server is already open."
    case .unsupportedFrame:
      return "The Jitsi server sent a frame that is not XMPP."
    case .frameTooLarge(let limit):
      return "A message to the Jitsi server exceeded the \(limit)-byte limit."
    }
  }
}

public actor XMPPWebSocketTransport {
  private let socket: any XMPPTextSocket
  private let parser: XMPPParser
  private let maximumFrameBytes: Int
  private var connected = false

  public init(
    socket: any XMPPTextSocket,
    parser: XMPPParser = .init(),
    maximumFrameBytes: Int = 1_048_576
  ) {
    self.socket = socket
    self.parser = parser
    self.maximumFrameBytes = maximumFrameBytes
  }

  public func connect() async throws {
    guard !connected else { throw XMPPTransportError.alreadyConnected }
    try await socket.start()
    connected = true
  }

  public func send(_ xml: String) async throws {
    guard connected else { throw XMPPTransportError.notConnected }
    guard xml.utf8.count <= maximumFrameBytes else {
      throw XMPPTransportError.frameTooLarge(limit: maximumFrameBytes)
    }
    try await socket.send(xml)
  }

  public func send(_ element: XMPPElement) async throws {
    // RFC 7395 requires every stanza frame to be explicitly qualified; a bare
    // `<iq>` earns `unsupported-stanza-type` from a WebSocket server. Builders
    // routinely omit the namespace because BOSH always filled it in for them,
    // so normalize here, at the one place every outgoing stanza passes.
    var stanza = element
    if stanza.namespace == nil, stanza.isClientStanza {
      stanza.namespace = XMPPElement.clientNamespace
    }
    try await send(XMPPWriter.serialize(stanza))
  }

  public func receive() async throws -> XMPPElement {
    guard connected else { throw XMPPTransportError.notConnected }
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .text(let text):
      data = Data(text.utf8)
    case .data(let bytes):
      data = bytes
    }
    guard data.count <= maximumFrameBytes else {
      throw XMPPTransportError.frameTooLarge(limit: maximumFrameBytes)
    }
    return try parser.parse(data)
  }

  public func close() async {
    guard connected else { return }
    connected = false
    await socket.close()
  }
}

private final class WebSocketOpenObserver: NSObject, URLSessionWebSocketDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var result: Result<Void, any Error>?
  private var continuation: CheckedContinuation<Void, any Error>?

  func waitUntilOpen() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if let result {
          continuation.resume(with: result)
        } else {
          self.continuation = continuation
        }
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    resolve(.success(()))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error { resolve(.failure(error)) }
  }

  private func resolve(_ result: Result<Void, any Error>) {
    lock.withLock {
      guard self.result == nil else { return }
      self.result = result
      continuation?.resume(with: result)
      continuation = nil
    }
  }
}
