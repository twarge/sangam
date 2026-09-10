import SwiftUI

@main
struct SangamApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(ConversationApplicationDelegate.self) private
      var conversationDelegate
  #endif
  init() {
    #if os(macOS) && DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if #available(macOS 26, *), let index = arguments.firstIndex(of: "--conversation-self-test"),
        index + 2 < arguments.count
      {
        Task { @MainActor in
          let success = await ConversationSession.runSpeechSelfTest(
            URL(fileURLWithPath: arguments[index + 1]), URL(fileURLWithPath: arguments[index + 2]))
          exit(success ? 0 : 1)
        }
      }
      if #available(macOS 26, *), let index = arguments.firstIndex(of: "--microphone-check") {
        let seconds =
          index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 10 : 10
        Task { @MainActor in
          let success = await AppleMeetingTranscriber.runMicrophoneCheck(seconds: seconds)
          exit(success ? 0 : 1)
        }
      }
    #endif
    #if os(iOS)
      // CallKit owns audio activation; WebRTC must be in manual-audio mode
      // before the first call's audio units exist.
      CallSessionManager.prepareAudio()
      // The meeting's Live Activity is gone — CallKit already puts the call
      // on the lock screen and in the Dynamic Island, so the card said it all
      // twice. An activity outlives the process that started it, though, so a
      // build that still ran one can have left a card behind. Nothing is
      // running yet at launch, which makes any card still up stale by
      // definition.
      MeetingActivityController.shared.end()
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
      // Full-bleed video: the title bar is transparent, with the traffic
      // lights floating over the feed like the main meeting window.
      .windowStyle(.hiddenTitleBar)
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
