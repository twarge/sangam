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

    // A double-clicked sidebar feed in its own window (its own scene on
    // iPad); keyed by stream id, so reopening the same feed refocuses the
    // existing window.
    WindowGroup("Feed", id: "feed", for: String.self) { $streamID in
      if let streamID {
        FeedWindow(streamID: streamID)
      } else {
        Text("No feed selected")
      }
    }
    #if os(macOS)
      .defaultSize(width: 640, height: 400)
    #endif

    #if os(macOS)
      Settings {
        SettingsView()
      }

      // Quick call controls while the meeting window is buried. Always
      // inserted: toggling a MenuBarExtra via isInserted re-enters the
      // scene update (the status item's visibility KVO dirties the SwiftUI
      // graph mid-evaluation) and overflows the stack, so the item stays
      // and its CONTENT reflects whether a meeting is on.
      MenuBarExtra {
        MenuBarControls()
      } label: {
        Image(systemName: "video.fill")
      }
    #endif
  }
}
