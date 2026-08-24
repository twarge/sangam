import JitsiConference
import JitsiMedia
import SwiftUI

#if os(iOS)
  import ReplayKit
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

  var body: some View {
    meetingGrid
      .background(.black)
      .overlay(alignment: .topTrailing) {
        // A corner self-preview for the grid layout only: the sidebar layout
        // shows the local camera at the top of the sidebar, and when nobody
        // else is in the meeting the self view already fills the window.
        if let localCameraTrack = model.localCameraTrack, !controller.isVideoMuted,
          !model.tiles.isEmpty, controller.usesTileGrid
        {
          LocalVideoSurface(track: localCameraTrack)
            .frame(width: 132, height: 176)
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
              RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.22))
            }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .padding(16)
            .accessibilityLabel("Your camera")
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

  @ViewBuilder
  private var meetingGrid: some View {
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
        sidebarStageView(tiles: tiles)
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
    .overlay(alignment: .bottomLeading) {
      HStack(spacing: 8) {
        ForEach(model.floatingReactions) { reaction in
          Text(reaction.emoji)
            .font(.system(size: 44))
            .transition(
              .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity.combined(with: .scale(scale: 1.4))
              )
            )
        }
      }
      .padding(.leading, 24)
      .padding(.bottom, 96)
      .allowsHitTesting(false)
      .animation(.snappy, value: model.floatingReactions)
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
    let featured =
      tiles.first { $0.id == model.pinnedTileID }
      ?? tiles.first { $0.stream?.videoType == "desktop" }
      ?? tiles.first { $0.endpointID != nil && $0.endpointID == model.dominantSpeakerID }
      ?? tiles[0]
    return HStack(spacing: 4) {
      if !model.sidebarCollapsed {
        VStack(spacing: 6) {
          selfSidebarTile
          ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 6) {
              ForEach(tiles) { tile in
                tileView(for: tile)
                  .frame(height: 100)
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

  private func tileView(for tile: NativeMeetingModel.MeetingTile) -> some View {
    let participant = tile.endpointID.flatMap { id in
      model.participants.first { $0.id == id }
    }
    return MeetingTileView(
      tile: tile,
      isDominantSpeaker: tile.endpointID != nil
        && tile.endpointID == model.dominantSpeakerID,
      isPinned: tile.id == model.pinnedTileID
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
}

/// The in-meeting group chat, in the zephyr style: an avatar and a bold
/// sender name head each run of consecutive messages from one person, with
/// the messages stacked beneath.
private struct ChatPanel: View {
  let messages: [ChatMessage]
  let send: (String) -> Void

  @State private var draft = ""

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
private struct MeetingTileView: View {
  let tile: NativeMeetingModel.MeetingTile
  let isDominantSpeaker: Bool
  let isPinned: Bool

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
    .clipShape(.rect(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          isDominantSpeaker ? Color.accentColor : .white.opacity(0.12),
          lineWidth: isDominantSpeaker ? 2.5 : 1
        )
    }
    .overlay(alignment: .topLeading) {
      HStack(spacing: 5) {
        if tile.handRaised {
          Image(systemName: "hand.raised.fill")
            .font(.caption)
            .foregroundStyle(.yellow)
        }
        if isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.white)
        }
      }
      .padding(6)
      .background(
        tile.handRaised || isPinned ? AnyShapeStyle(.black.opacity(0.55)) : AnyShapeStyle(.clear),
        in: .capsule
      )
      .padding(8)
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
    .accessibilityLabel(Text(tile.displayName))
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
  @Published private(set) var participants: [RemoteParticipant] = []
  @Published private(set) var dominantSpeakerID: String?
  @Published private(set) var isModerator = false
  @Published private(set) var chatMessages: [ChatMessage] = []
  @Published var pinnedTileID: String?
  @Published private(set) var floatingReactions: [FloatingReaction] = []
  @Published var sidebarCollapsed = false
  @Published private(set) var localCameraTrack: LocalVideoTrack?

  /// A reaction emoji currently floating over the meeting.
  struct FloatingReaction: Identifiable, Equatable {
    let id = UUID()
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
    controller.attach { [weak self, weak controller] command in
      guard let self, let controller else { return }
      Task { @MainActor in await self.execute(command, controller: controller) }
    }
    await startJoin(configuration: configuration, controller: controller)
  }

  private func startJoin(
    configuration: MeetingConfiguration,
    controller: MeetingController,
    username: String? = nil,
    password: String? = nil,
    waitForHost: Bool = false
  ) async {
    guard joinTask == nil, handle == nil else { return }
    SangamLog.event(
      "join begin room=\(configuration.normalizedRoom) server=\(configuration.serverURL.absoluteString) "
        + "waitForHost=\(waitForHost) authenticated=\(username != nil)")
    let task = Task { @MainActor [weak self, weak controller] in
      guard let self, let controller else { return }
      do {
        let handle = try await NativeConferenceBootstrap().connect(
          NativeConferenceJoinOptions(
            serverURL: configuration.serverURL,
            room: configuration.normalizedRoom,
            displayName: configuration.displayName,
            username: username,
            password: password,
            waitForHost: waitForHost,
            startCamera: true
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
        self.observe(handle: handle, controller: controller)
        self.startStatsLogging(handle: handle)
        // MUC membership is the user-visible definition of "joined". Jicofo's
        // default min-participants is two, so a lone participant will not
        // receive a Jingle media offer yet.
        controller.didJoin()
      } catch NativeConferenceBootstrapError.authenticationRequired {
        SangamLog.event("join: authenticationRequired")
        controller.requireAccess()
      } catch NativeConferenceBootstrapError.invalidCredentials {
        SangamLog.event("join: invalidCredentials")
        controller.requireAccess(message: "That username or password wasn’t accepted.")
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
    configuration = nil
    stopScreenCapture()
    if let handle {
      Task { await handle.coordinator.stop() }
      self.handle = nil
    }
  }

  /// Periodically logs the video RTP flow while `SANGAM_LOG` is set, so what
  /// the app actually sends and receives is visible during bring-up.
  private func startStatsLogging(handle: NativeConferenceHandle) {
    guard SangamLog.isEnabled else { return }
    statsTask?.cancel()
    statsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let self, let handle = self.handle else { return }
        let summary = await handle.coordinator.mediaStatsSummary()
        SangamLog.event("stats: \(summary)")
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
          participants = updated
        case .dominantSpeakerChanged(let endpointID):
          dominantSpeakerID = endpointID
        case .moderatorStatusChanged(let moderator):
          SangamLog.event("event: moderatorStatusChanged=\(moderator)")
          isModerator = moderator
        case .chatMessageReceived(let message):
          chatMessages.append(message)
          if chatMessages.count > 500 { chatMessages.removeFirst(chatMessages.count - 500) }
          if !message.isLocal { controller.noteUnreadChatMessage() }
        case .reactionsReceived(let endpointID, let reactions):
          SangamLog.event(
            "event: reactions from=\(endpointID ?? "self") [\(reactions.joined(separator: ", "))]")
          for name in reactions {
            let emoji = Self.reactionEmoji.first { $0.name == name }?.emoji ?? "✨"
            let reaction = FloatingReaction(emoji: emoji)
            floatingReactions.append(reaction)
            Task { @MainActor [weak self] in
              try? await Task.sleep(for: .seconds(3))
              self?.floatingReactions.removeAll { $0.id == reaction.id }
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
        case .lobbyEnabledChanged(let enabled):
          SangamLog.event("event: lobbyEnabledChanged=\(enabled)")
        case .lobbyKnockersChanged(let knockers):
          SangamLog.event("event: lobbyKnockersChanged count=\(knockers.count)")
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
    case .setScreenSharing(let enabled):
      if enabled {
        startScreenCapture(coordinator: coordinator, controller: controller)
      } else {
        stopScreenCapture()
        await coordinator.stopScreen()
        controller.didChangeScreenSharing(false)
      }
    case .switchCamera:
      controller.report(error: "Native camera switching is not connected yet.")
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

  private struct NativeVideoSurface: UIViewRepresentable {
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
  private struct NativeVideoSurface: NSViewRepresentable {
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
