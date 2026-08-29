import SwiftUI

struct RootView: View {
  @AppStorage("serverURL") private var serverURL = MeetingConfiguration.defaultServerURL
    .absoluteString
  @AppStorage("displayName") private var displayName = ""
  @AppStorage("room") private var room = ""
  @State private var activeMeeting: MeetingConfiguration?
  @ObservedObject private var hub = MeetingHub.shared

  var body: some View {
    Group {
      if let activeMeeting {
        MeetingView(configuration: activeMeeting) {
          self.activeMeeting = nil
        }
        // A different meeting is a different view tree: joining a link
        // while already in a room tears the old meeting down cleanly.
        .id(activeMeeting)
      } else {
        JoinView(
          serverURL: $serverURL,
          room: $room,
          displayName: $displayName,
          join: join
        )
      }
    }
    .frame(minWidth: 320, minHeight: 400)
    // The window is named after the meeting while one is active.
    .navigationTitle(activeMeeting?.normalizedRoom ?? "Sangam")
    // Meeting links: the sangam scheme, universal links once a deployment
    // registers its domain, and Handoff from another device.
    .onOpenURL { url in
      MeetingHub.shared.requestJoin(url: url)
    }
    .onContinueUserActivity(MeetingHub.meetingActivityType) { activity in
      if let url = activity.webpageURL { MeetingHub.shared.requestJoin(url: url) }
    }
    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { MeetingHub.shared.requestJoin(url: url) }
    }
    .onReceive(hub.$pendingJoin) { pending in
      guard let pending else { return }
      hub.pendingJoin = nil
      activeMeeting = pending
      room = pending.room
      serverURL = pending.serverURL.absoluteString
    }
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
