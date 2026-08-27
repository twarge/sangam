import AVKit
import CoreMedia
import JitsiConference
import JitsiMedia
import SwiftUI

/// Drives system Picture in Picture from a remote stream: the bridge
/// renders WebRTC frames into a sample-buffer layer, and AVKit floats that
/// layer in the system's PiP window on both macOS and iOS.
@MainActor
final class PictureInPictureManager: NSObject, ObservableObject {
  @Published private(set) var isActive = false
  /// Fired on start/stop so a host that does not observe this object can
  /// still mirror the state into its UI.
  var onActiveChanged: (@MainActor (Bool) -> Void)?
  /// Fired when a start attempt fails, with a user-facing explanation.
  var onError: (@MainActor (String) -> Void)?

  let bridge = VideoSampleBufferBridge()
  private var controller: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?

  var isSupported: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  /// Creates the AVKit controller once the layer's host view is on screen —
  /// AVKit refuses content sources that are not in a window yet.
  func prepareIfNeeded() {
    guard controller == nil, isSupported else { return }
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: bridge.layer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    self.controller = controller
  }

  func toggle(stream: RemoteVideoStream?) {
    prepareIfNeeded()
    guard let controller else {
      SangamLog.event("pip: unsupported on this system")
      onError?("Picture in Picture is not supported here.")
      return
    }
    if controller.isPictureInPictureActive {
      SangamLog.event("pip: stop")
      possibleObservation = nil
      controller.stopPictureInPicture()
      return
    }
    guard let stream else {
      SangamLog.event("pip: no remote stream to float")
      onError?("There’s no remote video to float yet.")
      return
    }
    bridge.attach(to: stream.track)
    startWhenPossible(controller)
  }

  /// AVKit honors `startPictureInPicture` only once it deems it possible —
  /// the content layer must be in a window and have received video. The
  /// first frame usually lands moments after attaching, so wait for the
  /// possible flag instead of firing blind (which fails silently).
  private func startWhenPossible(_ controller: AVPictureInPictureController) {
    if controller.isPictureInPicturePossible {
      SangamLog.event("pip: start (immediately possible)")
      controller.startPictureInPicture()
      return
    }
    SangamLog.event("pip: waiting to become possible")
    possibleObservation = controller.observe(
      \.isPictureInPicturePossible, options: [.new]
    ) { [weak self] _, change in
      guard change.newValue == true else { return }
      Task { @MainActor [weak self] in
        guard let self, self.possibleObservation != nil, let controller = self.controller
        else { return }
        self.possibleObservation = nil
        SangamLog.event("pip: start (became possible)")
        controller.startPictureInPicture()
      }
    }
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard let self, self.possibleObservation != nil else { return }
      self.possibleObservation = nil
      SangamLog.event("pip: never became possible")
      self.onError?(
        "Picture in Picture could not start — the video never reached the system player.")
    }
  }

  /// Follows stage changes while the floating window is up; with nothing
  /// left to show, the window closes.
  func showStream(_ stream: RemoteVideoStream?) {
    guard isActive else { return }
    if let stream {
      bridge.attach(to: stream.track)
    } else {
      controller?.stopPictureInPicture()
    }
  }
}

extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    Task { @MainActor in
      SangamLog.event("pip: failed to start: \(error.localizedDescription)")
      self.onError?("Picture in Picture could not start: \(error.localizedDescription)")
    }
  }

  nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    Task { @MainActor in
      SangamLog.event("pip: started")
      self.isActive = true
      self.onActiveChanged?(true)
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    Task { @MainActor in
      self.isActive = false
      self.bridge.detach()
      self.onActiveChanged?(false)
    }
  }
}

/// Live video has no timeline: playback is always "playing" over an
/// infinite range, and skipping means nothing.
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {}

  nonisolated func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, end: .positiveInfinity)
  }

  nonisolated func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    false
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}

/// Hosts the bridge's display layer in the view hierarchy — AVKit requires
/// the content-source layer to live in a window. Kept tiny and effectively
/// invisible beneath the stage; the system window does the real rendering.
#if os(macOS)
  struct PiPLayerHost: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let onReady: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      view.wantsLayer = true
      layer.frame = CGRect(x: 0, y: 0, width: 64, height: 36)
      view.layer?.addSublayer(layer)
      DispatchQueue.main.async(execute: onReady)
      return view
    }

    func updateNSView(_ view: NSView, context: Context) {
      layer.frame = view.bounds
    }
  }
#else
  struct PiPLayerHost: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let onReady: @MainActor @Sendable () -> Void

    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      layer.frame = CGRect(x: 0, y: 0, width: 64, height: 36)
      view.layer.addSublayer(layer)
      DispatchQueue.main.async(execute: onReady)
      return view
    }

    func updateUIView(_ view: UIView, context: Context) {
      layer.frame = view.bounds
    }
  }
#endif
