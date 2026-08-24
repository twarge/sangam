import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
  private static let appGroupIdentifier = "group.com.twarge.gafsaf"

  private var connection: SocketConnection?
  private var uploader: SampleUploader?
  private var frameCount = 0
  private var connectionTimer: DispatchSourceTimer?

  override init() {
    super.init()
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
      ),
      let connection = SocketConnection(filePath: container.appending(path: "rtc_SSFD").path)
    else { return }

    self.connection = connection
    uploader = SampleUploader(connection: connection)
    connection.didClose = { [weak self] error in
      guard let self else { return }
      if let error {
        finishBroadcastWithError(error)
      } else {
        finishBroadcastWithError(
          NSError(
            domain: RPRecordingErrorDomain,
            code: 10_001,
            userInfo: [NSLocalizedDescriptionKey: "Screen sharing stopped."]
          )
        )
      }
    }
  }

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    frameCount = 0
    DarwinNotificationCenter.shared.post(.started)
    openConnectionWhenReady()
  }

  override func broadcastFinished() {
    DarwinNotificationCenter.shared.post(.stopped)
    connectionTimer?.cancel()
    connectionTimer = nil
    connection?.close()
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) {
    guard sampleBufferType == .video else { return }
    frameCount += 1
    if frameCount.isMultiple(of: 3) {
      uploader?.send(sampleBuffer)
    }
  }

  private func openConnectionWhenReady() {
    let timer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "com.twarge.gafsaf.broadcast.connect")
    )
    timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in
      guard let self, connection?.open() == true else { return }
      timer.cancel()
      connectionTimer = nil
    }
    connectionTimer = timer
    timer.resume()
  }
}
