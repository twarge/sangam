#if canImport(Network)
  import CryptoKit
  import Foundation
  import Network

  public actor NetworkXMPPTextSocket: XMPPTextSocket {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.twarge.gafsaf.xmpp-websocket")
    private let host: String
    private let path: String
    private let preflightURL: URL?
    private var received = Data()
    private var keepaliveTask: Task<Void, Never>?

    public init(url: URL, preflightURL: URL? = nil) throws {
      guard
        let host = url.host,
        url.scheme == "wss" || url.scheme == "ws",
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "wss" ? 443 : 80)))
      else { throw NetworkXMPPSocketError.invalidURL }
      self.host = host
      var path = url.path.isEmpty ? "/" : url.path
      if let query = url.query { path += "?\(query)" }
      self.path = path
      self.preflightURL = preflightURL
      let parameters =
        url.scheme == "wss"
        ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        : NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
      connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }

    /// How often to send a WebSocket ping while the stream is quiet. Reverse
    /// proxies reap idle upstream connections — nginx's default read timeout
    /// is 60 seconds — so a participant sitting alone in a room would be
    /// disconnected for saying nothing. Any frame resets that clock.
    static let keepaliveInterval: Duration = .seconds(25)

    public func start() async throws {
      if let preflightURL { _ = try await URLSession.shared.data(from: preflightURL) }
      try await waitUntilReady()
      try await performUpgrade()
      keepaliveTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.keepaliveInterval)
          guard let self, !Task.isCancelled else { return }
          try? await self.sendPing()
        }
      }
    }

    public func send(_ text: String) async throws {
      try await sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    public func receive() async throws -> XMPPWebSocketMessage {
      while true {
        let frame = try await nextFrame()
        switch frame.opcode {
        case 0x1:
          guard let text = String(data: frame.payload, encoding: .utf8) else {
            throw NetworkXMPPSocketError.invalidText
          }
          return .text(text)
        case 0x2:
          return .data(frame.payload)
        case 0x8:
          let code: UInt16? =
            frame.payload.count >= 2
            ? UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
            : nil
          let reason =
            frame.payload.count > 2
            ? String(data: frame.payload.dropFirst(2), encoding: .utf8)
            : nil
          throw NetworkXMPPSocketError.remoteClosed(code: code, reason: reason)
        case 0x9:
          try await sendFrame(opcode: 0xA, payload: frame.payload)
        case 0xA:
          continue
        default:
          throw NetworkXMPPSocketError.unsupportedFrame(frame.opcode)
        }
      }
    }

    public func close() async {
      keepaliveTask?.cancel()
      keepaliveTask = nil
      try? await sendFrame(opcode: 0x8, payload: Data())
      connection.cancel()
    }

    private func sendPing() async throws {
      try await sendFrame(opcode: 0x9, payload: Data())
    }

    private func waitUntilReady() async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let gate = ContinuationGate(continuation)
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready: gate.resume()
          case .failed(let error): gate.resume(throwing: error)
          case .cancelled: gate.resume(throwing: NetworkXMPPSocketError.cancelledBeforeOpen)
          default: break
          }
        }
        connection.start(queue: queue)
      }
    }

    private func performUpgrade() async throws {
      let keyData = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
      let key = keyData.base64EncodedString()
      let request =
        "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\n"
        + "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
        + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Protocol: xmpp\r\n\r\n"
      try await sendRaw(Data(request.utf8))
      let marker = Data("\r\n\r\n".utf8)
      while received.range(of: marker) == nil { try await receiveMore() }
      guard let range = received.range(of: marker) else {
        throw NetworkXMPPSocketError.invalidUpgrade
      }
      let headerData = received[..<range.lowerBound]
      received.removeSubrange(..<range.upperBound)
      guard let header = String(data: headerData, encoding: .utf8) else {
        throw NetworkXMPPSocketError.invalidUpgrade
      }
      let expectedAccept = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
      let accept = Data(Insecure.SHA1.hash(data: expectedAccept)).base64EncodedString()
      guard
        header.hasPrefix("HTTP/1.1 101") || header.hasPrefix("HTTP/1.0 101"),
        header.lowercased().contains("sec-websocket-accept: \(accept.lowercased())")
      else { throw NetworkXMPPSocketError.invalidUpgrade }
    }

    private func sendFrame(opcode: UInt8, payload: Data) async throws {
      guard payload.count <= 1_048_576 else {
        throw NetworkXMPPSocketError.frameTooLarge
      }
      var frame = Data([0x80 | opcode])
      if payload.count < 126 {
        frame.append(0x80 | UInt8(payload.count))
      } else if payload.count <= Int(UInt16.max) {
        frame.append(0x80 | 126)
        let length = UInt16(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
      } else {
        frame.append(0x80 | 127)
        let length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
      }
      let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
      frame.append(contentsOf: mask)
      frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
      try await sendRaw(frame)
    }

    private func nextFrame() async throws -> (opcode: UInt8, payload: Data) {
      try await ensureBytes(2)
      let opcode = received[0] & 0x0F
      let masked = received[1] & 0x80 != 0
      var length = UInt64(received[1] & 0x7F)
      var headerLength = 2
      if length == 126 {
        try await ensureBytes(4)
        length = UInt64(received[2]) << 8 | UInt64(received[3])
        headerLength = 4
      } else if length == 127 {
        try await ensureBytes(10)
        length = received[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
        headerLength = 10
      }
      guard length <= 1_048_576 else { throw NetworkXMPPSocketError.frameTooLarge }
      let maskLength = masked ? 4 : 0
      try await ensureBytes(headerLength + maskLength + Int(length))
      let mask = masked ? Array(received[headerLength..<(headerLength + 4)]) : []
      let payloadStart = headerLength + maskLength
      var payload = Data(received[payloadStart..<(payloadStart + Int(length))])
      received.removeSubrange(..<(payloadStart + Int(length)))
      if masked {
        payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
      }
      return (opcode, payload)
    }

    private func ensureBytes(_ count: Int) async throws {
      while received.count < count { try await receiveMore() }
    }

    private func receiveMore() async throws {
      let data = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, any Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
          data, _, _, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else {
            continuation.resume(
              throwing: NetworkXMPPSocketError.remoteClosed(code: nil, reason: nil)
            )
          }
        }
      }
      received.append(data)
    }

    private func sendRaw(_ data: Data) async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(
          content: data,
          completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          })
      }
    }
  }

  public enum NetworkXMPPSocketError: Error, Equatable, Sendable {
    case invalidURL
    case cancelledBeforeOpen
    case invalidUpgrade
    case invalidText
    case remoteClosed(code: UInt16?, reason: String?)
    case unsupportedFrame(UInt8)
    case frameTooLarge
  }

  private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
      self.continuation = continuation
    }

    func resume() { resolve(.success(())) }
    func resume(throwing error: any Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Void, any Error>) {
      lock.withLock {
        continuation?.resume(with: result)
        continuation = nil
      }
    }
  }
#endif
