#if os(iOS)
  import AVFoundation
  import CallKit
  import Foundation
  import JitsiMedia

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
    fileprivate var currentCallID: UUID?
    fileprivate var endRequestedLocally = false

    private override init() {
      let configuration = CXProviderConfiguration()
      configuration.supportsVideo = true
      configuration.maximumCallGroups = 1
      configuration.maximumCallsPerCallGroup = 1
      configuration.supportedHandleTypes = [.generic]
      provider = CXProvider(configuration: configuration)
      super.init()
      // A nil queue delivers delegate callbacks on the main thread.
      provider.setDelegate(self, queue: nil)
    }

    /// Puts WebRTC's audio into CallKit's hands. Called at app launch,
    /// before the first call's audio units exist.
    static func prepareAudio() {
      CallKitAudioBridge.prepare()
    }

    func begin(room: String) {
      guard currentCallID == nil else { return }
      let callID = UUID()
      currentCallID = callID
      let start = CXStartCallAction(
        call: callID, handle: CXHandle(type: .generic, value: room))
      start.isVideo = true
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
      callController.request(CXTransaction(action: CXEndCallAction(call: callID))) { _ in }
    }

    /// Mirrors an in-app mute into the system call UI.
    func setMuted(_ muted: Bool) {
      guard let callID = currentCallID else { return }
      callController.request(
        CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))
      ) { _ in }
    }

    fileprivate func reportConnected(_ callID: UUID) {
      provider.reportOutgoingCall(with: callID, startedConnectingAt: nil)
      provider.reportOutgoingCall(with: callID, connectedAt: nil)
    }
  }

  extension CallSessionManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
      action.fulfill()
      Task { @MainActor in
        let manager = CallSessionManager.shared
        if let callID = manager.currentCallID {
          manager.reportConnected(callID)
        }
      }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
      action.fulfill()
      Task { @MainActor in
        let manager = CallSessionManager.shared
        let endedFromApp = manager.endRequestedLocally
        manager.endRequestedLocally = false
        manager.currentCallID = nil
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
      CallKitAudioBridge.audioSessionDidActivate(audioSession)
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
      CallKitAudioBridge.audioSessionDidDeactivate(audioSession)
    }
  }
#endif
