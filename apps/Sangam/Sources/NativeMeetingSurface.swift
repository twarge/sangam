import JitsiConference
import JitsiMedia
import SwiftUI

#if os(iOS)
  import ReplayKit
#endif
#if os(macOS)
  import AppKit
#endif

/// The gap between grid tiles, and the margin around the whole grid.
private let gridSpacing: CGFloat = 4

/// The trailing column chat and the conversation share when the window is
/// wide enough for one. A generic view cannot hold these as statics.
enum MeetingSidePanel {
  static let width: CGFloat = 300
  /// The width plus its inset: what the stage gives up in push mode, and what
  /// the control bar shifts by to stay centered on the stage that is left.
  static let inset: CGFloat = 312
}

struct NativeMeetingSurface<Controls: View>: View {
  let configuration: MeetingConfiguration
  @ObservedObject var controller: MeetingController
  @ObservedObject var conversation: ConversationSession
  @ViewBuilder var controls: Controls

  private enum SidebarSelection: Hashable {
    case meeting
    case stream(String)
  }
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
  #endif

  @StateObject private var model = NativeMeetingModel()
  /// The camera's shape, for the self view shown alone on the stage.
  @State private var selfVideoAspect: CGFloat?
  @Environment(\.openWindow) private var openWindow
  /// The floating sidebar's width, draggable at its trailing edge and
  /// remembered across meetings.
  @AppStorage("sidebarWidth") private var sidebarWidth = 236.0
  /// Whether the sidebar and chat panel push the stage aside instead of
  /// floating over it; the same key AppSettings writes.
  @AppStorage("panelsPushStage") private var panelsPushStage = false
  /// Whether the window is wide enough for chat and the conversation to sit
  /// beside the stage instead of sliding up over it. A phone is not, nor is
  /// an iPad in a narrow split: a 300pt panel would leave the stage a sliver
  /// and put the message field under the keyboard.
  private var usesSidePanels: Bool {
    #if os(iOS)
      horizontalSizeClass == .regular
    #else
      true
    #endif
  }

  private var usesChatSheet: Bool { !usesSidePanels }

  var body: some View {
    Group {
      if controller.connectionState == .joined {
        meetingRootWithSidebar
      } else {
        // The surface stays mounted so the join task below keeps running,
        // but none of the meeting chrome (sidebar, toolbar, stage) shows
        // until actually in the conference.
        Color.clear
      }
    }
    #if os(iOS)
      // The view AVKit animates the floating window out of and back into. It
      // draws nothing — the stage underneath is what is on screen — and the
      // video itself lives in the PiP view controller, not here.
      .overlay {
        PiPSourceHost(manager: model.pictureInPicture)
        .allowsHitTesting(false)
        .onAppear {
          controller.didChangePictureInPicture(
            available: model.pictureInPicture.isSupported,
            active: model.pictureInPicture.isActive
          )
        }
      }
    #else
      .overlay(alignment: .bottomTrailing) {
        // The sample-buffer route needs its content layer in a window; it
        // hides in the corner while the system window does the real
        // rendering.
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
    #endif
    .onChange(of: model.featuredRemoteStream?.id) { _, _ in
      model.pictureInPicture.showRemote(
        model.featuredRemoteStream, localFallback: model.localCameraTrack)
    }
    // Alone in the room the self view is the only thing to float, and it
    // arrives after the join rather than with it.
    .onChange(of: model.localCameraTrack == nil) { _, _ in
      model.pictureInPicture.showRemote(
        model.featuredRemoteStream, localFallback: model.localCameraTrack)
    }
    #if os(iOS)
      .onChange(of: scenePhase) { _, phase in
        // The system floats the meeting on the way out on its own; coming
        // back, the window has nothing left to show that the app isn't.
        if phase == .active {
          model.pictureInPicture.stopIfActive()
        } else {
          // On the way out is when automatic PiP starts, so this is the last
          // chance to make sure the window floats what is featured now.
          model.pictureInPicture.followCurrent()
        }
      }
      // And again on the notification, because the phase does not always
      // change: on an iPad the app can be alongside its own floating window
      // without ever having been backgrounded, so `.active` never arrives as
      // a change and the window outstays the app.
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      ) { _ in
        model.pictureInPicture.stopIfActive()
      }
      // The scene-level one as well: this is a multi-scene app, and on iPad
      // the app-level notification does not necessarily arrive for the scene
      // the user actually came back to.
      .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
        model.pictureInPicture.stopIfActive()
      }
    #endif
    // The stats panel ticks once a second while open, so the current
    // speaker's time counts up live.
    .task(id: controller.showsSpeakerStats) {
      guard controller.showsSpeakerStats else { return }
      while !Task.isCancelled, controller.showsSpeakerStats {
        await model.refreshSpeakerStats(controller: controller)
        try? await Task.sleep(for: .seconds(1))
      }
    }
    // The mute button's meter follows the microphone ten times a second
    // while the call is live and unmuted. Muted, there is nothing to draw
    // and the poll stops with the task.
    .task(id: controller.connectionState == .joined && !controller.isAudioMuted) {
      guard controller.connectionState == .joined, !controller.isAudioMuted else {
        controller.didChangeMicrophoneLevel(0)
        return
      }
      while !Task.isCancelled {
        await model.refreshMicrophoneLevel(controller: controller)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    .task {
      #if DEBUG
        if let preview = MeetingLayoutPreviewMode.current {
          controller.didChangeAudioMuted(true)
          controller.didChangeVideoMuted(true)
          controller.attach { command in
            switch command {
            case .authenticate:
              controller.report(error: "Preview: admin login submitted.")
            case .joinWithMeetingPassword:
              controller.report(error: "Preview: meeting password submitted.")
            case .hangUp:
              controller.didEnd()
            default: break
            }
          }
          switch preview {
          case .access: controller.requireAccess()
          case .password: controller.requireMeetingPassword()
          case .meeting, .chat, .notes, .lobby:
            controller.didJoin()
            model.loadChatPreview()
            controller.isChatOpen = preview == .chat
            conversation.isOpen = preview == .notes
            if preview == .lobby {
              controller.didChangeLobbyRequests([
                .init(id: "guest-1", displayName: "Priya Raman"),
                .init(id: "guest-2", displayName: "Jonas Weber"),
              ])
            }
            // Nothing is captured in a preview, so the mute button's meter
            // gets a voice-shaped level to follow instead.
            controller.didChangeAudioMuted(false)
            Task {
              var phase = 0.0
              while !Task.isCancelled {
                phase += 0.35
                let syllables = 0.55 + 0.45 * sin(phase * 3.1)
                controller.didChangeMicrophoneLevel(max(0, sin(phase)) * syllables)
                try? await Task.sleep(for: .milliseconds(100))
              }
            }
          }
          return
        }
      #endif
      model.conversation = conversation
      conversation.setLocalMuted(controller.isAudioMuted)
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
              // Admit/deny lives in the roster, so a collapsed sidebar
              // would otherwise hide that someone is waiting.
              .overlay(alignment: .topTrailing) {
                if model.sidebarCollapsed, !controller.lobbyRequests.isEmpty {
                  Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .offset(x: 4, y: -4)
                }
              }
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
  #else
    /// SwiftUI supplies the compact back button and interactive edge swipe.
    /// The media model belongs to this container, so navigating back to the
    /// roster never leaves or recreates the call.
    private var meetingRoot: some View {
      NavigationSplitView(
        columnVisibility: $columnVisibility,
        preferredCompactColumn: $preferredCompactColumn
      ) {
        sidebarRoster
          .navigationTitle("Participants")
          .navigationBarTitleDisplayMode(.inline)
          .navigationSplitViewColumnWidth(min: 220, ideal: sidebarWidth, max: 320)
          .safeAreaInset(edge: .bottom, spacing: 0) {
            // In a split iPad layout the controls belong to the wider stage.
            // Keep them reachable while viewing the full-width phone roster.
            if horizontalSizeClass == .compact { controls }
          }
      } detail: {
        detailContent
          .navigationTitle(configuration.normalizedRoom)
          .navigationBarTitleDisplayMode(.inline)
          .safeAreaInset(edge: .bottom, spacing: 0) { controls }
      }
      .navigationSplitViewStyle(.balanced)
    }

  #endif

  /// The meeting beside its trailing sidebar.
  ///
  /// `inspector` is the platform's own trailing column: it supplies the
  /// sidebar material, runs to the window edges without being told about
  /// safe areas, is resizable, and narrows the stage rather than floating
  /// over it. Hand-rolling the same thing out of an HStack and a Divider
  /// got the geometry nearly right and the edges wrong.
  private var meetingRootWithSidebar: some View {
    meetingRoot
      #if os(macOS)
        // Inside the inspector's stage rather than over the whole window, so
        // the control bar stays centered on the video that is left.
        .overlay(alignment: .bottom) {
          if controller.connectionState == .joined { controls }
        }
      #endif
      .inspector(isPresented: inspectorPresented) {
        trailingPanelContent
          .inspectorColumnWidth(min: 280, ideal: MeetingSidePanel.width, max: 460)
      }
  }

  /// The inspector is open when either panel is; dismissing it — by its own
  /// control or by dragging it shut — closes whichever one that was.
  private var inspectorPresented: Binding<Bool> {
    Binding(
      get: { hasTrailingPanel },
      set: { open in
        guard !open else { return }
        controller.isChatOpen = false
        conversation.isOpen = false
      }
    )
  }

  private var sidebarSelection: Binding<SidebarSelection?> {
    Binding(
      get: { model.pinnedTileID.map(SidebarSelection.stream) ?? .meeting },
      set: { selection in
        if case .stream(let id) = selection {
          model.pinnedTileID = id
        } else {
          model.pinnedTileID = nil
        }
      }
    )
  }

  private var sidebarRoster: some View {
    List(selection: sidebarSelection) {
      #if os(iOS)
        // Only when the stage is somewhere else. Side by side with it, this
        // is a link to what the user is already looking at.
        if horizontalSizeClass == .compact {
          Section {
            NavigationLink(value: SidebarSelection.meeting) {
              Label("Meeting", systemImage: "video")
            }
          }
        }
      #endif
      // Hosts see who is knocking at the top of the roster and let them
      // in, or not, one at a time.
      if !controller.lobbyRequests.isEmpty {
        Section {
          ForEach(controller.lobbyRequests) { request in
            LobbyRequestRow(
              displayName: request.displayName,
              admit: { controller.admitLobbyParticipant(request.id) },
              deny: { controller.denyLobbyParticipant(request.id) }
            )
          }
        } header: {
          Label(
            controller.lobbyRequests.count == 1
              ? "Waiting to join" : "Waiting to join (\(controller.lobbyRequests.count))",
            systemImage: "person.crop.circle.badge.clock"
          )
          .font(.subheadline.weight(.semibold))
        }
      }

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
            let thumbnail = SidebarThumbnail(
              isPinned: model.pinnedTileID == stream.id,
              videoType: stream.videoType,
              handRaised: entry.handRaised,
              reaction: entry.endpointID.flatMap { model.tileReactions[$0]?.emoji }
            ) {
              NativeVideoSurface(track: stream.track)
            }
            #if os(macOS)
              thumbnail
                .tag(SidebarSelection.stream(stream.id))
                // A double-click floats the feed in its own window; a single
                // click still selects (pins) through the List.
                .onTapGesture(count: 2) {
                  openWindow(id: "feed", value: stream.id)
                }
                .contextMenu { rosterMenu(for: entry, stream: stream) }
                .accessibilityLabel(Text("\(entry.displayName) video"))
            #else
              NavigationLink(value: SidebarSelection.stream(stream.id)) {
                thumbnail
              }
              .contextMenu { rosterMenu(for: entry, stream: stream) }
              .accessibilityLabel(Text("\(entry.displayName) video"))
            #endif
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
  private func rosterMenu(for entry: NativeMeetingModel.RosterEntry, stream: RemoteVideoStream?)
    -> some View
  {
    if let stream {
      #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
          Button("Open in New Window") { openWindow(id: "feed", value: stream.id) }
        }
      #endif
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

  @ViewBuilder
  private var detailContent: some View {
    let tiles = model.tiles
    ZStack {
      if tiles.isEmpty {
        // Alone in the meeting: the self view is the meeting, exactly like the
        // web app waiting for others to arrive.
        ZStack {
          if !controller.isVideoMuted, let localCameraTrack = model.localCameraTrack {
            // The only feed on the stage, and framed like any other: its own
            // shape, the same corner, the same margin.
            LocalVideoSurface(track: localCameraTrack, contentMode: .fit) { size in
              guard size.width > 0, size.height > 0 else { return }
              selfVideoAspect = size.width / size.height
            }
            .aspectRatio(selfVideoAspect, contentMode: .fit)
            .clipShape(.rect(cornerRadius: MeetingTileView.cornerRadius))
            .overlay {
              RoundedRectangle(cornerRadius: MeetingTileView.cornerRadius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .padding(gridSpacing * 2)
          }
          // The knock at the door has its own notice over the stage, whether
          // or not anyone is on it, so this one is only about the quiet.
          if controller.connectionState == .joined, controller.lobbyRequests.isEmpty {
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
        tileView(
          for: Self.featuredTile(
            in: tiles, pinned: model.pinnedTileID, dominantSpeakerID: model.dominantSpeakerID),
          fitsVideoAspect: true
        )
        // A margin, so the feed's rounded corner reads as a corner rather
        // than running into whichever sidebar is beside it.
        .padding(gridSpacing * 2)
      }
    }
    // Before any video exists the stage has no intrinsic size; without an
    // explicit fill the leading-aligned ZStack collapses to the sidebar's
    // width and the sidebar renders centered in the window on first join.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Tell the bridge which sources are actually shown large: they receive
    // full quality while everything else is decoded at thumbnail height.
    .onAppear { controller.didChangeFeaturedVideoSources(fullQualitySourceNames) }
    .onChange(of: fullQualitySourceNames) { _, names in
      controller.didChangeFeaturedVideoSources(names)
    }
    // The video is black; the surround it sits in is chrome, and follows the
    // system's appearance like the rest of the window.
    #if os(iOS)
      .background(.background)
    #else
      .background(.black)
    #endif
    .overlay(alignment: .top) {
      if controller.connectionState == .joined, !controller.lobbyRequests.isEmpty {
        LobbyNotice(
          requests: controller.lobbyRequests,
          admitAll: controller.admitAllLobbyParticipants
        )
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: controller.lobbyRequests)
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
    #if os(iOS)
      // The stage is the split view's detail column here: captions belong to
      // it, above the controls it carries as a safe-area inset.
      .overlay(alignment: .bottom) {
        if controller.connectionState == .joined {
          CaptionOverlay(feed: conversation.captionFeed)
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
        }
      }
    #endif
    .animation(.snappy, value: controller.isChatOpen)
    .animation(.snappy, value: conversation.isOpen)
    #if os(iOS)
      // Narrow enough that the conversation slides up over the stage rather
      // than sitting beside it. The same state drives both, and the Mac's
      // sidebar besides.
      .sheet(
        isPresented: Binding(
          get: { conversation.isOpen && !usesSidePanels },
          set: { conversation.isOpen = $0 }
        )
      ) {
        TranscriptSheet(session: conversation)
      }
      // A 300pt panel over a phone leaves the stage a sliver and puts the
      // message field under the keyboard. A sheet is the platform's answer:
      // it carries its own dismissal, and the keyboard moves it rather than
      // covering it.
      .sheet(
        isPresented: Binding(
          get: { controller.isChatOpen && usesChatSheet },
          set: { controller.isChatOpen = $0 }
        )
      ) {
        ChatPanel(
          messages: model.chatMessages, send: controller.sendChatMessage, floating: false
        )
        .meetingSheetChrome()
      }
    #endif
  }

  /// Whether the trailing column has something to show. The two panels are
  /// mutually exclusive by the state that opens them, so there is never a
  /// second one to stack beside the first.
  private var hasTrailingPanel: Bool {
    usesSidePanels && (controller.isChatOpen || conversation.isOpen)
  }

  @ViewBuilder private var trailingPanelContent: some View {
    if controller.isChatOpen {
      #if os(iOS)
        ChatPanel(
          messages: model.chatMessages, send: controller.sendChatMessage,
          floating: false, close: { controller.isChatOpen = false })
      #else
        ChatPanel(messages: model.chatMessages, send: controller.sendChatMessage)
      #endif
    } else if conversation.isOpen {
      // The same document either way; the Mac edits it as rendered Markdown
      // in an NSTextView, which suits a pointer and a wide column.
      #if os(iOS)
        ConversationPane(session: conversation, isSidebar: true)
      #else
        ConversationSidebar(session: conversation)
      #endif
    }
  }

  private func gridView(tiles: [NativeMeetingModel.MeetingTile]) -> some View {
    GeometryReader { geometry in
      let layout = VideoGridLayout.packing(
        tiles.count,
        into: CGSize(
          width: geometry.size.width - gridSpacing * 2,
          height: geometry.size.height - gridSpacing * 2
        ),
        spacing: gridSpacing
      )
      // One ForEach over every tile, so a participant keeps their view — and
      // its running renderer — when a resize changes the column count.
      let columns = max(layout.columns, 1)
      LazyVGrid(
        // The gap belongs between columns, so the last one carries none: the
        // grid is then exactly as wide as the frame below claims it is.
        columns: (0..<columns).map { column in
          GridItem(
            .fixed(layout.tile.width),
            spacing: column == columns - 1 ? 0 : gridSpacing
          )
        },
        spacing: gridSpacing
      ) {
        ForEach(tiles) { tile in
          tileView(for: tile)
            .frame(width: layout.tile.width, height: layout.tile.height)
        }
      }
      // The grid is exactly as wide as its columns; the outer frame then
      // centers that block in whatever the stage has left over, which is
      // where a tall window's slack goes.
      .frame(width: layout.width)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func tileView(
    for tile: NativeMeetingModel.MeetingTile,
    fitsVideoAspect: Bool = false
  ) -> some View {
    let participant = tile.endpointID.flatMap { id in
      model.participants.first { $0.id == id }
    }
    return MeetingTileView(
      tile: tile,
      isDominantSpeaker: tile.endpointID != nil
        && tile.endpointID == model.dominantSpeakerID,
      isPinned: tile.id == model.pinnedTileID,
      fitsVideoAspect: fitsVideoAspect,
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

  /// The remote video sources rendered large right now: every tile in grid
  /// view, the featured tile otherwise, plus any feed floated in its own
  /// window. Sorted so the onChange hook compares order-independently.
  private var fullQualitySourceNames: [String] {
    let tiles = model.tiles
    var names: Set<String> = []
    if controller.usesTileGrid {
      for tile in tiles {
        if let name = tile.stream?.sourceName { names.insert(name) }
      }
    } else if !tiles.isEmpty {
      let featured = Self.featuredTile(
        in: tiles,
        pinned: model.pinnedTileID,
        dominantSpeakerID: model.dominantSpeakerID
      )
      if let name = featured.stream?.sourceName { names.insert(name) }
    }
    for stream in model.streams where model.openFeedStreamIDs.contains(stream.id) {
      if let name = stream.sourceName { names.insert(name) }
    }
    return names.sorted()
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

#endif

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
        .foregroundStyle(.primary)
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
/// The knock at the door, over the stage: who is waiting, and the one
/// button that lets them in. The roster still carries admit and deny per
/// person; this is the version that can be acted on without opening it,
/// which on a phone means without leaving the video at all.
private struct LobbyNotice: View {
  let requests: [MeetingController.LobbyRequest]
  let admitAll: () -> Void

  private var names: String {
    requests.map(\.displayName).formatted(.list(type: .and))
  }

  var body: some View {
    VStack(spacing: 6) {
      Text(
        requests.count == 1
          ? "Someone is waiting to join"
          : "\(requests.count) people are waiting to join"
      )
      .font(.headline)
      Text(names)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(3)
      Button(requests.count == 1 ? "Admit" : "Admit All", action: admitAll)
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)
    }
    .padding(16)
    .frame(maxWidth: 420)
    .background(.regularMaterial, in: .rect(cornerRadius: 14))
    .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
    .accessibilityElement(children: .contain)
  }
}

/// One person waiting in the lobby: their name with inline admit and
/// deny controls, compact enough for the narrow roster column.
private struct LobbyRequestRow: View {
  let displayName: String
  let admit: () -> Void
  let deny: () -> Void

  /// A finger wants the whole 44 points Apple asks for. A pointer does not,
  /// and the Mac's roster column is narrow enough that two of them would
  /// crowd out the name.
  #if os(iOS)
    private static let hitTarget: CGFloat = 44
  #else
    private static let hitTarget: CGFloat = 28
  #endif

  var body: some View {
    HStack(spacing: 0) {
      Text(displayName)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      Button(action: deny) {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.secondary)
          // The glyph is a third of this; the frame around it is what the
          // finger actually gets.
          .frame(width: Self.hitTarget, height: Self.hitTarget)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .help("Deny")
      .accessibilityLabel(Text("Deny \(displayName)"))
      Button(action: admit) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
          .frame(width: Self.hitTarget, height: Self.hitTarget)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .help("Admit")
      .accessibilityLabel(Text("Admit \(displayName)"))
    }
  }
}

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

/// The in-meeting group chat, in the zephyr style: an avatar and a bold
/// sender name head each run of consecutive messages from one person, with
/// the messages stacked beneath.
private struct ChatPanel: View {
  let messages: [ChatMessage]
  let send: (String) -> Void
  /// A floating panel draws its own card over the stage. Presented as a
  /// sheet on a phone it fills the sheet, which supplies the surface.
  var floating = true
  /// Given a way to close, the panel carries its own toolbar row. A sheet
  /// has its own dismissal and passes nothing.
  var close: (() -> Void)?

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
      if let close {
        HStack(spacing: 12) {
          Text("Chat").font(.headline)
          Spacer(minLength: 8)
          Button(action: close) { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        Divider()
      }
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
    .background {
      if floating {
        RoundedRectangle(cornerRadius: 14)
          .fill(.regularMaterial)
          .strokeBorder(.white.opacity(0.12))
      }
    }
    #if os(macOS)
      // Opening the panel means typing; focus lands without a click. The
      // retry covers macOS applying focus only once the window is key.
      //
      // iOS gets no such focus: the keyboard would take half the screen the
      // moment chat opens — on a phone that snaps the sheet to full height
      // and hides the meeting behind it — and while it is up the control
      // bar's More menu cannot present at all. Tapping the field still
      // raises it, when there is something to say.
      .onAppear {
        inputFocused = true
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(200))
          if !inputFocused { inputFocused = true }
        }
      }
    #endif
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
  /// One radius for the feed, its highlight border, and the margin that
  /// keeps them clear of the sidebars.
  static let cornerRadius: CGFloat = 12

  let tile: NativeMeetingModel.MeetingTile
  let isDominantSpeaker: Bool
  let isPinned: Bool
  /// Whether the tile takes the stream's shape rather than filling the space
  /// it is given. The stage does; a grid cell keeps its slot, so the grid
  /// stays a grid.
  var fitsVideoAspect = false
  /// Receive health for the tile's stream, shown as a colored dot.
  var stat: InboundVideoStatistic?
  /// The owner's latest reaction, shown next to their raised hand.
  var reaction: String?

  /// The stream's shape, once it has told us. Nil until the first frame, and
  /// for a participant with no video at all — either way the tile falls back
  /// to filling the space it is given.
  @State private var videoAspect: CGFloat?

  var body: some View {
    ZStack {
      if let stream = tile.stream {
        // Whatever shape the sender is pushing — a 16:9 camera, a portrait
        // phone, a whole desktop — the tile shows all of it rather than
        // cropping the sides to fill.
        NativeVideoSurface(track: stream.track, contentMode: .fit) { size in
          videoAspect = size.width / size.height
        }
      } else {
        Color(white: 0.14)
        Text(initials)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.white.opacity(0.85))
          .frame(width: 76, height: 76)
          .background(.white.opacity(0.12), in: .circle)
      }
    }
    // The frame becomes the picture's shape, so the black the renderer would
    // letterbox with never gets drawn — and the border lands on the edge of
    // the video rather than out in the bars.
    .aspectRatio(fitsVideoAspect ? videoAspect : nil, contentMode: .fit)
    // One shape for the feed and the border that highlights it, so the
    // speaker outline follows the corner instead of cutting across it.
    .clipShape(.rect(cornerRadius: Self.cornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Self.cornerRadius)
        .strokeBorder(
          isDominantSpeaker ? Color.accentColor : .white.opacity(0.12),
          lineWidth: isDominantSpeaker ? 2.5 : 1
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
        size: 24
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
  weak var conversation: ConversationSession?
  @Published private(set) var dominantSpeakerID: String?
  @Published private(set) var isModerator = false
  @Published private(set) var chatMessages: [ChatMessage] = []
  @Published var pinnedTileID: String?
  /// The most recent reaction per participant (keyed by endpoint id, "self"
  /// for our own), shown on that participant's tiles for a few seconds.
  @Published private(set) var tileReactions: [String: TileReaction] = [:]
  @Published var sidebarCollapsed = false
  /// Stream ids currently floated in their own feed windows; those sources
  /// stay at full receive quality even though they are off the stage.
  @Published var openFeedStreamIDs: Set<String> = []
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

  #if DEBUG
    /// A short exchange for the layout preview, so the chat panel can be
    /// looked at — on a phone especially — without a meeting behind it.
    func loadChatPreview() {
      chatMessages = [
        ChatMessage(
          id: "1", senderEndpointID: "alex", senderDisplayName: "Alex",
          text: "Are we still on for the release review?", isLocal: false, timestamp: .now),
        ChatMessage(
          id: "2", senderEndpointID: "self", senderDisplayName: "You",
          text: "Yes — starting now.", isLocal: true, timestamp: .now),
        ChatMessage(
          id: "3", senderEndpointID: "sam", senderDisplayName: "Sam",
          text: "I'll paste the dependency list here once I have it.", isLocal: false,
          timestamp: .now),
      ]
    }
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
    // Once, here rather than in the toggle command: PiP now also starts on
    // its own when the app is backgrounded, and nobody may ever have used
    // the menu item to install these.
    pictureInPicture.currentVideo = { [weak self] in
      (self?.featuredRemoteStream, self?.localCameraTrack)
    }
    pictureInPicture.onActiveChanged = { [weak self, weak controller] active in
      guard let self, let controller else { return }
      controller.didChangePictureInPicture(
        available: self.pictureInPicture.isSupported, active: active)
    }
    pictureInPicture.onError = { [weak controller] message in
      controller?.report(error: message)
    }
    await startJoin(configuration: configuration, controller: controller)
  }

  /// One tick of the mute button's level meter.
  ///
  /// WebRTC reports the source's amplitude, where ordinary speech sits near
  /// the bottom of the range and a linear meter would barely twitch, so the
  /// reading is converted to decibels across the 50 dB that carry a voice.
  /// It rises with the sound and falls back gently, so syllables read as a
  /// level rather than as a flicker.
  func refreshMicrophoneLevel(controller: MeetingController) async {
    guard let handle else { return }
    let amplitude = await handle.coordinator.localAudioLevel() ?? 0
    let decibels = amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    let normalized = min(1, max(0, (decibels + 50) / 50))
    let previous = controller.microphoneMeter.level
    controller.didChangeMicrophoneLevel(
      normalized > previous ? normalized : previous * 0.72 + normalized * 0.28)
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
            token: configuration.token,
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
      } catch NativeConferenceBootstrapError.guestAccessUnavailable {
        // The server will not take a guest at all, so waiting for a host
        // cannot help: the sign-in card is the only way forward.
        SangamLog.event("join: guestAccessUnavailable")
        controller.requireAccess(message: "This meeting needs an account. Sign in to join.")
      } catch NativeConferenceBootstrapError.passwordLoginUnavailable {
        SangamLog.event("join: passwordLoginUnavailable")
        controller.requireAccess(
          message: "This server doesn’t accept username and password sign-in.")
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
    pictureInPicture.endFollowing()
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
        case .remoteAudioTrackChanged(let stream):
          conversation?.updateAudio(stream)
        case .remoteAudioTrackRemoved(let id):
          conversation?.removeAudio(id)
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
          conversation?.removeAllAudio()
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
          conversation?.updateParticipants(updated)
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
        case .remoteSourceMutedChanged(let sourceName, let muted):
          SangamLog.event("event: sourceMuted \(sourceName) -> \(muted)")
          // A muted source stops sending; drop its tile rather than leave the
          // last frame frozen on stage. An unmute is followed by the
          // coordinator re-announcing the track, which re-adds the stream.
          if muted {
            streams.removeAll { $0.sourceName == sourceName }
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
    case .joinWithMeetingPassword(let password):
      // Pre-join like the cases above: there is no coordinator yet, so this
      // must not fall through to the guard below. The retry abandons the
      // anonymous knock still in flight, same as signing in from the lobby.
      guard let configuration else { return }
      joinTask?.cancel()
      joinTask = nil
      await startJoin(
        configuration: configuration, controller: controller, meetingPassword: password)
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
    case .setFeaturedVideoSources(let names):
      await coordinator.setFeaturedVideoSources(names)
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
    case .joinWithMeetingPassword:
      // Handled in the pre-join switch above; unreachable with a live
      // coordinator (the password can only be demanded before joining).
      break
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
    var contentMode: VideoContentMode = .fill
    /// The stream's own dimensions, for a caller that wants to take the
    /// picture's shape instead of framing bars around it.
    var onVideoSize: ((CGSize) -> Void)?

    func makeUIView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateUIView(_ view: NativeVideoRendererView, context: Context) {
      view.videoContentMode = contentMode
      view.onVideoSize = onVideoSize
      view.display(track)
    }

    static func dismantleUIView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(nil)
    }
  }

  private struct LocalVideoSurface: UIViewRepresentable {
    let track: LocalVideoTrack?
    var contentMode: VideoContentMode = .fill
    /// The camera's own dimensions, so a self view can take its shape.
    var onVideoSize: ((CGSize) -> Void)?

    func makeUIView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateUIView(_ view: NativeVideoRendererView, context: Context) {
      view.videoContentMode = contentMode
      view.onVideoSize = onVideoSize
      view.display(local: track)
    }

    static func dismantleUIView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(local: nil)
    }
  }
#elseif os(macOS)
  struct NativeVideoSurface: NSViewRepresentable {
    let track: RemoteVideoTrack?
    var contentMode: VideoContentMode = .fill
    /// The stream's own dimensions, for a caller that wants to take the
    /// picture's shape instead of framing bars around it.
    var onVideoSize: ((CGSize) -> Void)?

    func makeNSView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateNSView(_ view: NativeVideoRendererView, context: Context) {
      view.videoContentMode = contentMode
      view.display(track)
    }

    static func dismantleNSView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(nil)
    }
  }

  private struct LocalVideoSurface: NSViewRepresentable {
    let track: LocalVideoTrack?
    var contentMode: VideoContentMode = .fill
    /// The camera's own dimensions, so a self view can take its shape.
    var onVideoSize: ((CGSize) -> Void)?

    func makeNSView(context: Context) -> NativeVideoRendererView {
      NativeVideoRendererView(frame: .zero)
    }

    func updateNSView(_ view: NativeVideoRendererView, context: Context) {
      view.videoContentMode = contentMode
      view.onVideoSize = onVideoSize
      view.display(local: track)
    }

    static func dismantleNSView(_ view: NativeVideoRendererView, coordinator: Void) {
      view.display(local: nil)
    }
  }
#endif
