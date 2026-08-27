#if os(macOS)
  import AppKit
  import SwiftUI

  /// The menu bar extra's contents: quick controls for the active meeting
  /// while its window is buried under other work.
  struct MenuBarControls: View {
    @ObservedObject private var hub = MeetingHub.shared

    var body: some View {
      if let controller = hub.activeController, let configuration = hub.activeConfiguration {
        ActiveMeetingMenu(controller: controller, configuration: configuration)
      } else {
        Text("No active meeting")
      }
    }
  }

  private struct ActiveMeetingMenu: View {
    @ObservedObject var controller: MeetingController
    let configuration: MeetingConfiguration

    var body: some View {
      Text(configuration.normalizedRoom)
      Divider()
      Button(controller.isAudioMuted ? "Unmute" : "Mute") {
        controller.toggleAudio()
      }
      Button(controller.isVideoMuted ? "Start Video" : "Stop Video") {
        controller.toggleVideo()
      }
      Button(controller.isHandRaised ? "Lower Hand" : "Raise Hand") {
        controller.toggleHandRaised()
      }
      Divider()
      Button("Open Sangam") {
        NSApp.activate(ignoringOtherApps: true)
      }
      Button("Leave Meeting") {
        controller.hangUp()
      }
    }
  }
#endif
