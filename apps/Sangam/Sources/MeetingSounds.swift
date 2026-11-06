import Foundation

#if os(macOS)
  import AppKit
#else
  import AudioToolbox
#endif

/// Small audible cues for meeting events, using system sounds so the app
/// ships no audio assets. Kept quiet by design: joins, leaves, knocks, and
/// reactions only.
enum MeetingSounds {
  static func participantJoined() {
    play(mac: "Glass", ios: 1054)
  }

  static func participantLeft() {
    play(mac: "Bottle", ios: 1053)
  }

  /// Someone is waiting in the lobby to be let in.
  static func knock() {
    play(mac: "Submarine", ios: 1074)
  }

  static func reaction() {
    play(mac: "Pop", ios: 1306)
  }

  private static func play(mac name: String, ios soundID: UInt32) {
    #if os(macOS)
      NSSound(named: NSSound.Name(name))?.play()
    #else
      AudioServicesPlaySystemSound(soundID)
    #endif
  }
}
