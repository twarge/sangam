import AVKit
import CoreMedia
import JitsiConference
import JitsiMedia
import SwiftUI

/// Drives system Picture in Picture from the meeting's featured video: the
/// bridge renders WebRTC frames into a sample-buffer layer, and AVKit floats
/// that layer in the system's PiP window.
///
/// The two platforms reach it by different routes, because AVKit has two.
/// iOS uses the video-call route — `AVPictureInPictureVideoCallViewController`
/// with an `activeVideoCallSourceView` — which is what Apple prescribes for
/// calls and what makes the window behave like FaceTime's. macOS has no such
/// class and keeps the sample-buffer route, whose playback delegate has to
/// invent a timeline for video that has none.
@MainActor
final class PictureInPictureManager: NSObject, ObservableObject {
  @Published private(set) var isActive = false
  /// Fired on start/stop so a host that does not observe this object can
  /// still mirror the state into its UI.
  var onActiveChanged: (@MainActor (Bool) -> Void)?
  /// Fired when a start attempt fails, with a user-facing explanation.
  var onError: (@MainActor (String) -> Void)?
  /// Asked for the video to float, rather than told about it. Automatic PiP
  /// can start at any moment, and pushing updates in from `onChange` meant
  /// the window showed whatever was featured when the last change happened —
  /// the self view, if the remote arrived while nothing else moved.
  var currentVideo: (@MainActor () -> (remote: RemoteVideoStream?, local: LocalVideoTrack?))?

  let bridge = VideoSampleBufferBridge()
  private var controller: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  #if os(iOS)
    private var callViewController: AVPictureInPictureVideoCallViewController?
    /// Held strongly. `ContentSource` keeps only a weak reference to the
    /// source view, and SwiftUI can throw the representable's view away and
    /// build another: a controller left bound to the discarded one is
    /// detached from its own window — no delegate callbacks, and
    /// `stopPictureInPicture` does nothing.
    private var sourceView: UIView?
  #endif

  var isSupported: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  /// Everything AVKit weighs when it decides whether Picture in Picture may
  /// start, in one line. PGPegasus errors carry no useful
  /// `localizedDescription` — every failure reads the same — so the state at
  /// the moment of the attempt is the only thing that separates one cause
  /// from another.
  private var diagnosticState: String {
    var parts: [String] = [
      "supported=\(AVPictureInPictureController.isPictureInPictureSupported())",
      "possible=\(controller?.isPictureInPicturePossible ?? false)",
      "active=\(controller?.isPictureInPictureActive ?? false)",
      "layer=\(Int(bridge.layer.bounds.width))x\(Int(bridge.layer.bounds.height))",
      "hosted=\(bridge.layer.superlayer != nil)",
      "readyForMore=\(bridge.layer.sampleBufferRenderer.isReadyForMoreMediaData)",
      "status=\(bridge.layer.sampleBufferRenderer.status.rawValue)",
    ]
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      parts.append("sourceInWindow=\(sourceView?.window != nil)")
      parts.append("category=\(session.category.rawValue)")
      parts.append("mode=\(session.mode.rawValue)")
      parts.append("app=\(UIApplication.shared.applicationState.rawValue)")
    #endif
    return parts.joined(separator: " ")
  }

  #if os(iOS)
    /// Builds the video-call controller once its source view is on screen.
    /// The sample-buffer layer lives in the floating view controller rather
    /// than in the app's own hierarchy — the stage renders inline through its
    /// own Metal path, and this layer exists only for the PiP window.
    func prepare(sourceView view: UIView) {
      // Not before it is on screen: AVKit wants a source view in a window.
      guard isSupported, view.window != nil else { return }
      // Already built against this very view; nothing to do.
      if controller != nil, sourceView === view { return }
      // A different view means the content source is pointing at one SwiftUI
      // has discarded, so it is rebuilt against what is actually on screen.
      // Not mid-flight, though: tearing the source out from under a window
      // that is up would strand it.
      if controller?.isPictureInPictureActive == true { return }
      let callViewController = AVPictureInPictureVideoCallViewController()
      // The window takes its shape from here; the real aspect follows the
      // first frame, through `bridge.onVideoSize`.
      callViewController.preferredContentSize = CGSize(width: 1920, height: 1080)
      let content = SampleBufferHostView(displayLayer: bridge.layer)
      content.translatesAutoresizingMaskIntoConstraints = false
      // Touching `view` loads it, which gives the layer a host straight away
      // rather than at the moment PiP starts.
      let host = callViewController.view!
      host.backgroundColor = .black
      host.addSubview(content)
      NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        content.topAnchor.constraint(equalTo: host.topAnchor),
        content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
      ])

      let source = AVPictureInPictureController.ContentSource(
        activeVideoCallSourceView: view, contentViewController: callViewController)
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      // The meeting floats itself when the user leaves the app and comes back
      // inline when they return. The system starts PiP during the
      // backgrounding transition, so the content has to be live already —
      // which is why the bridge follows the featured video for the whole call
      // rather than only while the window is up.
      controller.canStartPictureInPictureAutomaticallyFromInline = true

      bridge.onVideoSize = { [weak self] size in self?.applyVideoSize(size) }

      self.callViewController = callViewController
      self.sourceView = view
      self.controller = controller
      SangamLog.event("pip: prepared (video-call route)")
    }
  #else
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
  #endif

  #if os(iOS)
    /// The floating window follows the video's shape rather than the guess
    /// made before the first frame arrived.
    private func applyVideoSize(_ size: CGSize) {
      callViewController?.preferredContentSize = size
    }
  #endif

  /// Keeps the layer showing whatever the meeting is featuring, whether or not
  /// PiP is up. Automatic PiP has no chance to attach a track on the way to the
  /// background, so the content has to be there already.
  func follow(remote: RemoteVideoStream?, localFallback: LocalVideoTrack?) {
    if let remote {
      bridge.attach(to: remote.track)
    } else if let localFallback {
      bridge.attach(to: localFallback)
    } else {
      bridge.detach()
      controller?.stopPictureInPicture()
    }
  }

  /// Re-reads what should be floating and attaches it. Cheap enough to call
  /// whenever the answer might have changed.
  func followCurrent() {
    guard let video = currentVideo?() else { return }
    follow(remote: video.remote, localFallback: video.local)
  }

  /// Back in the app: the floating window has nothing left to do.
  ///
  /// Asked unconditionally rather than behind `isPictureInPictureActive`.
  /// Stopping something already stopped costs nothing, and the flag reads
  /// false during the transitions either side of the window being up — which
  /// is exactly when this is called.
  func stopIfActive() {
    guard let controller else { return }
    SangamLog.event("pip: stop requested (active=\(controller.isPictureInPictureActive))")
    possibleObservation = nil
    controller.stopPictureInPicture()
  }

  /// The call is over. Apple's guidance is to release the content source when
  /// it ends, so a later backgrounding cannot float a meeting that is no
  /// longer running.
  func endFollowing() {
    possibleObservation = nil
    controller?.stopPictureInPicture()
    bridge.detach()
    bridge.onVideoSize = nil
    controller = nil
    #if os(iOS)
      bridge.layer.removeFromSuperlayer()
      callViewController = nil
      sourceView = nil
    #endif
  }

  func toggle(remote: RemoteVideoStream?, localFallback: LocalVideoTrack?) {
    #if os(macOS)
      prepareIfNeeded()
    #endif
    guard let controller else {
      SangamLog.event("pip: no controller yet — \(diagnosticState)")
      onError?("Picture in Picture is not ready yet.")
      return
    }
    if controller.isPictureInPictureActive {
      SangamLog.event("pip: stop")
      possibleObservation = nil
      controller.stopPictureInPicture()
      return
    }
    if let remote {
      SangamLog.event("pip: floating remote \(remote.id)")
      bridge.attach(to: remote.track)
    } else if let localFallback {
      // Alone in the room: float the self view and wait; the first remote
      // stream to appear takes over.
      SangamLog.event("pip: floating self view while waiting")
      bridge.attach(to: localFallback)
    } else {
      SangamLog.event("pip: nothing to float")
      onError?("There’s no video to float yet — turn your camera on or wait for someone to join.")
      return
    }
    startWhenPossible(controller)
  }

  /// AVKit honors `startPictureInPicture` only once it deems it possible —
  /// the content must be there and the source on screen. The first frame
  /// usually lands moments after attaching, so wait for the possible flag
  /// instead of firing blind (which fails silently).
  private func startWhenPossible(_ controller: AVPictureInPictureController) {
    if controller.isPictureInPicturePossible {
      SangamLog.event("pip: start (immediately possible) — \(diagnosticState)")
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
        SangamLog.event("pip: start (became possible) — \(self.diagnosticState)")
        controller.startPictureInPicture()
      }
    }
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard let self, self.possibleObservation != nil else { return }
      self.possibleObservation = nil
      SangamLog.event("pip: never became possible — \(self.diagnosticState)")
      self.onError?(
        "Picture in Picture could not start — the video never reached the system player.")
    }
  }

  /// Follows stage changes while the floating window is up: the featured
  /// remote stream, else back to the self view, else the window closes.
  func showRemote(_ stream: RemoteVideoStream?, localFallback: LocalVideoTrack?) {
    follow(remote: stream, localFallback: localFallback)
  }
}

extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    let failure = error as NSError
    Task { @MainActor in
      SangamLog.event(
        "pip: failed to start: \(failure.domain) \(failure.code) "
          + "info=\(failure.userInfo) — \(self.diagnosticState)")
      self.onError?(
        "Picture in Picture could not start (\(failure.domain) \(failure.code)).")
    }
  }

  nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    Task { @MainActor in
      SangamLog.event("pip: started")
      self.isActive = true
      // Whatever is featured now, not whatever was attached last. Automatic
      // PiP starts without asking, and this is the first moment the window
      // is certainly showing something.
      self.followCurrent()
      self.onActiveChanged?(true)
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    Task { @MainActor in
      // The track stays attached: the call is still running, and the next
      // backgrounding needs live content to float.
      self.isActive = false
      self.onActiveChanged?(false)
    }
  }
}

#if os(macOS)
  /// Live video has no timeline: playback is always "playing" over an
  /// infinite range, and skipping means nothing. Only the sample-buffer route
  /// asks for this; iOS's video-call route has no such delegate, which is
  /// rather the point of it.
  extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
      _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
      CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
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

  /// Hosts the bridge's display layer in the view hierarchy — the
  /// sample-buffer route requires the content layer to live in a window.
  /// Kept tiny and effectively invisible beneath the stage; the system window
  /// does the real rendering.
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
  /// Keeps the display layer filling whatever it is put in — the floating
  /// window resizes, and a CALayer does not follow its host on its own.
  private final class SampleBufferHostView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
      self.displayLayer = displayLayer
      super.init(frame: .zero)
      displayLayer.videoGravity = .resizeAspect
      layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("PiP host is never decoded") }

    override func layoutSubviews() {
      super.layoutSubviews()
      // The floating window resizes in one step; an implicit animation would
      // drag the video behind the frame it is meant to fill.
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      displayLayer.frame = bounds
      CATransaction.commit()
    }
  }

  /// The view AVKit animates the floating window out of and back into. It
  /// carries no content of its own — the stage behind it is what is on screen
  /// inline — so it stays clear and takes no touches.
  ///
  /// Entering a window is the signal to build the controller: it is the one
  /// moment AVKit's requirement is certainly met, and unlike an update pass
  /// it is guaranteed to arrive.
  private final class PiPSourceView: UIView {
    var onAttached: ((UIView) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else { return }
      onAttached?(self)
    }
  }

  /// Places that source view over the stage.
  struct PiPSourceHost: UIViewRepresentable {
    let manager: PictureInPictureManager

    func makeUIView(context: Context) -> UIView {
      let view = PiPSourceView()
      view.backgroundColor = .clear
      view.isUserInteractionEnabled = false
      view.onAttached = { [manager] attached in manager.prepare(sourceView: attached) }
      return view
    }

    /// Also on update, so a view that was swapped in without a fresh window
    /// notification still rebinds the content source.
    func updateUIView(_ view: UIView, context: Context) {
      manager.prepare(sourceView: view)
    }
  }
#endif
