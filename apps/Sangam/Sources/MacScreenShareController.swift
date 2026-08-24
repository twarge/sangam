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

    /// Picker callbacks arrive on the main thread, `SCStreamDelegate` callbacks
    /// arrive on ScreenCaptureKit's own queue, and `stop()` is called from the
    /// main actor, so the active stream may only be read or written under
    /// `lock`.
    private let lock = NSLock()
    private var stream: SCStream?

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
      configuration.width = 3_840
      configuration.height = 2_160
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

  extension MacScreenShareController: SCContentSharingPickerObserver {
    func contentSharingPicker(
      _ picker: SCContentSharingPicker,
      didCancelFor stream: SCStream?
    ) {
      report(.idle)
    }

    func contentSharingPicker(
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

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
      report(.failed(error.localizedDescription))
    }
  }

  extension MacScreenShareController: SCStreamDelegate, SCStreamOutput {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
      _ = takeStream()
      report(.failed(error.localizedDescription))
    }

    func stream(
      _ stream: SCStream,
      didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
      of type: SCStreamOutputType
    ) {
      guard
        type == .screen,
        sampleBuffer.isValid,
        CMSampleBufferDataIsReady(sampleBuffer),
        let pixelBuffer = sampleBuffer.imageBuffer
      else { return }

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
    }
  }
#endif
