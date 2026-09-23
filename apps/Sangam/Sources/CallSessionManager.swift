#if os(iOS)
  import AVFoundation
  import CallKit
  import Foundation
  import JitsiMedia
  import UIKit

  /// Reports the active meeting to CallKit so it behaves like a call:
  /// call-priority audio that survives backgrounding, mute from system
  /// surfaces, and clean arbitration with phone calls. Meetings are
  /// join-based, so every call is "outgoing"; there is no incoming-call UI
  /// until a push-based invite server exists.
  @MainActor
  final class CallSessionManager: NSObject {
    static let shared = CallSessionManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    /// CallKit's callbacks arrive here rather than on the main thread.
    /// `didActivate` hands the session straight to WebRTC, which starts its
    /// audio units and calls `AVAudioSession.setActive` — a call that blocks
    /// for long enough that, on the main thread, UIKit's system gesture gate
    /// times out and drops the touches that arrive during it (taps on the
    /// control bar and its menu simply do nothing). RTCAudioSession takes its
    /// own lock, and every other delegate method hops to the main actor
    /// explicitly, so none of them need this queue to be the main one.
    private let providerQueue = DispatchQueue(label: "com.twarge.sangam.callkit")
    fileprivate var currentCallID: UUID?
    fileprivate var endRequestedLocally = false
    /// The window scene the meeting was joined from. Scenes come and go for
    /// other reasons — AVKit hosts video-call Picture in Picture in a scene
    /// of its own, and rebuilding the PiP controller disconnects the old
    /// one — so only this scene's disconnect means the meeting's window
    /// closed. Ending the call on any disconnect reported the meeting over
    /// moments after it began, and CallKit then took the audio session
    /// away from WebRTC: a joined meeting with no audio either way.
    fileprivate weak var meetingScene: UIWindowScene?

    private override init() {
      let configuration = CXProviderConfiguration()
      configuration.supportsVideo = true
      configuration.maximumCallGroups = 1
      configuration.maximumCallsPerCallGroup = 1
      configuration.supportedHandleTypes = [.generic]
      provider = CXProvider(configuration: configuration)
      super.init()
      provider.setDelegate(self, queue: providerQueue)
      // Closing the window is not a call failure, but CallKit reports one if
      // the call is still up when the scene or the process goes. The view's
      // own teardown does not reliably run for a window being closed, so the
      // end is taken from the system's own notices instead.
      // UIKit posts both on the main thread.
      NotificationCenter.default.addObserver(
        self, selector: #selector(sceneDidDisconnect(_:)),
        name: UIScene.didDisconnectNotification, object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(applicationWillTerminate),
        name: UIApplication.willTerminateNotification, object: nil)
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
      guard let scene = notification.object as? UIWindowScene else { return }
      let isMeetingScene = scene === meetingScene
      SangamLog.event(
        "callkit: scene disconnected role=\(scene.session.role.rawValue) meeting=\(isMeetingScene)")
      if isMeetingScene { endImmediately() }
    }

    @objc private func applicationWillTerminate() {
      endImmediately()
    }

    /// Ends the call through the provider rather than a transaction. A
    /// transaction is a round trip through the call controller, and a
    /// teardown does not always last long enough for one; reporting the end
    /// straight to the provider lands in the time there is.
    private func endImmediately() {
      guard let callID = currentCallID else { return }
      SangamLog.event("callkit: ending on teardown")
      currentCallID = nil
      meetingScene = nil
      endRequestedLocally = false
      provider.reportCall(with: callID, endedAt: nil, reason: .remoteEnded)
    }

    /// Puts WebRTC's audio into CallKit's hands. Called at app launch,
    /// before the first call's audio units exist.
    static func prepareAudio() {
      CallKitAudioBridge.prepare()
      if SangamLog.isEnabled { CallKitAudioBridge.enableVerboseLogging() }
      SangamLog.event("callkit: audio prepared — \(CallKitAudioBridge.diagnosticState)")
    }

    func begin(room: String) {
      guard currentCallID == nil else { return }
      let callID = UUID()
      currentCallID = callID
      meetingScene = Self.keyWindowScene()
      let start = CXStartCallAction(
        call: callID, handle: CXHandle(type: .generic, value: room))
      start.isVideo = true
      SangamLog.event("callkit: requesting start — \(CallKitAudioBridge.diagnosticState)")
      callController.request(CXTransaction(action: start)) { error in
        guard error != nil else { return }
        Task { @MainActor in
          // CallKit refused (parental controls, region policy): run audio
          // without it rather than joining a silent meeting.
          SangamLog.event("callkit: start refused, running without it")
          CallKitAudioBridge.runWithoutCallKit()
          CallSessionManager.shared.currentCallID = nil
        }
      }
    }

    func end() {
      guard let callID = currentCallID else { return }
      endRequestedLocally = true
      callController.request(CXTransaction(action: CXEndCallAction(call: callID))) { error in
        guard let error else { return }
        Task { @MainActor in
          // A swallowed failure here left the system call — and its lock
          // screen entry — running after the meeting was over. Report the
          // end straight to the provider so nothing outlives the meeting.
          SangamLog.event("callkit: end refused, reporting directly: \(error)")
          CallSessionManager.shared.reportEnded(callID)
        }
      }
    }

    /// Mirrors an in-app mute into the system call UI.
    func setMuted(_ muted: Bool) {
      guard let callID = currentCallID else { return }
      callController.request(
        CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))
      ) { _ in }
    }

    private func reportEnded(_ callID: UUID) {
      provider.reportCall(with: callID, endedAt: nil, reason: .remoteEnded)
      currentCallID = nil
      meetingScene = nil
      endRequestedLocally = false
    }

    /// The scene the user is acting in: the one holding the key window. With
    /// a single window that is simply the app's window; on iPad it is the
    /// window the Join button was tapped in.
    private static func keyWindowScene() -> UIWindowScene? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      return scenes.first { $0.windows.contains(where: \.isKeyWindow) }
        ?? scenes.first { $0.activationState == .foregroundActive }
    }

    fileprivate func reportConnected(_ callID: UUID) {
      provider.reportOutgoingCall(with: callID, startedConnectingAt: nil)
      provider.reportOutgoingCall(with: callID, connectedAt: nil)
      reportVideo(callID)
    }

    /// Whether the call is carrying the camera, for the system's call UI.
    /// A video call is one the side button locks rather than ends.
    private var sendsVideo = true

    /// Mirrors the camera state into the system call. Held until the call
    /// is connected if it arrives before then.
    func setSendsVideo(_ sends: Bool) {
      sendsVideo = sends
      guard let callID = currentCallID else { return }
      reportVideo(callID)
    }

    private func reportVideo(_ callID: UUID) {
      let update = CXCallUpdate()
      update.hasVideo = sendsVideo
      provider.reportCall(with: callID, updated: update)
    }
  }

  extension CallSessionManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
      SangamLog.event("callkit: start action performed — \(CallKitAudioBridge.diagnosticState)")
      action.fulfill()
      Task { @MainActor in
        let manager = CallSessionManager.shared
        if let callID = manager.currentCallID {
          manager.reportConnected(callID)
        }
      }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
      SangamLog.event("callkit: end action performed")
      action.fulfill()
      Task { @MainActor in
        let manager = CallSessionManager.shared
        let endedFromApp = manager.endRequestedLocally
        manager.endRequestedLocally = false
        manager.currentCallID = nil
        manager.meetingScene = nil
        // Ended from the system call UI: leave the meeting too.
        if !endedFromApp {
          MeetingHub.shared.activeController?.hangUp()
        }
      }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
      let muted = action.isMuted
      action.fulfill()
      Task { @MainActor in
        guard let controller = MeetingHub.shared.activeController,
          controller.isAudioMuted != muted
        else { return }
        controller.toggleAudio()
      }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
      SangamLog.event("callkit: audio session activated — \(CallKitAudioBridge.diagnosticState)")
      CallKitAudioBridge.audioSessionDidActivate(audioSession)
      SangamLog.event("callkit: audio handed to WebRTC — \(CallKitAudioBridge.diagnosticState)")
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
      SangamLog.event("callkit: audio session deactivated — \(CallKitAudioBridge.diagnosticState)")
      CallKitAudioBridge.audioSessionDidDeactivate(audioSession)
    }
  }
#endif
