#if os(iOS)
  import ActivityKit
  import Foundation

  /// The meeting no longer runs a Live Activity. CallKit already reports the
  /// call to the system — the lock screen, the Dynamic Island, mute and hang
  /// up all come from it — so the card only ever said the same thing a second
  /// time, and cost a battery-backed timer to say it.
  ///
  /// This remains to clear cards a previous build left behind. ActivityKit
  /// keeps an activity alive across launches, so one stranded by a crash or a
  /// force-quit would otherwise sit on the lock screen for hours with no
  /// meeting behind it and nothing left that could end it.
  @MainActor
  final class MeetingActivityController {
    static let shared = MeetingActivityController()

    func end() {
      Task.detached {
        for activity in Activity<MeetingActivityAttributes>.activities {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
      }
    }
  }
#endif
