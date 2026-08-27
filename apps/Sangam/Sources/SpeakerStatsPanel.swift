import SwiftUI

/// Who has held the floor for how long — seeded from the deployment's
/// speaker-stats history and ticking live for the current speaker.
struct SpeakerStatsPanel: View {
  @ObservedObject var controller: MeetingController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if controller.speakerStats.isEmpty {
          ContentUnavailableView(
            "No speaker time yet",
            systemImage: "waveform",
            description: Text("Time accumulates as people speak.")
          )
        } else {
          List(controller.speakerStats) { stat in
            HStack(spacing: 10) {
              Image(systemName: stat.isSpeaking ? "waveform" : "person.fill")
                .foregroundStyle(stat.isSpeaking ? Color.accentColor : .secondary)
                .frame(width: 22)
              Text(stat.name)
                .foregroundStyle(stat.hasLeft ? .secondary : .primary)
              if stat.hasLeft {
                Text("left")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 1)
                  .background(.quaternary, in: .capsule)
              }
              Spacer(minLength: 12)
              Text(Self.format(stat.seconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("Speaker Stats")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 380, minHeight: 400)
    #endif
  }

  private static func format(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }
}
