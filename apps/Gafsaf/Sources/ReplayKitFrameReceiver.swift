#if os(iOS)
  import CoreImage
  import Darwin
  import Foundation
  import ImageIO
  import JitsiMedia

  nonisolated final class ReplayKitFrameReceiver: @unchecked Sendable {
    enum State: Equatable, Sendable {
      case idle
      case listening
      case receiving
      case stopped
      case failed(String)
    }

    private static let appGroupIdentifier = "group.com.twarge.gafsaf"
    private static let socketName = "rtc_SSFD"
    private static let maximumHeaderBytes = 64 * 1_024
    private static let maximumFrameBytes = 16 * 1_024 * 1_024

    var stateDidChange: (@MainActor @Sendable (State) -> Void)?

    private let track: LocalVideoTrack
    private let queue = DispatchQueue(label: "com.twarge.gafsaf.broadcast.receiver")
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// `start()` and `stop()` are called from the main actor while `queue` runs
    /// the blocking accept/read loop, so every field below is shared across
    /// threads and may only be touched while holding `lock`. File descriptors
    /// are closed exclusively by `queue`; `stop()` only shuts them down, which
    /// unblocks `accept`/`read` without freeing a descriptor number that the
    /// loop could otherwise re-read after the kernel recycled it.
    private let lock = NSLock()
    private var listeningSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var socketPath: String?
    private var running = false

    init(track: LocalVideoTrack) {
      self.track = track
    }

    private var isRunning: Bool {
      lock.withLock { running }
    }

    func start() throws {
      let claimed = lock.withLock { () -> Bool in
        guard !running else { return false }
        running = true
        return true
      }
      guard claimed else { return }

      let descriptor: Int32
      let path: String
      do {
        (descriptor, path) = try Self.makeListeningSocket()
      } catch {
        lock.withLock { running = false }
        throw error
      }

      lock.withLock {
        listeningSocket = descriptor
        socketPath = path
      }
      report(.listening)
      queue.async { [weak self] in self?.receiveConnections() }
    }

    func stop() {
      let (client, listener) = lock.withLock { () -> (Int32, Int32) in
        running = false
        return (clientSocket, listeningSocket)
      }
      // Shut down without closing so the loop below wakes up, notices that it
      // is no longer running, and performs the close itself.
      if client >= 0 { Darwin.shutdown(client, SHUT_RDWR) }
      if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR) }
      report(.stopped)
    }

    private static func makeListeningSocket() throws -> (descriptor: Int32, path: String) {
      guard
        let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        )
      else {
        throw ReplayKitFrameReceiverError.appGroupUnavailable
      }
      let path = container.appending(path: Self.socketName).path
      guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
        throw ReplayKitFrameReceiverError.socketPathTooLong
      }

      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw ReplayKitFrameReceiverError.socketCreationFailed(errno) }
      Darwin.unlink(path)

      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let pathCapacity = MemoryLayout.size(ofValue: address.sun_path) - 1
      _ = path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
          strncpy(destination, source, pathCapacity)
        }
      }
      let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bindResult == 0 else {
        let code = errno
        Darwin.close(descriptor)
        Darwin.unlink(path)
        throw ReplayKitFrameReceiverError.socketBindFailed(code)
      }
      guard Darwin.listen(descriptor, 1) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        Darwin.unlink(path)
        throw ReplayKitFrameReceiverError.socketListenFailed(code)
      }
      return (descriptor, path)
    }

    private func receiveConnections() {
      defer { closeSockets() }
      while isRunning {
        let listener = lock.withLock { listeningSocket }
        guard listener >= 0 else { return }
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else {
          if isRunning { report(.failed("ReplayKit connection failed (errno \(errno)).")) }
          return
        }
        lock.withLock { clientSocket = accepted }
        report(.receiving)
        receiveFrames(from: accepted)
        let owned = lock.withLock { () -> Bool in
          guard clientSocket == accepted else { return false }
          clientSocket = -1
          return true
        }
        if owned { Darwin.close(accepted) }
        if isRunning { report(.listening) }
      }
    }

    private func closeSockets() {
      let (client, listener, path) = lock.withLock { () -> (Int32, Int32, String?) in
        let current = (clientSocket, listeningSocket, socketPath)
        clientSocket = -1
        listeningSocket = -1
        socketPath = nil
        return current
      }
      if client >= 0 { Darwin.close(client) }
      if listener >= 0 { Darwin.close(listener) }
      if let path { Darwin.unlink(path) }
    }

    private func receiveFrames(from descriptor: Int32) {
      var pending = Data()
      var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
      while isRunning {
        let count = bytes.withUnsafeMutableBytes { storage in
          Darwin.read(descriptor, storage.baseAddress, storage.count)
        }
        guard count > 0 else { return }
        pending.append(contentsOf: bytes.prefix(count))
        while let message = nextMessage(from: &pending) {
          deliver(message)
        }
        if pending.count > Self.maximumHeaderBytes + Self.maximumFrameBytes {
          report(.failed("ReplayKit sent an oversized frame."))
          return
        }
      }
    }

    private func nextMessage(from data: inout Data) -> ReplayKitFrameMessage? {
      let separator = Data("\r\n\r\n".utf8)
      guard let headerRange = data.range(of: separator) else {
        if data.count > Self.maximumHeaderBytes { data.removeAll(keepingCapacity: true) }
        return nil
      }
      guard
        headerRange.lowerBound <= Self.maximumHeaderBytes,
        let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
      else {
        data.removeSubrange(..<headerRange.upperBound)
        return nil
      }
      let fields = Self.headerFields(header)
      guard
        let lengthValue = fields["content-length"],
        let length = Int(lengthValue),
        (0...Self.maximumFrameBytes).contains(length)
      else {
        data.removeSubrange(..<headerRange.upperBound)
        return nil
      }
      let messageEnd = headerRange.upperBound + length
      guard data.count >= messageEnd else { return nil }
      let body = Data(data[headerRange.upperBound..<messageEnd])
      data.removeSubrange(..<messageEnd)
      return ReplayKitFrameMessage(
        jpeg: body,
        orientation: fields["buffer-orientation"].flatMap(UInt32.init) ?? 1
      )
    }

    private func deliver(_ message: ReplayKitFrameMessage) {
      guard
        let image = CIImage(data: message.jpeg),
        image.extent.width > 0,
        image.extent.height > 0
      else { return }
      let width = Int(image.extent.width.rounded(.down))
      let height = Int(image.extent.height.rounded(.down))
      var buffer: CVPixelBuffer?
      let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      guard
        CVPixelBufferCreate(
          kCFAllocatorDefault,
          width,
          height,
          kCVPixelFormatType_32BGRA,
          attributes as CFDictionary,
          &buffer
        ) == kCVReturnSuccess,
        let buffer
      else { return }
      imageContext.render(
        image,
        to: buffer,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        colorSpace: CGColorSpaceCreateDeviceRGB()
      )
      track.push(
        pixelBuffer: buffer,
        rotationDegrees: Self.rotationDegrees(orientation: message.orientation),
        timestampNanoseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
      )
    }

    private func report(_ state: State) {
      Task { @MainActor [stateDidChange] in stateDidChange?(state) }
    }

    private static func headerFields(_ header: String) -> [String: String] {
      var result: [String: String] = [:]
      for line in header.split(whereSeparator: \.isNewline).dropFirst() {
        let pair = line.split(separator: ":", maxSplits: 1)
        guard pair.count == 2 else { continue }
        result[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
          pair[1].trimmingCharacters(in: .whitespaces)
      }
      return result
    }

    private static func rotationDegrees(orientation: UInt32) -> Int {
      switch CGImagePropertyOrientation(rawValue: orientation) {
      case .right, .rightMirrored: 90
      case .down, .downMirrored: 180
      case .left, .leftMirrored: 270
      default: 0
      }
    }
  }

  private struct ReplayKitFrameMessage {
    var jpeg: Data
    var orientation: UInt32
  }

  enum ReplayKitFrameReceiverError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case socketPathTooLong
    case socketCreationFailed(Int32)
    case socketBindFailed(Int32)
    case socketListenFailed(Int32)
  }
#endif
