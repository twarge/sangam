import SwiftUI

@main
struct SangamApp: App {
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
    #endif
  }
}
