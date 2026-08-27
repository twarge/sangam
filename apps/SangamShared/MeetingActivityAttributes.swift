// ActivityKit exists in the macOS SDK but is marked unavailable there, so
// canImport alone is not a sufficient guard.
#if os(iOS)
  import ActivityKit
  import Foundation

  /// The Live Activity's shape, shared between the app (which starts and
  /// updates it) and the widget extension (which renders it). Explicitly
  /// nonisolated: ActivityKit uses the conformance off the main actor, and
  /// the app target defaults new types onto it.
  nonisolated struct MeetingActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
      var muted: Bool
    }

    var roomName: String
    var startedAt: Date
  }
#endif
