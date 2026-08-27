#if os(iOS)
  import ActivityKit
  import Foundation

  /// Drives the ongoing-meeting Live Activity: started on join, microphone
  /// state kept current, ended on leave.
  @MainActor
  final class MeetingActivityController {
    static let shared = MeetingActivityController()

    /// Activities are not Sendable; background work looks the activity up
    /// by this id in its own isolation region.
    private var activityID: String?

    func begin(room: String) {
      guard activityID == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let activity = try? Activity.request(
        attributes: MeetingActivityAttributes(roomName: room, startedAt: Date()),
        content: .init(state: .init(muted: false), staleDate: nil)
      )
      activityID = activity?.id
    }

    func update(muted: Bool) {
      guard let id = activityID else { return }
      Task.detached {
        for activity in Activity<MeetingActivityAttributes>.activities where activity.id == id {
          await activity.update(.init(state: .init(muted: muted), staleDate: nil))
        }
      }
    }

    func end() {
      guard let id = activityID else { return }
      activityID = nil
      Task.detached {
        for activity in Activity<MeetingActivityAttributes>.activities where activity.id == id {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
      }
    }
  }
#endif
