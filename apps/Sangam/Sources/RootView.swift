import SwiftUI

struct RootView: View {
  @AppStorage("serverURL") private var serverURL = MeetingConfiguration.defaultServerURL
    .absoluteString
  @AppStorage("displayName") private var displayName = ""
  @State private var room = ""
  @State private var activeMeeting: MeetingConfiguration?

  var body: some View {
    Group {
      if let activeMeeting {
        MeetingView(configuration: activeMeeting) {
          self.activeMeeting = nil
        }
      } else {
        JoinView(
          serverURL: $serverURL,
          room: $room,
          displayName: $displayName,
          join: join
        )
      }
    }
    .frame(minWidth: 360, minHeight: 520)
    // The window is named after the meeting while one is active.
    .navigationTitle(activeMeeting?.normalizedRoom ?? "Sangam")
  }

  private func join() {
    guard
      let server = URL(string: serverURL),
      let scheme = server.scheme?.lowercased(),
      scheme == "https" || (scheme == "http" && server.host == "localhost")
    else { return }

    let normalizedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRoom.isEmpty else { return }

    activeMeeting = MeetingConfiguration(
      serverURL: server,
      room: normalizedRoom,
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}
