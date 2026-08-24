#if os(macOS)
  import CoreMedia
  import Foundation
  import JitsiMedia
  import ScreenCaptureKit

  nonisolated final class MacScreenShareController: NSObject, @unchecked Sendable {
    enum State: Equatable, Sendable {
      case idle
      case selecting
      case starting
      case sharing
      case stopped
      case failed(String)
    }

    var stateDidChange: (@MainActor @Sendable (State) -> Void)?

    private let videoTrack: LocalVideoTrack
    private let captureQueue = DispatchQueue(
      label: "com.twarge.sangam.screen-capture",
      qos: .userInteractive
    )

    /// Picker callbacks arrive on ReplayKit's XPC queue (com.apple.replayd —
    /// NOT the main thread), `SCStreamDelegate` callbacks arrive on
    /// ScreenCaptureKit's own queue, and `stop()` is called from the main
    /// actor, so the active stream may only be read or written under `lock`.
    private let lock = NSLock()
    private var stream: SCStream?
    // Bring-up counters for the SANGAM_LOG diagnostic timeline, guarded by
    // `lock` because frames arrive on the capture queue.
    private var receivedFrames = 0
    private var pushedFrames = 0
    private var skippedFrames = 0
    private var lastStatus = "none"

    init(videoTrack: LocalVideoTrack) {
      self.videoTrack = videoTrack
      super.init()
    }

    private func takeStream() -> SCStream? {
      lock.withLock {
        let current = stream
        stream = nil
        return current
      }
    }

    private func setStream(_ newStream: SCStream?) {
      lock.withLock { stream = newStream }
    }

    @MainActor
    func presentPicker() {
      var configuration = SCContentSharingPickerConfiguration()
      configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
      configuration.allowsChangingSelectedContent = true
      if let bundleIdentifier = Bundle.main.bundleIdentifier {
        configuration.excludedBundleIDs = [bundleIdentifier]
      }

      let picker = SCContentSharingPicker.shared
      picker.defaultConfiguration = configuration
      picker.add(self)
      picker.isActive = true
      report(.selecting)
      picker.present()
    }

    @MainActor
    func stop() {
      let activeStream = takeStream()
      SCContentSharingPicker.shared.remove(self)
      SCContentSharingPicker.shared.isActive = false
      guard let activeStream else {
        report(.stopped)
        return
      }
      activeStream.stopCapture { [weak self] error in
        if let error {
          self?.report(.failed(error.localizedDescription))
        } else {
          self?.report(.stopped)
        }
      }
    }

    private func start(filter: SCContentFilter) {
      report(.starting)
      let configuration = SCStreamConfiguration()
      // Match the stream size to the picked content, and let ScreenCaptureKit
      // scale into it. A fixed 4K canvas leaves a window's pixels in one
      // corner of an otherwise black frame — which arrived at the far end as
      // a black feed — since without `scalesToFit` window content is not
      // scaled to the output size.
      let scale = CGFloat(filter.pointPixelScale)
      let width = Int(filter.contentRect.width * scale)
      let height = Int(filter.contentRect.height * scale)
      configuration.width = min(max(width - width % 2, 2), 3_840)
      configuration.height = min(max(height - height % 2, 2), 2_160)
      configuration.scalesToFit = true
      SangamLog.event(
        "screen-share: start content=\(Int(filter.contentRect.width))x\(Int(filter.contentRect.height)) "
          + "scale=\(filter.pointPixelScale) stream=\(configuration.width)x\(configuration.height)")
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
      configuration.queueDepth = 5
      configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      configuration.showsCursor = true
      configuration.capturesAudio = false

      let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
      do {
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
      } catch {
        report(.failed(error.localizedDescription))
        return
      }

      setStream(newStream)
      newStream.startCapture { [weak self] error in
        if let error {
          self?.report(.failed(error.localizedDescription))
        } else {
          self?.report(.sharing)
        }
      }
    }

    private func report(_ state: State) {
      Task { @MainActor [stateDidChange] in
        stateDidChange?(state)
      }
    }
  }

  // Every callback below must be `nonisolated`: the app target defaults to
  // MainActor isolation, and a conformance declared in an extension does not
  // inherit the class's `nonisolated`. ReplayKit delivers the picker callbacks
  // on its replayd XPC queue and ScreenCaptureKit delivers stream callbacks on
  // the capture queue, so a MainActor-isolated method here dies on the
  // runtime's executor assertion (dispatch_assert_queue_fail) the moment a
  // window is picked or a frame arrives.
  extension MacScreenShareController: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
      _ picker: SCContentSharingPicker,
      didCancelFor stream: SCStream?
    ) {
      report(.idle)
    }

    nonisolated func contentSharingPicker(
      _ picker: SCContentSharingPicker,
      didUpdateWith filter: SCContentFilter,
      for stream: SCStream?
    ) {
      if let stream {
        setStream(stream)
        report(.sharing)
      } else {
        start(filter: filter)
      }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
      report(.failed(error.localizedDescription))
    }
  }

  extension MacScreenShareController: SCStreamDelegate, SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
      _ = takeStream()
      // Closing the shared window, or stopping from the system's screen
      // sharing indicator, ends the stream with `userStopped`. That is an
      // ordinary end of sharing — report it as stopped so the app resets the
      // toolbar quietly instead of raising an error alert.
      let nsError = error as NSError
      if nsError.domain == SCStreamErrorDomain,
        nsError.code == SCStreamError.Code.userStopped.rawValue
      {
        report(.stopped)
      } else {
        report(.failed(error.localizedDescription))
      }
    }

    nonisolated func stream(
      _ stream: SCStream,
      didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
      of type: SCStreamOutputType
    ) {
      let status = Self.frameStatus(sampleBuffer)
      let counters: (received: Int, pushed: Int, skipped: Int) = lock.withLock {
        receivedFrames += 1
        lastStatus = status.name
        return (receivedFrames, pushedFrames, skippedFrames)
      }
      if counters.received == 1 || counters.received % 150 == 0 {
        let size = sampleBuffer.imageBuffer.map {
          "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))"
        }
        SangamLog.event(
          "screen-share: frames received=\(counters.received) pushed=\(counters.pushed) "
            + "skipped=\(counters.skipped) status=\(status.name) buffer=\(size ?? "none")")
      }
      guard
        type == .screen,
        sampleBuffer.isValid,
        CMSampleBufferDataIsReady(sampleBuffer),
        let pixelBuffer = sampleBuffer.imageBuffer,
        status.hasContent
      else {
        lock.withLock { skippedFrames += 1 }
        return
      }

      let presentationTime = sampleBuffer.presentationTimeStamp
      let timestamp = CMTimeConvertScale(
        presentationTime,
        timescale: 1_000_000_000,
        method: .default
      ).value
      videoTrack.push(
        pixelBuffer: pixelBuffer,
        timestampNanoseconds: timestamp
      )
      lock.withLock { pushedFrames += 1 }
    }

    /// A captured frame's status. Streams begin with started/blank frames
    /// whose buffers are empty; encoding those shows black at the far end.
    /// Complete frames carry new content and idle frames repeat unchanged
    /// content — both are real.
    private nonisolated static func frameStatus(
      _ sampleBuffer: CMSampleBuffer
    ) -> (name: String, hasContent: Bool) {
      guard
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
          sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus)
      else { return ("unreadable", false) }
      switch status {
      case .complete: return ("complete", true)
      case .idle: return ("idle", true)
      case .blank: return ("blank", false)
      case .started: return ("started", false)
      case .suspended: return ("suspended", false)
      case .stopped: return ("stopped", false)
      @unknown default: return ("unknown-\(rawStatus)", false)
      }
    }
  }
#endif
