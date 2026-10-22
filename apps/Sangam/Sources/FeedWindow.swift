import JitsiConference
import SwiftUI

/// A single feed in its own window (its own scene on iPad): opened by
/// double-clicking a sidebar thumbnail. The window holds the source, not
/// the stream: it is resolved live from the active meeting by `sourceID`,
/// so it follows the source when an SSRC-rewriting bridge moves it to
/// another receive slot, shows a placeholder while it is not being sent,
/// and picks it up again when it returns.
struct FeedWindow: View {
  let sourceID: String

  @ObservedObject private var hub = MeetingHub.shared

  var body: some View {
    Group {
      if let model = hub.activeModel {
        FeedContent(model: model, sourceID: sourceID)
      } else {
        FeedUnavailable()
      }
    }
    #if os(macOS)
      .frame(minWidth: 320, minHeight: 200)
    #endif
  }
}

private struct FeedContent: View {
  @ObservedObject var model: NativeMeetingModel
  let sourceID: String

  var body: some View {
    Group {
      if let stream = model.streams.first(where: { $0.sourceID == sourceID }) {
        NativeVideoSurface(track: stream.track)
          .navigationTitle(title(for: stream))
      } else {
        FeedUnavailable()
      }
    }
    .background(.black)
    // The video runs under the transparent title bar, edge to edge.
    .ignoresSafeArea()
    // A floated feed renders large, so its source must keep full receive
    // quality even while the main window shows it as a thumbnail (or not
    // at all).
    .onAppear { model.openFeedSourceIDs.insert(sourceID) }
    .onDisappear { model.openFeedSourceIDs.remove(sourceID) }
  }

  private func title(for stream: RemoteVideoStream) -> String {
    let owner = model.participants.first { $0.id == stream.endpointID }?.displayName
    let kind = stream.videoType == "desktop" ? "Screen" : "Camera"
    if let owner { return "\(owner) — \(kind)" }
    return kind
  }
}

private struct FeedUnavailable: View {
  var body: some View {
    ContentUnavailableView(
      "This feed has stopped",
      systemImage: "video.slash",
      description: Text(
        "Its sender stopped sending, or the meeting ended. It picks up here if they start again.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
    .environment(\.colorScheme, .dark)
    .navigationTitle("Feed")
  }
}
