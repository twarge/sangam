import JitsiConference
import SwiftUI

/// A single feed in its own window (its own scene on iPad): opened by
/// double-clicking a sidebar thumbnail. The stream is resolved live from
/// the active meeting, so the window follows renegotiations and shows a
/// placeholder once the feed is gone.
struct FeedWindow: View {
  let streamID: String

  @ObservedObject private var hub = MeetingHub.shared

  var body: some View {
    Group {
      if let model = hub.activeModel {
        FeedContent(model: model, streamID: streamID)
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
  let streamID: String

  var body: some View {
    Group {
      if let stream = model.streams.first(where: { $0.id == streamID }) {
        NativeVideoSurface(track: stream.track)
          .navigationTitle(title(for: stream))
      } else {
        FeedUnavailable()
      }
    }
    .background(.black)
    // The video runs under the transparent title bar, edge to edge.
    .ignoresSafeArea()
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
      "This feed has ended",
      systemImage: "video.slash",
      description: Text("It closed when its sender stopped, or the meeting ended.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
    .environment(\.colorScheme, .dark)
    .navigationTitle("Feed")
  }
}
