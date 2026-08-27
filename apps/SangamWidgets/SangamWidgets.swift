import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SangamWidgets: WidgetBundle {
  var body: some Widget {
    MeetingLiveActivity()
  }
}

/// The ongoing-meeting Live Activity: room, elapsed time, and microphone
/// state on the lock screen and in the Dynamic Island.
struct MeetingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: "video.fill")
          .font(.title3)
          .foregroundStyle(.green)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.attributes.roomName)
            .font(.headline)
            .lineLimit(1)
          Text(context.attributes.startedAt, style: .timer)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Spacer()
        MicBadge(muted: context.state.muted)
      }
      .padding(14)
      .activityBackgroundTint(Color.black.opacity(0.6))
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "video.fill")
            .font(.title2)
            .foregroundStyle(.green)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 2) {
            Text(context.attributes.roomName)
              .font(.headline)
              .lineLimit(1)
            Text(context.attributes.startedAt, style: .timer)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          MicBadge(muted: context.state.muted)
        }
      } compactLeading: {
        Image(systemName: "video.fill")
          .foregroundStyle(.green)
      } compactTrailing: {
        Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
          .foregroundStyle(context.state.muted ? .red : .green)
      } minimal: {
        Image(systemName: "video.fill")
          .foregroundStyle(.green)
      }
    }
  }
}

private struct MicBadge: View {
  let muted: Bool

  var body: some View {
    Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
      .font(.title3)
      .foregroundStyle(muted ? .red : .green)
  }
}
