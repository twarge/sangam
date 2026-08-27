import SwiftUI

@main
struct SangamApp: App {
  @ObservedObject private var hub = MeetingHub.shared

  init() {
    #if os(iOS)
      // CallKit owns audio activation; WebRTC must be in manual-audio mode
      // before the first call's audio units exist.
      CallSessionManager.prepareAudio()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
    #if os(macOS)
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1100, height: 700)
      .windowResizability(.contentMinSize)
    #endif

    #if os(macOS)
      Settings {
        SettingsView()
      }

      // Quick call controls while the meeting window is buried.
      MenuBarExtra(isInserted: $hub.menuBarVisible) {
        MenuBarControls()
      } label: {
        Image(systemName: "video.fill")
      }
    #endif
  }
}
