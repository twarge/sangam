import JitsiConference
import JitsiMedia
import SwiftUI

#if os(iOS)
  import ReplayKit
#endif
#if os(macOS)
  import AppKit
#endif

#if os(iOS)
  /// The legacy adapter survives on iOS only, so macOS always runs the native
  /// transport and never consults this switch.
  enum NativeTransportMode {
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["SANGAM_LEGACY_JITSI"] != "1"
    }
  }
#endif

struct NativeMeetingSurface: View {
  let configuration: MeetingConfiguration
  @ObservedObject var controller: MeetingController

  @StateObject private var model = NativeMeetingModel()
  @Environment(\.openWindow) private var openWindow
  /// The floating sidebar's width, draggable at its trailing edge and
  /// remembered across meetings.
  @AppStorage("sidebarWidth") private var sidebarWidth = 236.0
  /// Whether the sidebar and chat panel push the stage aside instead of
  /// floating over it; the same key AppSettings writes.
  @AppStorage("panelsPushStage") private var panelsPushStage = false


  var body: some View {
    meetingRoot
      .overlay(alignment: .bottomTrailing) {
        // AVKit needs the PiP content layer in a window; it hides in the
        // corner while the system window does the real rendering.
        PiPLayerHost(layer: model.pictureInPicture.bridge.layer) {
          model.pictureInPicture.prepareIfNeeded()
          controller.didChangePictureInPicture(
            available: model.pictureInPicture.isSupported,
            active: model.pictureInPicture.isActive
          )
        }
        .frame(width: 64, height: 36)
        .opacity(0.02)
        .allowsHitTesting(false)
      }
      .onChange(of: model.featuredRemoteStream?.id) { _, _ in
        model.pictureInPicture.showRemote(
          model.featuredRemoteStream, localFallback: model.localCameraTrack)
      }
      // The stats panel ticks once a second while open, so the current
      // speaker's time counts up live.
      .task(id: controller.showsSpeakerStats) {
        guard controller.showsSpeakerStats else { return }
        while !Task.isCancelled, controller.showsSpeakerStats {
          await model.refreshSpeakerStats(controller: controller)
          try? await Task.sleep(for: .seconds(1))
        }
      }
      .task {
        await model.join(configuration: configuration, controller: controller)
      }
      .onDisappear {
        model.leave(controller: controller)
      }
      #if os(iOS)
        .sheet(isPresented: $model.showsBroadcastPicker) {
          NativeBroadcastPickerSheet()
          .presentationDetents([.height(220)])
        }
      #endif
  }

  #if os(macOS)
    /// The stage fills the whole window — edge to edge, under the sidebar —
    /// and the participant roster floats over it as a dark translucent panel.
    /// One section per person, the name as its header, and a selectable
    /// thumbnail row per feed beneath; audio-only participants are just their
    /// header. Selecting a thumbnail pins it to the stage.
    private var meetingRoot: some View {
      Group {
        if panelsPushStage {
          // Push mode: the stage narrows to make room for the panel.
          HStack(spacing: 0) {
            if !model.sidebarCollapsed { sidebarPanel }
            detailContent
              .ignoresSafeArea()
          }
        } else {
          // Float mode: the stage runs edge to edge under the panel.
          ZStack(alignment: .leading) {
            detailContent
              .ignoresSafeArea()
            if !model.sidebarCollapsed { sidebarPanel }
          }
        }
      }
      .animation(.snappy, value: model.sidebarCollapsed)
      .animation(.snappy, value: panelsPushStage)
      .onAppear { reportSidebarInset() }
      .onChange(of: model.sidebarCollapsed) { _, _ in reportSidebarInset() }
      .onChange(of: sidebarWidth) { _, _ in reportSidebarInset() }
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button {
            model.sidebarCollapsed.toggle()
          } label: {
            Image(systemName: "sidebar.left")
          }
          .help(model.sidebarCollapsed ? "Show participants" : "Hide participants")
          .keyboardShortcut("s", modifiers: [.command, .option])
        }
      }
    }

    /// The roster panel with its backdrop and resize handle. The list
    /// itself honors the toolbar's safe area; only the backdrop runs all
    /// the way to the window edge behind it.
    private var sidebarPanel: some View {
      sidebarRoster
        .scrollContentBackground(.hidden)
        .frame(width: sidebarWidth)
        .background {
          SidebarBackdrop()
            .overlay(Color.black.opacity(0.35))
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .trailing) {
          SidebarResizeHandle(width: $sidebarWidth)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    /// Tells the toolbar host how much of the left edge the sidebar
    /// occupies, so the control bar centers over the visible stage.
    private func reportSidebarInset() {
      controller.didChangeSidebarInset(model.sidebarCollapsed ? 0 : sidebarWidth)
    }

    private var sidebarRoster: some View {
      List(selection: $model.pinnedTileID) {
        Section {
          if !controller.isVideoMuted, let localCameraTrack = model.localCameraTrack {
            SidebarThumbnail(
              isPinned: false,
              videoType: nil,
              handRaised: controller.isHandRaised,
              reaction: model.tileReactions["self"]?.emoji
            ) {
              LocalVideoSurface(track: localCameraTrack)
            }
            .accessibilityLabel("Your camera")
          }
          // A live preview of the outgoing share, straight from capture.
          if controller.isScreenSharing, let localScreenTrack = model.localScreenTrack {
            SidebarThumbnail(isPinned: false, videoType: "desktop") {
              LocalVideoSurface(track: localScreenTrack)
            }
            .accessibilityLabel("Your screen share")
          }
        } header: {
          RosterHeader(
            name: "You",
            audioMuted: controller.isAudioMuted,
            handRaised: controller.isHandRaised,
            isSpeaking: false
          )
        }

        ForEach(model.roster) { entry in
          Section {
            ForEach(entry.streams) { stream in
              SidebarThumbnail(
                isPinned: model.pinnedTileID == stream.id,
                videoType: stream.videoType,
                handRaised: entry.handRaised,
                reaction: entry.endpointID.flatMap { model.tileReactions[$0]?.emoji }
              ) {
                NativeVideoSurface(track: stream.track)
              }
              .tag(stream.id)
              // A double-click floats the feed in its own window; a single
              // click still selects (pins) through the List.
              .onTapGesture(count: 2) {
                openWindow(id: "feed", value: stream.id)
              }
              .contextMenu { rosterMenu(for: entry, stream: stream) }
              .accessibilityLabel(Text("\(entry.displayName) video"))
            }
          } header: {
            RosterHeader(
              name: entry.displayName,
              audioMuted: entry.audioMuted,
              handRaised: entry.handRaised,
              isSpeaking: entry.endpointID != nil
                && entry.endpointID == model.dominantSpeakerID
            )
            .contextMenu { rosterMenu(for: entry, stream: nil) }
          }
        }
      }
      .listStyle(.sidebar)
    }

    @ViewBuilder
    private func rosterMenu(for entry: NativeMeetingModel.RosterEntry, stream: RemoteVideoStream?) -> some View {
      if let stream {
        if model.pinnedTileID == stream.id {
          Button("Unpin") { model.pinnedTileID = nil }
        } else {
          Button("Pin to stage") { model.pinnedTileID = stream.id }
        }
      }
      if model.isModerator, let endpointID = entry.endpointID,
        let participant = model.participants.first(where: { $0.id == endpointID })
      {
        if !participant.audioMuted {
          Button("Mute microphone") { controller.muteParticipant(participant.id) }
        }
        if controller.audioModerationOn {
          Button("Allow to speak") { controller.allowToSpeak(participant.id) }
        }
        if controller.breakoutRooms.count > 1 {
          Menu("Send to") {
            ForEach(controller.breakoutRooms) { room in
              Button(room.name) {
                controller.sendParticipantToBreakoutRoom(participant.id, roomJID: room.id)
              }
            }
          }
        }
        if !participant.isModerator, participant.realJID != nil {
          Button("Make moderator") { controller.grantModerator(participant.id) }
        }
        Button("Remove from meeting", role: .destructive) {
          controller.kickParticipant(participant.id)
        }
      }
    }
  #else
    private var meetingRoot: some View { detailContent }
  #endif

  @ViewBuilder
  private var detailContent: some View {
    let tiles = model.tiles
    ZStack {
      if tiles.isEmpty {
        // Alone in the meeting: the self view is the meeting, exactly like the
        // web app waiting for others to arrive.
        ZStack {
          if !controller.isVideoMuted, let localCameraTrack = model.localCameraTrack {
            LocalVideoSurface(track: localCameraTrack)
          }
          if controller.connectionState == .joined {
            VStack(spacing: 6) {
              Text("You’re the only one in the meeting")
                .font(.headline)
              Text("Others will appear here when they join.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
          }
        }
      } else if controller.usesTileGrid {
        gridView(tiles: tiles)
      } else {
        #if os(macOS)
          // The sources live in the floating sidebar; the stage is the whole
          // window, borderless and edge to edge.
          tileView(
            for: Self.featuredTile(
              in: tiles, pinned: model.pinnedTileID, dominantSpeakerID: model.dominantSpeakerID),
            flat: true
          )
        #else
          sidebarStageView(tiles: tiles)
        #endif
      }
    }
    // Before any video exists the stage has no intrinsic size; without an
    // explicit fill the leading-aligned ZStack collapses to the sidebar's
    // width and the sidebar renders centered in the window on first join.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // In push mode the open chat carves its width out of the stage instead
    // of covering it; the panel overlay then sits in the carved-out gap.
    .padding(.trailing, panelsPushStage && controller.isChatOpen ? 312 : 0)
    .background(.black)
    .overlay(alignment: .topTrailing) {
      // A corner self-preview for the grid layout only: the other layouts show
      // the local camera in the sidebar, and when nobody else is in the
      // meeting the self view already fills the window.
      if let localCameraTrack = model.localCameraTrack, !controller.isVideoMuted,
        !model.tiles.isEmpty, controller.usesTileGrid
      {
        LocalVideoSurface(track: localCameraTrack)
          .frame(width: 132, height: 176)
          .clipShape(.rect(cornerRadius: 14))
          .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.22))
          }
          .overlay(alignment: .bottomTrailing) {
            TileBadges(
              handRaised: controller.isHandRaised,
              reaction: model.tileReactions["self"]?.emoji,
              size: 22
            )
          }
          .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
          .padding(16)
          .accessibilityLabel("Your camera")
      }
    }
    .overlay(alignment: .trailing) {
      if controller.isChatOpen {
        ChatPanel(messages: model.chatMessages, send: controller.sendChatMessage)
          .frame(width: 300)
          .padding(12)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: controller.isChatOpen)
  }

  private func gridView(tiles: [NativeMeetingModel.MeetingTile]) -> some View {
    GeometryReader { geometry in
      let columns = Self.columnCount(for: tiles.count)
      let rows = Int(ceil(Double(tiles.count) / Double(columns)))
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns),
        spacing: 4
      ) {
        ForEach(tiles) { tile in
          tileView(for: tile)
            .frame(height: max(120, (geometry.size.height - 8) / CGFloat(rows)) - 4)
        }
      }
      .padding(4)
    }
  }

  /// The default layout: a collapsible left sidebar of video sources — the
  /// local camera on top — beside a stage featuring the pinned tile, a screen
  /// share, or the dominant speaker, in that order of preference.
  private func sidebarStageView(tiles: [NativeMeetingModel.MeetingTile]) -> some View {
    let featured = Self.featuredTile(
      in: tiles,
      pinned: model.pinnedTileID,
      dominantSpeakerID: model.dominantSpeakerID
    )
    return HStack(spacing: 4) {
      if !model.sidebarCollapsed {
        VStack(spacing: 6) {
          selfSidebarTile
          ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 6) {
              ForEach(tiles) { tile in
                tileView(for: tile)
                  .frame(height: 100)
                  #if os(iOS)
                    // iPad multiwindow: a double-tap floats the feed in
                    // its own scene (iPhone has no additional windows).
                    .highPriorityGesture(
                      TapGesture(count: 2).onEnded {
                        guard UIDevice.current.userInterfaceIdiom == .pad,
                          let stream = tile.stream
                        else { return }
                        openWindow(id: "feed", value: stream.id)
                      }
                    )
                  #endif
              }
            }
          }
        }
        .frame(width: 172)
        .transition(.move(edge: .leading).combined(with: .opacity))
      }
      tileView(for: featured)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(4)
    .overlay(alignment: .topLeading) {
      Button {
        model.sidebarCollapsed.toggle()
      } label: {
        Image(systemName: model.sidebarCollapsed ? "chevron.right" : "chevron.left")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 26, height: 26)
          .background(.black.opacity(0.55), in: .circle)
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .help(model.sidebarCollapsed ? "Show participants" : "Hide participants")
      .padding(10)
    }
    .animation(.snappy, value: model.sidebarCollapsed)
  }

  /// The local camera at the top of the sidebar.
  private var selfSidebarTile: some View {
    ZStack {
      if !controller.isVideoMuted, let localCameraTrack = model.localCameraTrack {
        LocalVideoSurface(track: localCameraTrack)
      } else {
        Color(white: 0.14)
        Image(systemName: "video.slash.fill")
          .foregroundStyle(.white.opacity(0.6))
      }
    }
    .frame(height: 100)
    .clipShape(.rect(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12))
    }
    .overlay(alignment: .bottomLeading) {
      HStack(spacing: 5) {
        if controller.isAudioMuted {
          Image(systemName: "mic.slash.fill")
            .font(.caption2)
            .foregroundStyle(.red)
        }
        Text("You")
          .font(.caption)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.black.opacity(0.55), in: .capsule)
      .padding(6)
    }
    .accessibilityLabel("Your camera")
  }

  private func tileView(
    for tile: NativeMeetingModel.MeetingTile,
    flat: Bool = false
  ) -> some View {
    let participant = tile.endpointID.flatMap { id in
      model.participants.first { $0.id == id }
    }
    return MeetingTileView(
      tile: tile,
      isDominantSpeaker: tile.endpointID != nil
        && tile.endpointID == model.dominantSpeakerID,
      isPinned: tile.id == model.pinnedTileID,
      flat: flat,
      stat: tile.stream.flatMap { model.streamStats[$0.id] },
      reaction: tile.endpointID.flatMap { model.tileReactions[$0]?.emoji }
    )
    .onTapGesture {
      model.pinnedTileID = model.pinnedTileID == tile.id ? nil : tile.id
    }
    .contextMenu {
      if model.pinnedTileID == tile.id {
        Button("Unpin") { model.pinnedTileID = nil }
      } else {
        Button("Pin to stage") { model.pinnedTileID = tile.id }
      }
      if model.isModerator, let participant {
        if !participant.audioMuted {
          Button("Mute microphone") { controller.muteParticipant(participant.id) }
        }
        if controller.audioModerationOn {
          Button("Allow to speak") { controller.allowToSpeak(participant.id) }
        }
        if controller.breakoutRooms.count > 1 {
          Menu("Send to") {
            ForEach(controller.breakoutRooms) { room in
              Button(room.name) {
                controller.sendParticipantToBreakoutRoom(participant.id, roomJID: room.id)
              }
            }
          }
        }
        if !participant.isModerator, participant.realJID != nil {
          Button("Make moderator") { controller.grantModerator(participant.id) }
        }
        Button("Remove from meeting", role: .destructive) {
          controller.kickParticipant(participant.id)
        }
      }
    }
  }

  private static func columnCount(for tiles: Int) -> Int {
    switch tiles {
    case ...1: 1
    case ...4: 2
    case ...9: 3
    default: 4
    }
  }

  /// The tile the stage features: the pinned tile, else a screen share, else
  /// the dominant speaker, else the first.
  private static func featuredTile(
    in tiles: [NativeMeetingModel.MeetingTile],
    pinned: String?,
    dominantSpeakerID: String?
  ) -> NativeMeetingModel.MeetingTile {
    tiles.first { $0.id == pinned }
      ?? tiles.first { $0.stream?.videoType == "desktop" }
      ?? tiles.first { $0.endpointID != nil && $0.endpointID == dominantSpeakerID }
      ?? tiles[0]
  }
}

#if os(macOS)
  /// The floating sidebar's ground: a dark translucent material that lets the
  /// stage video read through it, independent of the system appearance.
  private struct SidebarBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
      let view = NSVisualEffectView()
      view.material = .hudWindow
      view.blendingMode = .withinWindow
      view.state = .active
      view.appearance = NSAppearance(named: .vibrantDark)
      return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
  }

  /// The invisible grab strip on the sidebar's trailing edge; dragging it
  /// resizes the panel between sensible bounds.
  private struct SidebarResizeHandle: View {
    @Binding var width: Double

    @State private var widthAtDragStart: Double?

    var body: some View {
      Color.clear
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { inside in
          if inside {
            NSCursor.resizeLeftRight.push()
          } else {
            NSCursor.pop()
          }
        }
        .gesture(
          DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
              let base = widthAtDragStart ?? width
              widthAtDragStart = base
              width = min(420, max(180, base + value.translation.width))
            }
            .onEnded { _ in widthAtDragStart = nil }
        )
    }
  }

  /// A participant's name line in the sidebar, with their live state beside
  /// it: a speaking indicator while they are the dominant speaker, a raised
  /// hand, and their microphone state.
  private struct RosterHeader: View {
    let name: String
    let audioMuted: Bool
    let handRaised: Bool
    let isSpeaking: Bool

    var body: some View {
      HStack(spacing: 6) {
        Text(name)
          .font(.body.bold())
          .foregroundStyle(.white)
          .lineLimit(1)
          .truncationMode(.tail)
        if isSpeaking {
          Image(systemName: "speaker.wave.2.fill")
            .foregroundStyle(Color.accentColor)
        }
        Spacer(minLength: 4)
        if handRaised {
          Image(systemName: "hand.raised.fill")
            .foregroundStyle(.yellow)
        }
        if audioMuted {
          Image(systemName: "mic.slash.fill")
            .foregroundStyle(.red)
        }
      }
      .font(.subheadline)
    }
  }

  /// One feed's thumbnail row under its owner's name.
  private struct SidebarThumbnail<Surface: View>: View {
    let isPinned: Bool
    let videoType: String?
    var handRaised = false
    var reaction: String?
    @ViewBuilder var surface: Surface

    var body: some View {
      surface
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .clipShape(.rect(cornerRadius: 7))
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(
              isPinned ? Color.accentColor : .white.opacity(0.1),
              lineWidth: isPinned ? 2 : 1
            )
        }
        .overlay(alignment: .bottomTrailing) {
          // Deliberately large for the thumbnail's 92-point height, so the
          // state reads at sidebar size.
          TileBadges(handRaised: handRaised, reaction: reaction, size: 30)
        }
        .overlay(alignment: .topTrailing) {
          HStack(spacing: 4) {
            if videoType == "desktop" {
              Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.caption2)
            }
            if isPinned {
              Image(systemName: "pin.fill")
                .font(.caption2)
            }
          }
          .padding(4)
          .background(
            videoType == "desktop" || isPinned
              ? AnyShapeStyle(.black.opacity(0.55)) : AnyShapeStyle(.clear),
            in: .capsule
          )
          .foregroundStyle(.white)
          .padding(5)
        }
        .padding(.vertical, 2)
    }
  }
#endif

/// The in-meeting group chat, in the zephyr style: an avatar and a bold
/// sender name head each run of consecutive messages from one person, with
/// the messages stacked beneath.
private struct ChatPanel: View {
  let messages: [ChatMessage]
  let send: (String) -> Void

  @State private var draft = ""
  @FocusState private var inputFocused: Bool

  private struct MessageGroup: Identifiable {
    let id: String
    let senderID: String
    let senderName: String
    let isLocal: Bool
    var messages: [ChatMessage]
  }

  private var groups: [MessageGroup] {
    var result: [MessageGroup] = []
    for message in messages {
      if var last = result.last, last.senderID == message.senderEndpointID,
        last.isLocal == message.isLocal
      {
        last.messages.append(message)
        result[result.count - 1] = last
      } else {
        result.append(
          MessageGroup(
            id: message.id,
            senderID: message.senderEndpointID,
            senderName: message.isLocal ? "You" : message.senderDisplayName,
            isLocal: message.isLocal,
            messages: [message]
          )
        )
      }
    }
    return result
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
              HStack(alignment: .top, spacing: 9) {
                ChatAvatar(name: group.senderName, seed: group.senderID, isLocal: group.isLocal)
                VStack(alignment: .leading, spacing: 3) {
                  Text(group.senderName)
                    .font(.callout.bold())
                  ForEach(group.messages) { message in
                    Text(message.text)
                      .font(.callout)
                      .textSelection(.enabled)
                      .id(message.id)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(12)
        }
        .onChange(of: messages.count) { _, _ in
          if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }

      Divider()

      HStack(spacing: 8) {
        TextField("Message everyone", text: $draft)
          .textFieldStyle(.plain)
          .focused($inputFocused)
          .onSubmit(submit)
        Button(action: submit) {
          Image(systemName: "paperplane.fill")
        }
        .buttonStyle(.plain)
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(10)
    }
    .background(.regularMaterial, in: .rect(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12))
    }
    .onAppear {
      // Opening the panel means typing; focus lands without a click. The
      // retry covers macOS applying focus only once the window is key.
      inputFocused = true
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(200))
        if !inputFocused { inputFocused = true }
      }
    }
  }

  private func submit() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    send(text)
    draft = ""
  }
}

/// Initials on a hue derived from the sender, so each person keeps a stable
/// avatar color.
private struct ChatAvatar: View {
  let name: String
  let seed: String
  let isLocal: Bool

  var body: some View {
    Text(initials)
      .font(.caption.bold())
      .foregroundStyle(.white)
      .frame(width: 30, height: 30)
      .background(color, in: .circle)
  }

  private var initials: String {
    let words = name.split(separator: " ")
    let letters = words.prefix(2).compactMap(\.first)
    return letters.isEmpty ? "?" : String(letters).uppercased()
  }

  private var color: Color {
    if isLocal { return .accentColor }
    let hue = Double(abs(seed.hashValue % 360)) / 360
    return Color(hue: hue, saturation: 0.55, brightness: 0.72)
  }
}

/// One participant's spot in the grid: their video when it flows, their name
/// and state either way.
/// The raised hand and the sender's latest reaction, anchored to a tile's
/// lower-right corner. `size` scales the whole cluster, so small sidebar
/// thumbnails can show it proportionally larger than the stage does.
struct TileBadges: View {
  let handRaised: Bool
  let reaction: String?
  var size: CGFloat = 24

  var body: some View {
    HStack(spacing: size * 0.2) {
      if handRaised {
        Image(systemName: "hand.raised.fill")
          .font(.system(size: size * 0.66))
          .foregroundStyle(.yellow)
          .padding(size * 0.2)
          .background(.black.opacity(0.55), in: .circle)
      }
      if let reaction {
        Text(reaction)
          .font(.system(size: size))
          .shadow(color: .black.opacity(0.6), radius: 2)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .padding(6)
    .allowsHitTesting(false)
    .animation(.snappy, value: reaction)
    .animation(.snappy, value: handRaised)
  }
}

private struct MeetingTileView: View {
  let tile: NativeMeetingModel.MeetingTile
  let isDominantSpeaker: Bool
  let isPinned: Bool
  /// A stage tile fills the window edge to edge: no rounding, and a border
  /// only while its owner is the dominant speaker.
  var flat = false
  /// Receive health for the tile's stream, shown as a colored dot.
  var stat: InboundVideoStatistic?
  /// The owner's latest reaction, shown next to their raised hand.
  var reaction: String?

  var body: some View {
    ZStack {
      if let stream = tile.stream {
        NativeVideoSurface(track: stream.track)
      } else {
        Color(white: 0.14)
        Text(initials)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.white.opacity(0.85))
          .frame(width: 76, height: 76)
          .background(.white.opacity(0.12), in: .circle)
      }
    }
    .clipShape(.rect(cornerRadius: flat ? 0 : 10))
    .overlay {
      RoundedRectangle(cornerRadius: flat ? 0 : 10)
        .strokeBorder(
          isDominantSpeaker ? Color.accentColor : .white.opacity(flat ? 0 : 0.12),
          lineWidth: isDominantSpeaker ? 2.5 : (flat ? 0 : 1)
        )
    }
    .overlay(alignment: .topLeading) {
      if isPinned {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.white)
          .padding(6)
          .background(.black.opacity(0.55), in: .capsule)
          .padding(8)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      TileBadges(
        handRaised: tile.handRaised,
        reaction: reaction,
        size: flat ? 34 : 24
      )
    }
    .overlay(alignment: .bottomLeading) {
      HStack(spacing: 5) {
        if tile.audioMuted {
          Image(systemName: "mic.slash.fill")
            .font(.caption2)
            .foregroundStyle(.red)
        }
        Text(tile.displayName)
          .font(.caption)
          .lineLimit(1)
        if tile.stream?.videoType == "desktop" {
          Image(systemName: "rectangle.inset.filled.and.person.filled")
            .font(.caption2)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.black.opacity(0.55), in: .capsule)
      .padding(8)
    }
    .overlay(alignment: .topTrailing) {
      if tile.stream != nil {
        Circle()
          .fill(qualityColor)
          .frame(width: 8, height: 8)
          .padding(10)
          .help(qualityDescription)
          .accessibilityLabel("Connection \(qualityDescription)")
      }
    }
    .accessibilityLabel(Text(tile.displayName))
  }

  /// Green for smooth video, orange when frames are limping in, red for a
  /// stalled stream, gray before the first statistics arrive.
  private var qualityColor: Color {
    guard let stat, stat.frameHeight > 0 else { return .gray.opacity(0.6) }
    if stat.framesPerSecond >= 15 { return .green }
    if stat.framesPerSecond >= 5 { return .orange }
    return .red
  }

  private var qualityDescription: String {
    guard let stat, stat.frameHeight > 0 else { return "no data yet" }
    return "\(stat.frameHeight)p @ \(Int(stat.framesPerSecond.rounded())) fps"
  }

  private var initials: String {
    let words = tile.displayName.split(separator: " ")
    let letters = words.prefix(2).compactMap(\.first)
    return letters.isEmpty ? "?" : String(letters).uppercased()
  }
}

@MainActor
final class NativeMeetingModel: ObservableObject {
  /// One grid spot: a participant (with or without flowing video) or a video
  /// source that has not been attributed to a participant yet.
  struct MeetingTile: Identifiable {
    let id: String
    let displayName: String
    let stream: RemoteVideoStream?
    let audioMuted: Bool
    let handRaised: Bool
    let endpointID: String?
  }

  @Published private(set) var streams: [RemoteVideoStream] = []
  /// Receive health per stream (keyed by track id), refreshed every few
  /// seconds for the tiles' connection indicators.
  @Published private(set) var streamStats: [String: InboundVideoStatistic] = [:]
  @Published private(set) var participants: [RemoteParticipant] = []
  @Published private(set) var dominantSpeakerID: String?
  @Published private(set) var isModerator = false
  @Published private(set) var chatMessages: [ChatMessage] = []
  @Published var pinnedTileID: String?
  /// The most recent reaction per participant (keyed by endpoint id, "self"
  /// for our own), shown on that participant's tiles for a few seconds.
  @Published private(set) var tileReactions: [String: TileReaction] = [:]
  @Published var sidebarCollapsed = false
  @Published private(set) var localCameraTrack: LocalVideoTrack?
  /// The outgoing screen-share track, previewed in the sidebar while sharing.
  /// It renders straight from the capture pipeline, so a black preview means
  /// capture is broken while a good preview clears everything up to the
  /// encoder.
  @Published private(set) var localScreenTrack: LocalVideoTrack?
  /// System Picture in Picture, fed by whatever the stage features.
  let pictureInPicture = PictureInPictureManager()

  /// What the PiP window should show: the pinned tile's stream, else a
  /// screen share, else the dominant speaker's, else any stream at all.
  var featuredRemoteStream: RemoteVideoStream? {
    let tiles = self.tiles
    guard !tiles.isEmpty else { return nil }
    let featured =
      tiles.first { $0.id == pinnedTileID }
      ?? tiles.first { $0.stream?.videoType == "desktop" }
      ?? tiles.first { $0.endpointID != nil && $0.endpointID == dominantSpeakerID }
      ?? tiles[0]
    return featured.stream ?? tiles.compactMap(\.stream).first
  }

  /// A reaction shown on a participant's tiles; the token distinguishes a
  /// repeat of the same emoji so its expiry timer restarts.
  struct TileReaction: Equatable {
    let token: UUID
    let emoji: String
  }

  /// The shared jitsi-meet reaction vocabulary and its emoji.
  static let reactionEmoji: [(name: String, emoji: String)] = [
    ("like", "👍"), ("clap", "👏"), ("laugh", "😀"), ("surprised", "😮"),
    ("boo", "🙁"), ("silence", "😶"), ("love", "💖"),
  ]
  #if os(iOS)
    @Published var showsBroadcastPicker = false
  #endif

  /// One sidebar section: a participant and whatever they're sending. A
  /// stream whose owner is not (yet) known from presence gets its own entry.
  struct RosterEntry: Identifiable {
    let id: String
    let displayName: String
    let audioMuted: Bool
    let handRaised: Bool
    let endpointID: String?
    let streams: [RemoteVideoStream]
  }

  /// The participant roster in join order, each with their feeds.
  var roster: [RosterEntry] {
    var placedStreamIDs: Set<String> = []
    var entries = participants.map { participant -> RosterEntry in
      let owned = streams.filter { $0.endpointID == participant.id }
      owned.forEach { placedStreamIDs.insert($0.id) }
      return RosterEntry(
        id: participant.id,
        displayName: participant.displayName,
        audioMuted: participant.audioMuted,
        handRaised: participant.handRaised,
        endpointID: participant.id,
        streams: owned
      )
    }
    for stream in streams where !placedStreamIDs.contains(stream.id) {
      entries.append(
        RosterEntry(
          id: "stream-\(stream.id)",
          displayName: stream.sourceName ?? stream.endpointID ?? "Participant",
          audioMuted: false,
          handRaised: false,
          endpointID: stream.endpointID,
          streams: [stream]
        )
      )
    }
    return entries
  }

  /// The grid contents: every participant in join order — with a tile per
  /// video source for someone sending both camera and screen share — plus any
  /// stream whose owner is not (yet) known from presence.
  var tiles: [MeetingTile] {
    var result: [MeetingTile] = []
    var placedStreamIDs: Set<String> = []
    for participant in participants {
      let owned = streams.filter { $0.endpointID == participant.id }
      if owned.isEmpty {
        result.append(
          MeetingTile(
            id: participant.id,
            displayName: participant.displayName,
            stream: nil,
            audioMuted: participant.audioMuted,
            handRaised: participant.handRaised,
            endpointID: participant.id
          )
        )
      } else {
        for stream in owned {
          placedStreamIDs.insert(stream.id)
          result.append(
            MeetingTile(
              id: stream.id,
              displayName: participant.displayName,
              stream: stream,
              audioMuted: participant.audioMuted,
              handRaised: participant.handRaised,
              endpointID: participant.id
            )
          )
        }
      }
    }
    for stream in streams where !placedStreamIDs.contains(stream.id) {
      result.append(
        MeetingTile(
          id: stream.id,
          displayName: stream.sourceName ?? stream.endpointID ?? "Participant",
          stream: stream,
          audioMuted: false,
          handRaised: false,
          endpointID: stream.endpointID
        )
      )
    }
    return result
  }

  private var handle: NativeConferenceHandle?
  private var configuration: MeetingConfiguration?
  private var joinTask: Task<Void, Never>?
  private var eventTask: Task<Void, Never>?
  private var statsTask: Task<Void, Never>?
  #if os(macOS)
    private var screenCapture: MacScreenShareController?
  #elseif os(iOS)
    private var screenReceiver: ReplayKitFrameReceiver?
  #endif

  func join(configuration: MeetingConfiguration, controller: MeetingController) async {
    guard joinTask == nil, handle == nil else { return }
    self.configuration = configuration
    MeetingHub.shared.registerModel(self)
    controller.didSetMeetingLink(configuration.meetingLink)
    controller.attach { [weak self, weak controller] command in
      guard let self, let controller else { return }
      Task { @MainActor in await self.execute(command, controller: controller) }
    }
    await startJoin(configuration: configuration, controller: controller)
  }

  /// One tick of the speaker-stats panel: a fresh snapshot from the
  /// coordinator, with the self row renamed.
  func refreshSpeakerStats(controller: MeetingController) async {
    guard let handle else { return }
    let selfID = handle.occupantJID.split(separator: "/").last.map(String.init) ?? ""
    let stats = await handle.coordinator.currentSpeakerStats()
    controller.didChangeSpeakerStats(
      stats.map { stat in
        MeetingController.SpeakerStatDisplay(
          id: stat.id,
          name: stat.id == selfID
            ? "You" : stat.displayName.isEmpty ? stat.id : stat.displayName,
          seconds: stat.totalSpeakingTime,
          isSpeaking: stat.isSpeaking,
          hasLeft: stat.hasLeft
        )
      }
    )
  }

  /// Moves this client to another room in the same deployment — a breakout
  /// room, or back to the main one — by tearing the conference down and
  /// rejoining under the new address.
  func switchRoom(to roomJID: String, controller: MeetingController) async {
    guard let configuration else { return }
    SangamLog.event("breakout: switching to \(roomJID)")
    joinTask?.cancel()
    joinTask = nil
    eventTask?.cancel()
    eventTask = nil
    statsTask?.cancel()
    statsTask = nil
    stopScreenCapture()
    controller.didChangeScreenSharing(false)
    if let handle {
      await handle.coordinator.stop()
      self.handle = nil
    }
    streams = []
    streamStats = [:]
    participants = []
    dominantSpeakerID = nil
    pinnedTileID = nil
    isModerator = false
    controller.didStartSwitchingRooms()
    await startJoin(configuration: configuration, controller: controller, roomOverride: roomJID)
  }

  private func startJoin(
    configuration: MeetingConfiguration,
    controller: MeetingController,
    username: String? = nil,
    password: String? = nil,
    waitForHost: Bool = false,
    roomOverride: String? = nil,
    meetingPassword: String? = nil
  ) async {
    guard joinTask == nil, handle == nil else { return }
    SangamLog.event(
      "join begin room=\(roomOverride ?? configuration.normalizedRoom) "
        + "server=\(configuration.serverURL.absoluteString) "
        + "waitForHost=\(waitForHost) authenticated=\(username != nil)")
    let task = Task { @MainActor [weak self, weak controller] in
      guard let self, let controller else { return }
      do {
        let handle = try await NativeConferenceBootstrap().connect(
          NativeConferenceJoinOptions(
            serverURL: configuration.serverURL,
            room: roomOverride ?? configuration.normalizedRoom,
            displayName: configuration.displayName,
            username: username,
            password: password,
            waitForHost: waitForHost,
            startCamera: true,
            meetingPassword: meetingPassword
          ),
          progress: { [weak controller] progress in
            Task { @MainActor in
              switch progress {
              case .waitingInLobby(let waitingForHost):
                SangamLog.event("join progress: waitingInLobby waitForHost=\(waitingForHost)")
                controller?.didEnterLobby(waitingForHost: waitingForHost)
              case .stage(let stage):
                SangamLog.event("join stage: \(stage.rawValue)")
              }
            }
          }
        )
        SangamLog.event(
          "join: entered MUC as \(handle.occupantJID); focus ready=\(handle.focus.ready)")
        self.handle = handle
        self.localCameraTrack = handle.coordinator.cameraVideoTrack
        self.localScreenTrack = handle.coordinator.screenVideoTrack
        self.observe(handle: handle, controller: controller)
        self.startStatsLogging(handle: handle)
        // MUC membership is the user-visible definition of "joined". Jicofo's
        // default min-participants is two, so a lone participant will not
        // receive a Jingle media offer yet.
        controller.didJoin()
      } catch NativeConferenceBootstrapError.authenticationRequired {
        if waitForHost || username != nil {
          // A waiting join or a credentialed join should not bounce here;
          // fall back to the sign-in card rather than looping.
          SangamLog.event("join: authenticationRequired after credentials/wait")
          controller.requireAccess()
        } else {
          // No host yet: wait for one by default. Signing in as a host is
          // the waiting card's expandable secondary path.
          SangamLog.event("join: authenticationRequired — waiting for a host")
          controller.didEnterLobby(waitingForHost: true)
          self.joinTask = nil
          await self.startJoin(
            configuration: configuration, controller: controller, waitForHost: true)
        }
      } catch NativeConferenceBootstrapError.invalidCredentials {
        SangamLog.event("join: invalidCredentials")
        controller.requireAccess(message: "That username or password wasn’t accepted.")
      } catch NativeConferenceBootstrapError.passwordRequired {
        SangamLog.event("join: passwordRequired")
        controller.requireMeetingPassword()
      } catch is CancellationError {
        SangamLog.event("join: cancelled")
        return
      } catch {
        SangamLog.event("join: failed \(error)")
        controller.didFailToJoin(error: error.localizedDescription)
      }
      self.joinTask = nil
    }
    joinTask = task
    await task.value
  }

  func leave(controller: MeetingController) {
    MeetingHub.shared.unregisterModel(self)
    controller.detach()
    joinTask?.cancel()
    joinTask = nil
    eventTask?.cancel()
    eventTask = nil
    statsTask?.cancel()
    statsTask = nil
    streams = []
    participants = []
    dominantSpeakerID = nil
    isModerator = false
    chatMessages = []
    pinnedTileID = nil
    localCameraTrack = nil
    localScreenTrack = nil
    configuration = nil
    stopScreenCapture()
    if let handle {
      Task { await handle.coordinator.stop() }
      self.handle = nil
    }
  }

  /// Refreshes the tiles' connection indicators every few seconds, and logs
  /// the full RTP flow while `SANGAM_LOG` is set.
  private func startStatsLogging(handle: NativeConferenceHandle) {
    statsTask?.cancel()
    statsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let self, let handle = self.handle else { return }
        let stats = await handle.coordinator.inboundVideoStatistics()
        streamStats = Dictionary(uniqueKeysWithValues: stats.map { ($0.trackID, $0) })
        if SangamLog.isEnabled {
          let summary = await handle.coordinator.mediaStatsSummary()
          SangamLog.event("stats: \(summary)")
        }
      }
    }
  }

  private func observe(handle: NativeConferenceHandle, controller: MeetingController) {
    eventTask?.cancel()
    eventTask = Task { @MainActor [weak self, weak controller] in
      for await event in handle.coordinator.events {
        guard let self, let controller else { return }
        switch event {
        case .negotiating(let sessionID):
          SangamLog.event("event: negotiating session=\(sessionID)")
        case .connected(let sessionID):
          SangamLog.event("event: connected session=\(sessionID)")
          controller.didJoin()
        case .peerConnectionState(let state):
          SangamLog.event("event: peerConnectionState=\(state.rawValue)")
          if state == .failed {
            controller.report(error: "The native media connection failed.")
          }
        case .remoteVideoTrackAdded(let stream):
          SangamLog.event(
            "event: remoteVideoTrackAdded id=\(stream.id) source=\(stream.sourceName ?? "?") "
              + "owner=\(stream.endpointID ?? "?") placeholder=\(stream.isBridgePlaceholder)")
          // The bridge's mixed placeholder source never carries real video and
          // is not a participant.
          guard !stream.isBridgePlaceholder else { break }
          streams.removeAll { $0.id == stream.id }
          streams.append(stream)
        case .remoteVideoTrackRemoved(let id):
          streams.removeAll { $0.id == id }
          SangamLog.event(
            "event: remoteVideoTrackRemoved id=\(id) (remote video sources: \(streams.count))")
        case .remoteSessionEnded(let reason):
          SangamLog.event("event: remoteSessionEnded reason=\(reason ?? "nil")")
          // Like the web client, a Jingle session ending does not end the
          // conference: Jicofo tears the media session down whenever this
          // client is the only participant left and re-invites when someone
          // joins. Stay in the room; only surface unexpected reasons.
          streams = []
          dominantSpeakerID = nil
          let cleanReasons: Set<String> = ["gone", "success", "expired"]
          if let reason, !cleanReasons.contains(reason) {
            controller.report(error: "The media session ended (\(reason)).")
          }
        case .screenSharingChanged(let sharing):
          SangamLog.event("event: screenSharingChanged=\(sharing)")
          controller.didChangeScreenSharing(sharing)
        case .unsupportedAction(let action):
          SangamLog.event("event: unsupportedAction=\(action.rawValue)")
          controller.report(error: "Native Jitsi does not yet support \(action.rawValue).")
        case .warning(let message):
          SangamLog.event("event: warning \(message)")
          controller.report(error: message)
        case .diagnostic(let message):
          SangamLog.event("diag: \(message)")
        case .failed(let message):
          SangamLog.event("event: failed \(message)")
          controller.didEnd(error: message)
        case .participantsChanged(let updated):
          SangamLog.event(
            "event: participantsChanged count=\(updated.count) "
              + "[\(updated.map(\.id).joined(separator: ", "))]")
          let previous = Set(participants.map(\.id))
          let current = Set(updated.map(\.id))
          // No sound for the roster that was already there when we joined.
          if !previous.isEmpty, !current.subtracting(previous).isEmpty {
            MeetingSounds.participantJoined()
          }
          if !previous.subtracting(current).isEmpty {
            MeetingSounds.participantLeft()
          }
          participants = updated
        case .dominantSpeakerChanged(let endpointID):
          dominantSpeakerID = endpointID
        case .moderatorStatusChanged(let moderator):
          SangamLog.event("event: moderatorStatusChanged=\(moderator)")
          isModerator = moderator
          controller.didChangeModeratorStatus(moderator)
        case .avModerationChanged(let media, let enabled, _):
          SangamLog.event("event: avModeration \(media) enabled=\(enabled)")
          if media == "audio" {
            controller.didChangeAudioModeration(enabled)
          }
        case .avModerationApprovalChanged(let media, let approved):
          SangamLog.event("event: avModerationApproval \(media)=\(approved)")
          if approved {
            controller.report(
              error: media == "audio"
                ? "A moderator has allowed you to unmute."
                : "A moderator has allowed you to turn your camera on.")
          }
        case .unmuteBlocked(let media):
          SangamLog.event("event: unmuteBlocked media=\(media)")
          if media == "audio" {
            controller.didChangeAudioMuted(true)
            controller.report(
              error: "Moderation is on — raise your hand and a moderator can allow you to speak."
            )
          } else {
            controller.didChangeVideoMuted(true)
            controller.report(
              error: "Moderation is on — a moderator must allow you to turn your camera on.")
          }
        case .chatMessageReceived(let message):
          chatMessages.append(message)
          if chatMessages.count > 500 { chatMessages.removeFirst(chatMessages.count - 500) }
          if !message.isLocal {
            controller.noteUnreadChatMessage()
            MeetingNotifications.post(
              title: message.senderDisplayName,
              body: message.text,
              id: "chat-\(message.id)"
            )
          }
        case .reactionsReceived(let endpointID, let reactions):
          SangamLog.event(
            "event: reactions from=\(endpointID ?? "self") [\(reactions.joined(separator: ", "))]")
          MeetingSounds.reaction()
          // The newest reaction owns the sender's tile badge; a token per
          // arrival restarts the expiry so repeats keep it alive.
          let key = endpointID ?? "self"
          let emoji =
            reactions.compactMap({ name in
              Self.reactionEmoji.first { $0.name == name }?.emoji
            }).last ?? "✨"
          let reaction = TileReaction(token: UUID(), emoji: emoji)
          tileReactions[key] = reaction
          Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.tileReactions[key]?.token == reaction.token {
              self?.tileReactions[key] = nil
            }
          }
        case .remoteSourceVideoTypeChanged(let sourceName, let videoType):
          SangamLog.event("event: sourceVideoType \(sourceName) -> \(videoType)")
          streams = streams.map { stream in
            guard stream.sourceName == sourceName else { return stream }
            var updated = stream
            updated.videoType = videoType
            return updated
          }
        case .mutedByModerator(let media):
          SangamLog.event("event: mutedByModerator media=\(media)")
          if media == "audio" {
            controller.didChangeAudioMuted(true)
            controller.report(error: "A moderator muted your microphone.")
          } else {
            controller.didChangeVideoMuted(true)
            controller.report(error: "A moderator turned off your camera.")
          }
        case .camerasChanged(let available, let currentDeviceID):
          SangamLog.event(
            "event: camerasChanged count=\(available.count)"
              + " current=\(currentDeviceID ?? "none")")
          controller.didChangeCameras(
            available.map { MeetingController.CameraOption(id: $0.id, name: $0.name) },
            currentID: currentDeviceID
          )
        case .breakoutRoomsUpdated(let rooms):
          SangamLog.event("event: breakoutRoomsUpdated count=\(rooms.count)")
          controller.didChangeBreakoutRooms(
            rooms.map {
              MeetingController.BreakoutRoomOption(
                id: $0.id, name: $0.name, isMainRoom: $0.isMainRoom,
                participantCount: $0.participantCount)
            }
          )
        case .movedToBreakoutRoom(let roomJID):
          SangamLog.event("event: movedToBreakoutRoom \(roomJID)")
          // A moderator sent us to another room. Switching cancels this
          // event loop, so it must run outside it.
          Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            await self.switchRoom(to: roomJID, controller: controller)
          }
        case .roomPasswordProtectedChanged(let protected):
          SangamLog.event("event: roomPasswordProtected=\(protected)")
          controller.didChangeRoomPasswordProtected(protected)
        case .pollsUpdated(let polls):
          SangamLog.event("event: pollsUpdated count=\(polls.count)")
          let selfID = handle.occupantJID.split(separator: "/").last.map(String.init) ?? ""
          controller.didChangePolls(
            polls.map { poll in
              MeetingController.PollDisplay(
                id: poll.id,
                question: poll.question,
                senderName: poll.senderID == selfID
                  ? "You"
                  : self.participants.first { $0.id == poll.senderID }?.displayName
                    ?? poll.senderID,
                answers: poll.answers.enumerated().map { index, answer in
                  MeetingController.PollDisplay.Answer(
                    id: index,
                    name: answer.name,
                    votes: answer.voterIDs.count,
                    mine: answer.voterIDs.contains(selfID)
                  )
                }
              )
            }
          )
        case .lobbyEnabledChanged(let enabled):
          SangamLog.event("event: lobbyEnabledChanged=\(enabled)")
          controller.didChangeLobbyEnabled(enabled)
        case .lobbyKnockersChanged(let knockers):
          SangamLog.event("event: lobbyKnockersChanged count=\(knockers.count)")
          let known = Set(controller.lobbyRequests.map(\.id))
          for knocker in knockers where !known.contains(knocker.id) {
            MeetingNotifications.post(
              title: "Waiting to join",
              body: "\(knocker.displayName) is asking to join the meeting.",
              id: "knock-\(knocker.id)"
            )
          }
          controller.didChangeLobbyRequests(
            knockers.map { MeetingController.LobbyRequest(id: $0.id, displayName: $0.displayName) }
          )
        }
      }
    }
  }

  private func execute(_ command: MeetingController.Command, controller: MeetingController) async {
    switch command {
    case .authenticate(let username, let password):
      guard let configuration else { return }
      // Signing in from the lobby abandons the anonymous knock still in
      // flight; its cancellation tears down what that join opened.
      joinTask?.cancel()
      joinTask = nil
      await startJoin(
        configuration: configuration,
        controller: controller,
        username: username,
        password: password
      )
      return
    case .waitForHost:
      guard let configuration else { return }
      await startJoin(
        configuration: configuration,
        controller: controller,
        waitForHost: true
      )
      return
    case .cancelWaiting:
      joinTask?.cancel()
      joinTask = nil
      return
    default:
      break
    }
    guard let coordinator = handle?.coordinator else {
      if case .hangUp = command { controller.didEnd() }
      return
    }
    switch command {
    case .setAudioMuted(let muted):
      await coordinator.setMicrophoneMuted(muted)
    case .setVideoMuted(let muted):
      await coordinator.setCameraEnabled(!muted)
    case .setHandRaised(let raised):
      await coordinator.setHandRaised(raised)
    case .sendChatMessage(let text):
      do {
        try await coordinator.sendChatMessage(text)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .sendReaction(let name):
      await coordinator.sendReaction(name)
    case .kickParticipant(let id):
      do {
        try await coordinator.kickParticipant(id: id)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .grantModerator(let id):
      do {
        try await coordinator.grantModerator(id: id)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .muteParticipant(let id):
      do {
        try await coordinator.muteParticipant(id: id)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .setReceiveQuality(let maxHeight):
      await coordinator.setPreferredReceiveMaxHeight(maxHeight)
    case .setAudioModeration(let enabled):
      do {
        try await coordinator.setAVModeration(enabled: enabled)
      } catch {
        controller.didChangeAudioModeration(!enabled)
        controller.report(error: error.localizedDescription)
      }
    case .allowToSpeak(let id):
      do {
        try await coordinator.approveUnmute(id: id)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .setBackgroundBlur(let enabled):
      await coordinator.setVirtualBackground(enabled ? .blur : .none)
    case .createBreakoutRoom(let subject):
      do {
        try await coordinator.createBreakoutRoom(subject: subject)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .removeBreakoutRoom(let jid):
      do {
        try await coordinator.removeBreakoutRoom(jid: jid)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .joinBreakoutRoom(let jid):
      await switchRoom(to: jid, controller: controller)
    case .sendParticipantToBreakoutRoom(let id, let roomJID):
      do {
        try await coordinator.sendParticipantToBreakoutRoom(id: id, roomJID: roomJID)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .joinWithMeetingPassword(let password):
      guard let configuration else { return }
      joinTask?.cancel()
      joinTask = nil
      await startJoin(
        configuration: configuration, controller: controller, meetingPassword: password)
    case .setLobbyEnabled(let enabled):
      do {
        try await coordinator.setLobbyEnabled(enabled)
      } catch {
        controller.didChangeLobbyEnabled(!enabled)
        controller.report(error: error.localizedDescription)
      }
    case .setRoomPassword(let password):
      do {
        try await coordinator.setRoomPassword(password)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .createPoll(let question, let answers):
      do {
        try await coordinator.createPoll(question: question, answers: answers)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .answerPoll(let id, let votes):
      do {
        try await coordinator.answerPoll(id: id, votes: votes)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .togglePictureInPicture:
      pictureInPicture.onActiveChanged = { [weak controller, weak self] active in
        guard let self, let controller else { return }
        controller.didChangePictureInPicture(
          available: self.pictureInPicture.isSupported, active: active)
        if !active { self.pictureInPicture.bridge.detach() }
      }
      pictureInPicture.onError = { [weak controller] message in
        controller?.report(error: message)
      }
      pictureInPicture.toggle(remote: featuredRemoteStream, localFallback: localCameraTrack)
    case .setScreenSharing(let enabled):
      if enabled {
        startScreenCapture(coordinator: coordinator, controller: controller)
      } else {
        stopScreenCapture()
        await coordinator.stopScreen()
        controller.didChangeScreenSharing(false)
      }
    case .switchCamera(let deviceID):
      do {
        try await coordinator.switchCamera(toDeviceID: deviceID)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .admitLobbyParticipant(let id):
      do {
        try await coordinator.admitLobbyParticipant(id: id)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .denyLobbyParticipant(let id):
      do {
        try await coordinator.denyLobbyParticipant(id: id)
      } catch {
        controller.report(error: error.localizedDescription)
      }
    case .authenticate, .waitForHost, .cancelWaiting:
      break
    case .hangUp:
      await coordinator.stop()
      handle = nil
      controller.didEnd()
    }
  }

  private func startScreenCapture(
    coordinator: NativeJingleCoordinator,
    controller: MeetingController
  ) {
    #if os(macOS)
      let capture =
        screenCapture ?? MacScreenShareController(videoTrack: coordinator.screenVideoTrack)
      screenCapture = capture
      capture.stateDidChange = { [weak self, weak controller] state in
        guard let self, let controller else { return }
        switch state {
        case .sharing:
          Task { @MainActor in
            do {
              try await coordinator.publishScreen()
            } catch {
              self.stopScreenCapture()
              controller.didChangeScreenSharing(false)
              controller.report(error: error.localizedDescription)
            }
          }
        case .stopped, .idle:
          Task { await coordinator.stopScreen() }
          controller.didChangeScreenSharing(false)
        case .failed(let message):
          Task { await coordinator.stopScreen() }
          controller.didChangeScreenSharing(false)
          controller.report(error: message)
        case .selecting, .starting:
          break
        }
      }
      capture.presentPicker()
    #elseif os(iOS)
      let receiver = screenReceiver ?? ReplayKitFrameReceiver(track: coordinator.screenVideoTrack)
      screenReceiver = receiver
      receiver.stateDidChange = { [weak self, weak controller] state in
        guard let self, let controller else { return }
        switch state {
        case .receiving:
          self.showsBroadcastPicker = false
          Task { @MainActor in
            do {
              try await coordinator.publishScreen()
            } catch {
              self.stopScreenCapture()
              controller.didChangeScreenSharing(false)
              controller.report(error: error.localizedDescription)
            }
          }
        case .stopped:
          Task { await coordinator.stopScreen() }
          controller.didChangeScreenSharing(false)
        case .failed(let message):
          Task { await coordinator.stopScreen() }
          controller.didChangeScreenSharing(false)
          controller.report(error: message)
        case .idle, .listening:
          break
        }
      }
      do {
        try receiver.start()
        showsBroadcastPicker = true
      } catch {
        controller.didChangeScreenSharing(false)
        controller.report(error: error.localizedDescription)
      }
    #endif
  }

  private func stopScreenCapture() {
    #if os(macOS)
      screenCapture?.stop()
      screenCapture = nil
    #elseif os(iOS)
      screenReceiver?.stop()
      screenReceiver = nil
      showsBroadcastPicker = false
    #endif
  }
}

#if os(iOS)
  private struct NativeBroadcastPickerSheet: View {
    var body: some View {
      VStack(spacing: 16) {
        Text("Share This Screen")
          .font(.headline)
        Text("Tap the broadcast button, then choose Start Broadcast.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        NativeBroadcastPicker()
          .frame(width: 56, height: 56)
      }
      .padding(24)
    }
  }

  private struct NativeBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
      let picker = RPSystemBroadcastPickerView(frame: .zero)
      picker.preferredExtension = "com.twarge.sangam.broadcast"
      picker.showsMicrophoneButton = false
      return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
  }

  struct NativeVideoSurface: UIViewRepresentable {
    let track: RemoteVideoTrack?

    func makeUIView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateUIView(_ view: NativeVideoRendererView, context: Context) {
      view.display(track)
    }

    static func dismantleUIView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(nil)
    }
  }

  private struct LocalVideoSurface: UIViewRepresentable {
    let track: LocalVideoTrack?

    func makeUIView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateUIView(_ view: NativeVideoRendererView, context: Context) {
      view.display(local: track)
    }

    static func dismantleUIView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(local: nil)
    }
  }
#elseif os(macOS)
  struct NativeVideoSurface: NSViewRepresentable {
    let track: RemoteVideoTrack?

    func makeNSView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateNSView(_ view: NativeVideoRendererView, context: Context) {
      view.display(track)
    }

    static func dismantleNSView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(nil)
    }
  }

  private struct LocalVideoSurface: NSViewRepresentable {
    let track: LocalVideoTrack?

    func makeNSView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateNSView(_ view: NativeVideoRendererView, context: Context) {
      view.display(local: track)
    }

    static func dismantleNSView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(local: nil)
    }
  }
#endif
