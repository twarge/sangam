import JitsiConference
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The meeting's stage in a window of its own (its own scene on iPad), for a
/// second display: whatever the main stage features — the pinned feed, else
/// a screen share, else the active speaker — following the meeting as it
/// changes. A feed window holds one source; this holds none, and shows the
/// stage even while the main window shows the grid.
struct StageWindow: View {
  /// The one value the stage's window group is ever opened with. A
  /// value-keyed group brings forward the window already showing a value
  /// instead of opening another, so there is only ever one stage window.
  static let singleton = "stage"

  @ObservedObject private var hub = MeetingHub.shared

  var body: some View {
    Group {
      if let model = hub.activeModel {
        StageContent(model: model)
      } else {
        StageUnavailable(
          title: "No meeting in progress",
          description: "The stage appears here when you join a meeting."
        )
      }
    }
    .navigationTitle("Stage")
    #if os(macOS)
      .frame(minWidth: 320, minHeight: 200)
      .background(FreeDisplayPlacement())
    #endif
  }
}

/// The featured tile, framed as the main stage frames it. It keeps no
/// receive-quality bookkeeping of its own, unlike a feed window: the
/// featured source is always one the main surface asks the bridge to send at
/// full quality.
private struct StageContent: View {
  @ObservedObject var model: NativeMeetingModel

  var body: some View {
    Group {
      if let tile = model.featuredTile {
        MeetingTileView(
          tile: tile,
          isDominantSpeaker: tile.endpointID != nil && tile.endpointID == model.dominantSpeakerID,
          isPinned: tile.id == model.pinnedTileID,
          fitsVideoAspect: true,
          stat: tile.stream.flatMap { model.streamStats[$0.id] },
          reaction: tile.endpointID.flatMap { model.tileReactions[$0]?.emoji }
        )
        // The main stage's margin, so the feed's corner reads as a corner.
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        StageUnavailable(
          title: "You’re the only one in the meeting",
          description: "Whoever speaks or shares appears here when others join."
        )
      }
    }
    .background(.black)
    // The video runs under the transparent title bar, edge to edge.
    .ignoresSafeArea()
  }
}

private struct StageUnavailable: View {
  let title: String
  let description: String

  var body: some View {
    ContentUnavailableView(
      title, systemImage: "rectangle.on.rectangle", description: Text(description)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
    .environment(\.colorScheme, .dark)
  }
}

#if os(macOS)
  /// Moves the window it is placed in onto a display no other Sangam window
  /// is on, filling it, once, when the window opens: the stage is for a
  /// second screen. With one display, none free, or the window already on a
  /// display of its own, it stays where macOS put it.
  private struct FreeDisplayPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ view: PlacementView, context: Context) {}

    final class PlacementView: NSView {
      private var placed = false

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !placed, let window else { return }
        placed = true
        // A turn later, once SwiftUI has given the window its default frame
        // and ordered it in — placing it earlier, the window would be put
        // back.
        Task { @MainActor [weak window] in
          guard let window else { return }
          Self.place(window)
        }
      }

      private static func place(_ window: NSWindow) {
        let others = NSApp.windows.filter {
          $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
        }
        func isFree(_ screen: NSScreen) -> Bool {
          !others.contains { $0.screen?.displayID == screen.displayID }
        }
        if let current = window.screen, isFree(current) { return }
        guard let free = NSScreen.screens.first(where: isFree) else { return }
        window.setFrame(free.visibleFrame, display: true)
      }
    }
  }

  extension NSScreen {
    fileprivate var displayID: CGDirectDisplayID? {
      deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
  }
#endif
