/// Transition adapter that hosts the official Jitsi iOS SDK. It exists only so
/// the native transport can be compared against a known-good client during
/// bring-up, is selected with `SANGAM_LEGACY_JITSI=1`, and is deleted once the
/// native path clears the end-to-end conference gate. macOS has no legacy
/// surface: its WebKit iframe adapter has been removed.
#if os(iOS)
  import JitsiMeetSDK
  import SwiftUI
  import UIKit

  struct PlatformMeetingSurface: UIViewRepresentable {
    let configuration: MeetingConfiguration
    let controller: MeetingController

    func makeCoordinator() -> Coordinator {
      Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> JitsiMeetView {
      let view = JitsiMeetView()
      view.backgroundColor = .black
      view.delegate = context.coordinator
      context.coordinator.attach(to: view)

      let options = JitsiMeetConferenceOptions.fromBuilder { builder in
        builder.serverURL = configuration.serverURL
        builder.room = configuration.normalizedRoom
        if !configuration.displayName.isEmpty {
          builder.userInfo = JitsiMeetUserInfo(
            displayName: configuration.displayName,
            andEmail: nil,
            andAvatar: nil
          )
        }
        builder.setFeatureFlag("ios.screensharing.enabled", withBoolean: true)
        builder.setFeatureFlag("toolbox.enabled", withBoolean: false)
        builder.setFeatureFlag("filmstrip.enabled", withBoolean: false)
        builder.setFeatureFlag("meeting-name.enabled", withBoolean: false)
        builder.setFeatureFlag("conference-timer.enabled", withBoolean: false)
        builder.setFeatureFlag("prejoinpage.enabled", withBoolean: false)
        builder.setFeatureFlag("welcomepage.enabled", withBoolean: false)
      }

      DispatchQueue.main.async {
        view.join(options)
      }
      return view
    }

    func updateUIView(_ uiView: JitsiMeetView, context: Context) {}

    static func dismantleUIView(_ uiView: JitsiMeetView, coordinator: Coordinator) {
      coordinator.detach()
      uiView.leave()
    }

    @MainActor
    final class Coordinator: NSObject, JitsiMeetViewDelegate {
      private let controller: MeetingController
      private weak var view: JitsiMeetView?

      init(controller: MeetingController) {
        self.controller = controller
      }

      func attach(to view: JitsiMeetView) {
        self.view = view
        controller.attach { [weak self] command in
          self?.execute(command)
        }
      }

      func detach() {
        controller.detach()
        view = nil
      }

      func conferenceJoined(_ data: [AnyHashable: Any]!) {
        controller.didJoin()
      }

      func conferenceTerminated(_ data: [AnyHashable: Any]!) {
        controller.didEnd(error: data?["error"] as? String)
      }

      func ready(toClose data: [AnyHashable: Any]!) {
        controller.didEnd()
      }

      func audioMutedChanged(_ data: [AnyHashable: Any]!) {
        if let muted = data?["muted"] as? Bool {
          controller.didChangeAudioMuted(muted)
        }
      }

      func videoMutedChanged(_ data: [AnyHashable: Any]!) {
        if let muted = data?["muted"] as? Bool {
          controller.didChangeVideoMuted(muted)
        }
      }

      func screenShareToggled(_ data: [AnyHashable: Any]!) {
        if let sharing = data?["sharing"] as? Bool {
          controller.didChangeScreenSharing(sharing)
        }
      }

      private func execute(_ command: MeetingController.Command) {
        guard let view else { return }
        switch command {
        case .setAudioMuted(let muted):
          view.setAudioMuted(muted)
        case .setVideoMuted(let muted):
          view.setVideoMuted(muted)
        case .setScreenSharing(let enabled):
          view.toggleScreenShare(enabled)
        case .switchCamera:
          // The SDK path only flips between its own cameras.
          view.toggleCamera()
        case .authenticate, .waitForHost, .cancelWaiting, .admitLobbyParticipant,
          .denyLobbyParticipant, .setHandRaised, .sendChatMessage, .sendReaction,
          .kickParticipant, .grantModerator, .muteParticipant, .setReceiveQuality,
          .setAudioModeration, .allowToSpeak, .setBackgroundBlur:
          break
        case .hangUp:
          view.hangUp()
        }
      }
    }
  }
#endif
