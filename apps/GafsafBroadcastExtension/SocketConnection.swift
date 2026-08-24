import Darwin
import Foundation

final class SocketConnection: NSObject, StreamDelegate, @unchecked Sendable {
  /// Assigned during broadcast setup, before `open()` starts `networkQueue`,
  /// and only read afterwards.
  var didOpen: (() -> Void)?
  var didClose: ((Error?) -> Void)?
  var streamHasSpaceAvailable: (() -> Void)?

  private let filePath: String
  private var socketHandle: Int32 = -1
  private var address: sockaddr_un?

  /// `open()` and `close()` run on the broadcast handler's thread, `write()`
  /// runs on the uploader's queue, and the stream callbacks run on
  /// `networkQueue`'s run loop, so the streams and the run-loop flag may only
  /// be touched under `lock`. Callbacks are always invoked outside the lock so
  /// a delegate that calls back into this object cannot deadlock.
  private let lock = NSLock()
  private var inputStream: InputStream?
  private var outputStream: OutputStream?
  private var networkQueue: DispatchQueue?
  private var shouldKeepRunning = false

  init?(filePath: String) {
    self.filePath = filePath
    socketHandle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketHandle != -1 else { return nil }
    super.init()
  }

  func open() -> Bool {
    guard FileManager.default.fileExists(atPath: filePath) else { return false }
    guard setupAddress(), connectSocket() else { return false }

    let (input, output) = setupStreams()
    input?.open()
    output?.open()
    return true
  }

  func close() {
    let (input, output) = lock.withLock { () -> (InputStream?, OutputStream?) in
      shouldKeepRunning = false
      let current = (inputStream, outputStream)
      inputStream = nil
      outputStream = nil
      return current
    }
    input?.delegate = nil
    output?.delegate = nil
    input?.close()
    output?.close()
  }

  func write(buffer: UnsafePointer<UInt8>, maximumLength: Int) -> Int {
    guard let output = lock.withLock({ outputStream }) else { return 0 }
    return output.write(buffer, maxLength: maximumLength)
  }

  func stream(_ stream: Stream, handle event: Stream.Event) {
    let (input, output) = lock.withLock { (inputStream, outputStream) }
    switch event {
    case .openCompleted where stream === output:
      didOpen?()
    case .hasBytesAvailable where stream === input:
      var byte: UInt8 = 0
      if input?.read(&byte, maxLength: 1) == 0, stream.streamStatus == .atEnd {
        close()
        didClose?(nil)
      }
    case .hasSpaceAvailable where stream === output:
      streamHasSpaceAvailable?()
    case .errorOccurred:
      let error = stream.streamError
      close()
      didClose?(error)
    default:
      break
    }
  }

  private func setupAddress() -> Bool {
    var value = sockaddr_un()
    guard filePath.utf8.count < MemoryLayout.size(ofValue: value.sun_path) else { return false }

    value.sun_family = sa_family_t(AF_UNIX)

    _ = withUnsafeMutablePointer(to: &value.sun_path.0) { pointer in
      filePath.withCString { source in
        strncpy(pointer, source, filePath.utf8.count)
      }
    }
    address = value
    return true
  }

  private func connectSocket() -> Bool {
    guard var address else { return false }
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return status == 0
  }

  private func setupStreams() -> (input: InputStream?, output: OutputStream?) {
    var readStream: Unmanaged<CFReadStream>?
    var writeStream: Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readStream, &writeStream)

    let input: InputStream? = readStream?.takeRetainedValue()
    let output: OutputStream? = writeStream?.takeRetainedValue()
    input?.delegate = self
    output?.delegate = self
    input?.setProperty(
      kCFBooleanTrue,
      forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String)
    )
    output?.setProperty(
      kCFBooleanTrue,
      forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String)
    )

    let queue = DispatchQueue(label: "com.twarge.gafsaf.broadcast.socket")
    lock.withLock {
      inputStream = input
      outputStream = output
      networkQueue = queue
      shouldKeepRunning = true
    }

    queue.async { [weak self] in
      guard let self else { return }
      // Read the streams back out through `self` rather than capturing them:
      // Foundation's stream types are not Sendable, so capturing them in this
      // `@Sendable` closure would be an unchecked crossing rather than a
      // guarded one.
      let (scheduled, writable) = lock.withLock { (inputStream, outputStream) }
      scheduled?.schedule(in: .current, forMode: .common)
      writable?.schedule(in: .current, forMode: .common)
      while lock.withLock({ shouldKeepRunning }),
        RunLoop.current.run(mode: .default, before: .distantFuture)
      {}
    }
    return (input, output)
  }
}
