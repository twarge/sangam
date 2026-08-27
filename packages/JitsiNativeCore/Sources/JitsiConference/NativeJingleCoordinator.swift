import Foundation
import JitsiBridge
import JitsiConcurrency
import JitsiJingle
import JitsiMedia
import JitsiXMPP

public struct NativeJingleConfiguration: Equatable, Sendable {
  public var responderJID: String
  public var occupantJID: String
  /// Shown to moderators while this client waits in, or watches, a lobby.
  public var displayName: String
  public var streamID: String
  public var audioTrackID: String
  public var cameraTrackID: String
  public var audioSourceName: String
  public var cameraSourceName: String
  public var screenSourceName: String

  /// The deployment's main XMPP domain, whose disco#info announces service
  /// components (AV moderation, speaker stats, …).
  public var xmppDomain: String

  /// The meeting room's bare address, derived from `occupantJID`.
  public var roomJID: String { XMPPJID.bare(occupantJID) }
  /// This client's nickname in the meeting room, derived from `occupantJID`.
  public var nickname: String { XMPPJID.resource(occupantJID) ?? "" }

  public init(
    responderJID: String,
    occupantJID: String,
    displayName: String = "",
    streamID: String = UUID().uuidString.lowercased(),
    audioTrackID: String = "native-audio-0",
    cameraTrackID: String = "native-video-0",
    audioSourceName: String = "native-a0",
    cameraSourceName: String = "native-v0",
    screenSourceName: String = "native-v1",
    xmppDomain: String = ""
  ) {
    self.responderJID = responderJID
    self.occupantJID = occupantJID
    self.displayName = displayName
    self.streamID = streamID
    self.audioTrackID = audioTrackID
    self.cameraTrackID = cameraTrackID
    self.audioSourceName = audioSourceName
    self.cameraSourceName = cameraSourceName
    self.screenSourceName = screenSourceName
    self.xmppDomain = xmppDomain.isEmpty ? XMPPJID.domain(responderJID) : xmppDomain
  }
}

/// A remote video source with its rendering track, as shown in a tile.
public struct RemoteVideoStream: Identifiable, Sendable {
  /// The WebRTC track id, which for a signaled source is the track part of its
  /// msid — the stable handle both signaling and media agree on.
  public var id: String { track.id }
  public var track: RemoteVideoTrack
  /// The Jitsi source name ("abcd1234-v0"), when the source was signaled.
  public var sourceName: String?
  /// The owning participant's endpoint id, from the source's owner or the
  /// source-name prefix.
  public var endpointID: String?
  /// "camera" or "desktop".
  public var videoType: String?
  /// The videobridge's own mixed placeholder source (jvb-v0), which never
  /// carries real video and is not shown as a participant.
  public var isBridgePlaceholder: Bool
}

/// A remote participant in the meeting room, tracked from MUC presence.
public struct RemoteParticipant: Identifiable, Equatable, Sendable {
  /// The endpoint id — the participant's MUC nickname.
  public var id: String
  public var displayName: String
  public var audioMuted: Bool
  public var videoMuted: Bool
  public var isModerator: Bool
  public var handRaised: Bool
  /// The occupant's real XMPP address, disclosed by the room to moderators;
  /// granting moderator rights needs it.
  public var realJID: String?
}

/// A group chat message in the meeting.
public struct ChatMessage: Identifiable, Equatable, Sendable {
  public var id: String
  public var senderEndpointID: String
  public var senderDisplayName: String
  public var text: String
  public var isLocal: Bool
  public var timestamp: Date
}

public enum NativeJingleEvent: Sendable {
  case negotiating(sessionID: String)
  case connected(sessionID: String)
  case peerConnectionState(NativePeerConnectionState)
  case remoteVideoTrackAdded(RemoteVideoStream)
  case remoteVideoTrackRemoved(id: String)
  /// The media session ended. Like the reference client, this does NOT end the
  /// conference: the client stays in the room — Jicofo tears the session down
  /// whenever fewer than two participants remain and re-invites when someone
  /// joins again.
  case remoteSessionEnded(reason: String?)
  /// The other people in the meeting room changed — someone joined, left, or
  /// updated their presence (name, mute state, role).
  case participantsChanged([RemoteParticipant])
  /// The bridge's dominant-speaker notification (`nil` for silence).
  case dominantSpeakerChanged(endpointID: String?)
  /// This client gained or lost moderator status — granted by the room when
  /// the previous moderator leaves, among other ways.
  case moderatorStatusChanged(Bool)
  /// A group chat message arrived (or the local one was sent).
  case chatMessageReceived(ChatMessage)
  /// Someone sent emoji reactions; `endpointID` is `nil` for our own, echoed
  /// back so the sender's UI shows them too.
  case reactionsReceived(endpointID: String?, reactions: [String])
  /// A remote source switched between camera and desktop mid-call.
  case remoteSourceVideoTypeChanged(sourceName: String, videoType: String)
  case screenSharingChanged(Bool)
  case unsupportedAction(JingleAction)
  case warning(message: String)
  /// An opt-in bring-up trace, distinct from `warning`: it reports what the
  /// signaling path is doing (incoming actions, bridge-channel state, receiver
  /// constraints) without implying anything is wrong. The app logs it only when
  /// `SANGAM_LOG` is set.
  case diagnostic(message: String)
  case failed(message: String)
  /// The attached cameras changed, or capture moved to another device — a
  /// picked switch or automatic failover after the active camera vanished.
  /// `currentDeviceID` is nil while no camera is capturing.
  case camerasChanged(available: [CameraDevice], currentDeviceID: String?)
  /// A moderator muted this client's microphone ("audio") or camera
  /// ("video"); the tracks are already stopped when this arrives.
  case mutedByModerator(media: String)
  /// AV moderation was switched on or off for a media type: while on,
  /// participants cannot unmute that media until a moderator approves them.
  case avModerationChanged(media: String, enabled: Bool, actor: String?)
  /// This client was approved (or had its approval revoked) to unmute the
  /// given media while AV moderation is on.
  case avModerationApprovalChanged(media: String, approved: Bool)
  /// An unmute was refused locally because AV moderation is on and this
  /// client is not approved; the media stays muted.
  case unmuteBlocked(media: String)
  /// The deployment's breakout-room roster changed (rooms created, removed,
  /// renamed, or their occupancy moved).
  case breakoutRoomsUpdated([BreakoutRoom])
  /// The room gained or lost a password (moderators learn this from the
  /// room's configuration).
  case roomPasswordProtectedChanged(Bool)
  /// The meeting's polls changed: one was created, or votes moved.
  case pollsUpdated([MeetingPoll])
  /// A moderator sent this client to another room; the app must leave the
  /// current conference and join `roomJID`.
  case movedToBreakoutRoom(roomJID: String)
  /// The meeting's lobby was switched on or off. Only reported to moderators,
  /// who are the only ones the room tells.
  case lobbyEnabledChanged(Bool)
  /// Who is waiting in the lobby right now, for a moderator to admit or deny.
  case lobbyKnockersChanged([LobbyKnocker])
}

/// One room in the deployment's breakout-room roster, including the main
/// room itself.
public struct BreakoutRoom: Identifiable, Equatable, Sendable {
  /// The room's full MUC address — what a client joins to move there.
  public var id: String
  public var name: String
  public var isMainRoom: Bool
  public var participantCount: Int

  public init(id: String, name: String, isMainRoom: Bool, participantCount: Int) {
    self.id = id
    self.name = name
    self.isMainRoom = isMainRoom
    self.participantCount = participantCount
  }
}

/// One poll in the meeting, with live vote state.
public struct MeetingPoll: Identifiable, Equatable, Sendable {
  public struct Answer: Equatable, Sendable {
    public var name: String
    public var voterIDs: [String]

    public init(name: String, voterIDs: [String] = []) {
      self.name = name
      self.voterIDs = voterIDs
    }
  }

  public var id: String
  public var senderID: String
  public var question: String
  public var answers: [Answer]

  public init(id: String, senderID: String, question: String, answers: [Answer]) {
    self.id = id
    self.senderID = senderID
    self.question = question
    self.answers = answers
  }
}

/// Someone waiting in the meeting's lobby to be let in.
public struct LobbyKnocker: Identifiable, Equatable, Sendable {
  /// The knocker's nickname in the lobby room; the handle `admit`/`deny` take.
  public var id: String
  public var displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

public actor NativeJingleCoordinator {
  public nonisolated let events: AsyncStream<NativeJingleEvent>
  public nonisolated let screenVideoTrack: LocalVideoTrack
  /// The local camera track, exposed so the app can render a self-preview.
  /// It is the same track published to the conference, so the preview shows
  /// exactly what other participants receive.
  public nonisolated let cameraVideoTrack: LocalVideoTrack

  private let connection: XMPPConnection
  private let configuration: NativeJingleConfiguration
  private let mediaFactory: WebRTCMediaFactory
  private let policy: PeerConnectionPolicy
  // Rebuilt when Jicofo replaces the Jingle session, so neither is `let`.
  private var eventBridge: PeerConnectionEventBridge
  private var peerConnection: PeerConnectionNegotiator

  /// Session setup, remote source updates, and local screen publication each
  /// read the installed remote SDP and then derive a new one from it. Actor
  /// isolation does not keep those two steps together, because every `await`
  /// inside them releases this actor and lets the receive loop or a toolbar
  /// action start its own negotiation. Routing all three through one queue
  /// makes each read-modify-write atomic with respect to the others.
  private let negotiations = SerialTaskQueue()
  private let audioTrack: LocalAudioTrack
  private let cameraTrack: LocalCameraTrack
  private let continuation: AsyncStream<NativeJingleEvent>.Continuation
  private var receiveTask: Task<Void, Never>?
  private var mediaTask: Task<Void, Never>?
  private var cameraTask: Task<Void, Never>?
  private var activeOffer: IncomingJingleIQ?
  private var localICECredentials: ICECredentials?
  /// The id of the session-accept awaiting Jicofo's answer. Jicofo rejecting
  /// the accept means no media can ever flow on this session, and the
  /// reference client treats that as fatal — silently ignoring the error IQ
  /// leaves an apparently joined meeting with a black screen and no clue why.
  private var pendingAcceptID: String?
  private var cameraStarted = false
  private var microphoneMuted = false
  private var cameraEnabled = true
  /// Epoch milliseconds of when the local hand went up; rides on every
  /// presence update while set.
  private var raisedHandTimestamp: String?
  private var screenEnabled = false
  private var screenPublished = false
  /// The user's receive-quality preference: per-source height cap the bridge
  /// applies to everything it forwards us (the web's performance slider).
  private var preferredReceiveMaxHeight = 720
  /// The deployment's AV moderation component, from the domain's disco
  /// identities; nil when the server runs none.
  private var avModerationComponent: String?
  /// The deployment's breakout-rooms component, discovered the same way.
  private var breakoutRoomsComponent: String?
  /// The deployment's polls component, discovered the same way.
  private var pollsComponent: String?
  /// The meeting's polls by id, in arrival order.
  private var polls: [String: MeetingPoll] = [:]
  private var pollOrder: [String] = []
  /// Whether the room currently requires a password, from its configuration
  /// (moderators refresh it on every room-config change).
  private var roomPasswordProtected = false
  /// Room-wide AV moderation state per media type ("audio"/"video").
  private var avModerationEnabled: [String: Bool] = [:]
  /// This client's per-media approval to unmute while moderation is on.
  private var avModerationSelfApproved: [String: Bool] = [:]
  private var outgoingSequence: UInt64 = 0

  // Local ICE candidates gather the moment the local description is installed,
  // which is before `accept` captures our ICE credentials. A candidate sent
  // without them wipes the bridge's copy and breaks every connectivity check,
  // so candidates that arrive early are held here and flushed once credentials
  // exist. Dropping them instead can leave ICE stuck in `checking` with no
  // local candidates ever reaching the bridge.
  private var pendingLocalCandidates: [NativeICECandidate] = []
  /// Colibri bridge channel for the current session; the videobridge only
  /// forwards remote video after we send it receiver constraints over this.
  private var bridgeChannel: BridgeChannel?
  /// The remote video source names the bridge knows (e.g. "abcd-v0"). The
  /// videobridge forwards a video source only once we ask for it by name in
  /// receiver constraints, so these are named there.
  private var remoteVideoSourceNames: [String] = []
  /// Remote video source descriptions keyed by track id (the msid's track
  /// part), so a WebRTC track can be attributed to its participant.
  private var videoSourceByTrackID: [String: RemoteVideoSourceInfo] = [:]
  /// The live remote video tracks by id. Kept so an SSRC-rewriting bridge's
  /// source remap can re-announce an existing track under its new owner —
  /// the track object itself never changes, only whose video it carries.
  private var remoteVideoTracks: [String: RemoteVideoTrack] = [:]
  /// Which track id each remote video SSRC decodes into, from the signaled
  /// sources and from receive slots created for an SSRC-rewriting bridge.
  /// This is what lets a `VideoSourcesMap` remap find the affected tile.
  private var trackIDByVideoSSRC: [UInt32: String] = [:]
  /// Remote audio SSRCs already present in the remote description, so an
  /// `AudioSourcesMap` only renegotiates for genuinely new ones.
  private var remoteAudioSSRCs: Set<UInt32> = []
  /// Receive slots created for an SSRC-rewriting bridge, numbered the way
  /// lib-jitsi-meet numbers them ("remote-video-1", "remote-audio-1", …).
  private var videoSlotCount = 0
  private var audioSlotCount = 0
  /// Consumes bridge-channel events strictly in arrival order. Source remaps
  /// are ordered state — two applied backwards leave tiles showing the wrong
  /// participant — so one consumer replaces a detached Task per event.
  private var bridgeChannelEventsTask: Task<Void, Never>?
  /// The other occupants of the meeting room, keyed by endpoint id, plus their
  /// join order for a stable tile layout.
  private var participants: [String: RemoteParticipant] = [:]
  private var participantOrder: [String] = []
  /// Set when Jicofo tore the media session down (fewer than two participants
  /// remain, say). The client stays in the room, and the next session-initiate
  /// must rebuild the peer connection instead of reusing the closed one.
  private var sessionEnded = false

  private struct RemoteVideoSourceInfo {
    var name: String?
    var owner: String?
    var videoType: String?
    var isBridgePlaceholder: Bool
    /// The id WebRTC actually gave the receiver's track — synthesized, not
    /// the signaled msid track id, for media lines added by renegotiation.
    /// Removal announcements must use this id, because it is what the app's
    /// stream list holds.
    var rtcTrackID: String?
  }

  // Lobby moderation. The room only tells moderators where its lobby is, and
  // only they can see who is waiting, so all of this stays idle for everyone
  // else.
  private var isModerator = false
  private var lobbyRoomJID: String?
  private var lobbyJoinRequested = false
  private var lobbyJoined = false
  private var lobbyOccupants: [String: LobbyOccupant] = [:]
  private var roomInfoRefresh: Task<Void, Never>?
  /// IQ requests awaiting their answer, keyed by stanza id. The receive loop
  /// owns the transport once it runs, so requests made after `start()` cannot
  /// read the socket themselves; the loop hands matching answers over here.
  private var pendingRequests: [String: CheckedContinuation<XMPPElement, any Error>] = [:]

  private struct LobbyOccupant {
    var knocker: LobbyKnocker
    var realJID: String?
  }

  public init(
    connection: XMPPConnection,
    configuration: NativeJingleConfiguration,
    policy: PeerConnectionPolicy = .init(),
    mediaFactory: WebRTCMediaFactory = .init()
  ) throws {
    let bridge = PeerConnectionEventBridge()
    let nativeConnection = try mediaFactory.makePeerConnection(policy: policy, delegate: bridge)
    let stream = AsyncStream<NativeJingleEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    self.connection = connection
    self.configuration = configuration
    self.mediaFactory = mediaFactory
    self.policy = policy
    eventBridge = bridge
    peerConnection = PeerConnectionNegotiator(connection: nativeConnection)
    audioTrack = mediaFactory.makeLocalAudioTrack(id: configuration.audioTrackID)
    let camera = mediaFactory.makeCameraTrack(id: configuration.cameraTrackID)
    cameraTrack = camera
    cameraVideoTrack = camera.videoTrack
    screenVideoTrack = mediaFactory.makeVideoTrack(id: "native-desktop-0", screenCast: true)
    events = stream.stream
    continuation = stream.continuation
  }

  deinit {
    continuation.finish()
  }

  public func start() {
    guard receiveTask == nil, mediaTask == nil else { return }
    receiveTask = Task { [weak self] in await self?.runReceiveLoop() }
    mediaTask = Task { [weak self] in await self?.runMediaLoop() }
    cameraTask = Task { [weak self] in await self?.runCameraLoop() }
    Task { [weak self] in await self?.discoverServerComponents() }
  }

  public func startCamera(
    position: CameraPosition = .front,
    width: Int32 = 1_280,
    height: Int32 = 720,
    framesPerSecond: Int = 30
  ) async throws {
    guard !cameraStarted else { return }
    try await cameraTrack.start(
      position: position,
      width: width,
      height: height,
      framesPerSecond: framesPerSecond
    )
    cameraStarted = true
  }

  public func setMicrophoneMuted(_ muted: Bool) async {
    if !muted, unmuteBlocked(media: "audio") {
      emit(.unmuteBlocked(media: "audio"))
      return
    }
    microphoneMuted = muted
    audioTrack.isMuted = muted
    await sendSourcePresence()
  }

  /// The cameras attached right now, for device pickers.
  public nonisolated static func availableCameras() -> [CameraDevice] {
    LocalCameraTrack.availableCameras()
  }

  /// Moves capture to another camera mid-call; the published track and its
  /// negotiated sources are untouched.
  public func switchCamera(toDeviceID deviceID: String) async throws {
    try await cameraTrack.switchCamera(toDeviceID: deviceID)
  }

  /// Switches the Apple-native virtual background on the outgoing camera.
  public func setVirtualBackground(_ mode: VirtualBackgroundMode) {
    cameraTrack.setVirtualBackground(mode)
  }

  public func setCameraEnabled(_ enabled: Bool) async {
    if enabled, unmuteBlocked(media: "video") {
      emit(.unmuteBlocked(media: "video"))
      return
    }
    cameraEnabled = enabled
    cameraTrack.videoTrack.isEnabled = enabled
    await sendSourcePresence()
  }

  /// Switches AV moderation on or off for a media type — while on, only
  /// approved participants can unmute it. Moderators only, and only where
  /// the deployment runs the component.
  public func setAVModeration(media: String = "audio", enabled: Bool) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard let component = avModerationComponent else {
      throw NativeJingleCoordinatorError.avModerationUnavailable
    }
    try await connection.send(
      XMPPElement(
        name: "message",
        attributes: ["to": component, "id": nextID(prefix: "avmod")],
        children: [
          XMPPElement(
            name: "av_moderation",
            attributes: ["enable": enabled ? "true" : "false", "mediaType": media]
          )
        ]
      )
    )
  }

  /// Approves a participant to unmute `media` while AV moderation is on, by
  /// whitelisting their occupant address with the component.
  public func approveUnmute(id: String, media: String = "audio") async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard let component = avModerationComponent else {
      throw NativeJingleCoordinatorError.avModerationUnavailable
    }
    guard participants[id] != nil else {
      throw NativeJingleCoordinatorError.unknownParticipant
    }
    try await connection.send(
      XMPPElement(
        name: "message",
        attributes: ["to": component, "id": nextID(prefix: "avmod")],
        children: [
          XMPPElement(
            name: "av_moderation",
            attributes: [
              "jidToWhitelist": "\(configuration.roomJID)/\(id)", "mediaType": media,
            ]
          )
        ]
      )
    )
  }

  /// Raises or lowers the local hand, signalled as Jitsi's
  /// `jitsi_participant_raisedHand` presence property.
  public func setHandRaised(_ raised: Bool) async {
    raisedHandTimestamp =
      raised ? String(Int(Date().timeIntervalSince1970 * 1000)) : nil
    await sendSourcePresence()
  }

  /// Sends a group chat message to the meeting and reports it back as a local
  /// `chatMessageReceived`, so the sender's own transcript needs no separate
  /// bookkeeping.
  public func sendChatMessage(_ text: String) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let id = nextID(prefix: "chat")
    try await connection.send(
      XMPPElement(
        name: "message",
        attributes: ["id": id, "to": configuration.roomJID, "type": "groupchat"],
        children: [XMPPElement(name: "body", text: trimmed)]
      )
    )
    emit(
      .chatMessageReceived(
        ChatMessage(
          id: id,
          senderEndpointID: configuration.nickname,
          senderDisplayName: configuration.displayName.isEmpty
            ? "You" : configuration.displayName,
          text: trimmed,
          isLocal: true,
          timestamp: Date()
        )
      )
    )
  }

  /// Broadcasts an emoji reaction the way the web app does — an endpoint
  /// message over the bridge channel. Best effort: without a bridge channel
  /// there is nobody to see it anyway.
  public func sendReaction(_ name: String) async {
    if let bridgeChannel,
      let data = try? ReactionEndpointMessage(
        reactions: [name],
        timestampMilliseconds: Int(Date().timeIntervalSince1970 * 1000)
      ).encoded()
    {
      try? await bridgeChannel.send(raw: data)
    }
    emit(.reactionsReceived(endpointID: nil, reactions: [name]))
  }

  /// Removes a participant from the meeting. Only moderators can.
  public func kickParticipant(id: String) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard participants[id] != nil else {
      throw NativeJingleCoordinatorError.unknownParticipant
    }
    let requestID = nextID(prefix: "kick")
    _ = try await request(
      MUCKickRequest(
        id: requestID,
        roomJID: configuration.roomJID,
        nickname: id,
        reason: "Removed by the host"
      ).element(),
      id: requestID
    )
  }

  /// Asks Jicofo to mute a participant's microphone (or camera, with media
  /// "video"), as the web's moderation menu does. Only moderators can, and
  /// there is deliberately no remote unmute — people unmute themselves.
  public func muteParticipant(id: String, media: String = "audio") async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard participants[id] != nil else {
      throw NativeJingleCoordinatorError.unknownParticipant
    }
    let requestID = nextID(prefix: "mute")
    _ = try await request(
      JitsiMuteRequest(
        id: requestID,
        roomJID: configuration.roomJID,
        targetNickname: id,
        media: media
      ).element(),
      id: requestID
    )
  }

  /// Switches the meeting's waiting room (lobby) on or off: a members-only
  /// room configuration change, submitted exactly as the reference client
  /// does. When enabling, everyone already in the room is granted
  /// membership first so they are not thrown into the lobby they now guard.
  public func setLobbyEnabled(_ enabled: Bool) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    if enabled {
      let memberJIDs = participants.values.compactMap { $0.realJID.map { XMPPJID.bare($0) } }
      if !memberJIDs.isEmpty {
        let id = nextID(prefix: "affiliations")
        _ = try? await request(
          XMPPElement(
            name: "iq",
            attributes: ["id": id, "to": configuration.roomJID, "type": "set"],
            children: [
              XMPPElement(
                name: "query",
                namespace: "http://jabber.org/protocol/muc#admin",
                children: memberJIDs.map {
                  XMPPElement(name: "item", attributes: ["affiliation": "member", "jid": $0])
                }
              )
            ]
          ),
          id: id
        )
      }
    }
    var fields: [(name: String, value: String)] = [
      ("muc#roomconfig_membersonly", enabled ? "true" : "false")
    ]
    if roomPasswordProtected {
      fields.append(("muc#roomconfig_passwordprotectedroom", "1"))
    }
    try await submitRoomConfiguration(
      fields: fields, requiredField: "muc#roomconfig_membersonly")
    scheduleRoomInfoRefresh()
  }

  /// Sets or removes the meeting password (nil or empty removes it).
  public func setRoomPassword(_ password: String?) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    let key = password ?? ""
    var fields: [(name: String, value: String)] = [
      ("muc#roomconfig_roomsecret", key),
      ("muc#roomconfig_passwordprotectedroom", key.isEmpty ? "0" : "1"),
      // The reference client always pins this; prosody once reset it on
      // partial submits (prosody issue 373).
      ("muc#roomconfig_whois", "anyone"),
    ]
    if lobbyRoomJID != nil {
      fields.append(("muc#roomconfig_membersonly", "true"))
    }
    try await submitRoomConfiguration(
      fields: fields, requiredField: "muc#roomconfig_roomsecret")
    if roomPasswordProtected != !key.isEmpty {
      roomPasswordProtected = !key.isEmpty
      emit(.roomPasswordProtectedChanged(roomPasswordProtected))
    }
  }

  /// XEP-0045 room reconfiguration: fetch the owner form to confirm the
  /// service offers `requiredField`, then submit just the changed fields.
  private func submitRoomConfiguration(
    fields: [(name: String, value: String)],
    requiredField: String
  ) async throws {
    let ownerNamespace = "http://jabber.org/protocol/muc#owner"
    let getID = nextID(prefix: "roomconfig")
    let form = try await request(
      XMPPElement(
        name: "iq",
        attributes: ["id": getID, "to": configuration.roomJID, "type": "get"],
        children: [XMPPElement(name: "query", namespace: ownerNamespace)]
      ),
      id: getID
    )
    let offered = form.child(named: "query")?.child(named: "x")?.children.contains {
      $0.name == "field" && $0[attribute: "var"] == requiredField
    }
    guard offered == true else {
      throw NativeJingleCoordinatorError.roomConfigurationUnsupported
    }
    var formFields = [
      XMPPElement(
        name: "field",
        attributes: ["var": "FORM_TYPE"],
        children: [
          XMPPElement(name: "value", text: "http://jabber.org/protocol/muc#roomconfig")
        ]
      )
    ]
    formFields += fields.map { field in
      XMPPElement(
        name: "field",
        attributes: ["var": field.name],
        children: [XMPPElement(name: "value", text: field.value)]
      )
    }
    let setID = nextID(prefix: "roomconfig")
    _ = try await request(
      XMPPElement(
        name: "iq",
        attributes: ["id": setID, "to": configuration.roomJID, "type": "set"],
        children: [
          XMPPElement(
            name: "query",
            namespace: ownerNamespace,
            children: [
              XMPPElement(
                name: "x",
                namespace: "jabber:x:data",
                attributes: ["type": "submit"],
                children: formFields
              )
            ]
          )
        ]
      ),
      id: setID
    )
  }

  /// Creates a poll; the polls component broadcasts it to the room (this
  /// client included, which is when it appears locally).
  public func createPoll(question: String, answers: [String]) async throws {
    try await sendPollsCommand([
      "type": "polls",
      "command": "new-poll",
      "pollId": String(UUID().uuidString.prefix(12)).lowercased(),
      "question": question,
      "answers": answers.map { ["name": $0] },
    ])
  }

  /// Casts (or changes) this client's votes on a poll — one flag per
  /// answer, exactly as the reference client sends it.
  public func answerPoll(id: String, votes: [Bool]) async throws {
    try await sendPollsCommand([
      "type": "polls",
      "command": "answer-poll",
      "pollId": id,
      "answers": votes,
    ])
  }

  private func sendPollsCommand(_ payload: [String: Any]) async throws {
    guard let component = pollsComponent else {
      throw NativeJingleCoordinatorError.pollsUnavailable
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw NativeJingleCoordinatorError.pollsUnavailable
    }
    try await connection.send(
      XMPPElement(
        name: "message",
        attributes: ["to": component, "type": "chat", "id": nextID(prefix: "polls")],
        children: [
          XMPPElement(
            name: "json-message",
            namespace: "http://jitsi.org/jitmeet",
            text: json
          )
        ]
      )
    )
  }

  /// Creates a breakout room with the given name. Moderators only, and
  /// only where the deployment runs the component.
  public func createBreakoutRoom(subject: String) async throws {
    try await sendBreakoutRoomsCommand([
      "subject": subject, "type": "features/breakout-rooms/add",
    ])
  }

  /// Removes a breakout room by its full MUC address.
  public func removeBreakoutRoom(jid: String) async throws {
    try await sendBreakoutRoomsCommand([
      "breakoutRoomJid": jid, "type": "features/breakout-rooms/remove",
    ])
  }

  /// Sends a participant to another room; the component instructs their
  /// client to move.
  public func sendParticipantToBreakoutRoom(id: String, roomJID: String) async throws {
    guard participants[id] != nil else {
      throw NativeJingleCoordinatorError.unknownParticipant
    }
    try await sendBreakoutRoomsCommand([
      "participantJid": "\(configuration.roomJID)/\(id)",
      "roomJid": roomJID,
      "type": "features/breakout-rooms/move-to-room",
    ])
  }

  private func sendBreakoutRoomsCommand(_ attributes: [String: String]) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard let component = breakoutRoomsComponent else {
      throw NativeJingleCoordinatorError.breakoutRoomsUnavailable
    }
    try await connection.send(
      XMPPElement(
        name: "message",
        attributes: ["to": component, "id": nextID(prefix: "breakout")],
        children: [XMPPElement(name: "breakout_rooms", attributes: attributes)]
      )
    )
  }

  /// Makes a participant a moderator (room owner, as the web app grants it).
  /// The affiliation change addresses the occupant's real JID, which the room
  /// only discloses to moderators.
  public func grantModerator(id: String) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard let participant = participants[id] else {
      throw NativeJingleCoordinatorError.unknownParticipant
    }
    guard let jid = participant.realJID else {
      throw NativeJingleCoordinatorError.participantAddressUnknown
    }
    let requestID = nextID(prefix: "grant")
    _ = try await request(
      MUCAffiliationRequest(
        id: requestID,
        roomJID: configuration.roomJID,
        jid: jid,
        affiliation: "owner"
      ).element(),
      id: requestID
    )
  }

  /// A concise one-line summary of current media flow, for the opt-in
  /// `SANGAM_LOG` bring-up log.
  public func mediaStatsSummary() async -> String {
    await peerConnection.videoStatsSummary()
  }

  /// Per-stream receive statistics keyed by the announced track id, for the
  /// tiles' connection indicators.
  public func inboundVideoStatistics() async -> [InboundVideoStatistic] {
    await peerConnection.inboundVideoStatistics()
  }

  /// The number of remote ICE candidates WebRTC has accepted. Exposed for tests
  /// that verify the bridge's inline session-initiate candidates were ingested.
  public func remoteCandidateCount() async -> Int {
    await peerConnection.remoteCandidateCount()
  }

  public func setScreenFramesEnabled(_ enabled: Bool) {
    screenEnabled = enabled
    screenVideoTrack.isEnabled = enabled
    if screenPublished { emit(.screenSharingChanged(enabled)) }
  }

  /// Publishes the first desktop source. Once allocated, its sender is retained
  /// and subsequent stop/start operations only disable or enable its frames.
  ///
  /// Sharing is allowed with no media session live — alone in the meeting,
  /// say, after Jicofo expired the session. Capture keeps running and the
  /// source is published automatically when the next session is accepted,
  /// exactly as the web app arms a share before anyone joins.
  public func publishScreen() async throws {
    screenEnabled = true
    screenVideoTrack.isEnabled = true
    try await negotiations.run {
      try await self.publishScreenIfSessionReady()
    }
    emit(.screenSharingChanged(true))
    await sendSourcePresence()
  }

  /// Publishes the screen when a media session exists; otherwise leaves the
  /// share armed for `accept` to publish. Must run on the negotiations queue.
  private func publishScreenIfSessionReady() async throws {
    guard activeOffer != nil, await peerConnection.currentRemoteSDP() != nil else { return }
    try await performPublishScreen()
  }

  private func performPublishScreen() async throws {
    if screenPublished { return }
    guard let activeOffer, let remoteSDP = await peerConnection.currentRemoteSDP() else {
      throw NativeJingleCoordinatorError.sessionNotReady
    }
    let addition = try JitsiMultistreamSDP().addingLocalSourceMedia(to: remoteSDP)
    let negotiation = try await peerConnection.addLocalVideoSource(
      screenVideoTrack,
      streamID: configuration.streamID,
      mid: addition.mid,
      expandedRemoteOfferSDP: addition.sdp
    )
    let content = try JitsiMultistreamSDP().sourceContent(
      from: negotiation.localSDP,
      mid: addition.mid,
      metadata: LocalSourceMetadata(
        name: configuration.screenSourceName,
        videoType: "desktop"
      )
    )
    let update = JingleIQBuilder().sourceUpdate(
      action: .sourceAdd,
      sessionID: activeOffer.session.sessionID,
      content: content,
      initiator: activeOffer.session.initiator ?? activeOffer.sender,
      to: activeOffer.sender,
      from: configuration.responderJID,
      id: nextID(prefix: "source-add")
    )
    try await connection.send(update)
    screenPublished = true
  }

  public func stopScreen() async {
    screenEnabled = false
    screenVideoTrack.isEnabled = false
    emit(.screenSharingChanged(false))
    await sendSourcePresence()
  }

  /// Hands over the room's answer to this client's own join presence, which
  /// the join consumed before the receive loop started. Moderator status
  /// comes from it; later changes arrive through the loop.
  public func noteLocalPresence(_ presence: MUCParticipantPresence) {
    updateLocalRole(presence)
  }

  /// Lets a lobby participant into the meeting. Only moderators can; the room
  /// refuses the invitation from anyone else.
  public func admitLobbyParticipant(id: String) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard let occupant = lobbyOccupants[id] else {
      throw NativeJingleCoordinatorError.unknownLobbyParticipant
    }
    guard let jid = occupant.realJID else {
      throw NativeJingleCoordinatorError.lobbyParticipantAddressUnknown
    }
    try await connection.send(
      MUCInviteMessage(roomJID: configuration.roomJID, inviteeJIDs: [jid]).element()
    )
  }

  /// Turns a lobby participant away. They see it as a refusal; the lobby
  /// tells the meeting room, which moderators may show as a notification.
  public func denyLobbyParticipant(id: String) async throws {
    guard isModerator else { throw NativeJingleCoordinatorError.notModerator }
    guard let lobbyRoomJID, lobbyOccupants[id] != nil else {
      throw NativeJingleCoordinatorError.unknownLobbyParticipant
    }
    let requestID = nextID(prefix: "lobby-deny")
    _ = try await request(
      MUCKickRequest(
        id: requestID,
        roomJID: lobbyRoomJID,
        nickname: id,
        reason: "The host did not admit you."
      ).element(),
      id: requestID
    )
  }

  public func stop() async {
    receiveTask?.cancel()
    mediaTask?.cancel()
    cameraTask?.cancel()
    roomInfoRefresh?.cancel()
    receiveTask = nil
    mediaTask = nil
    cameraTask = nil
    roomInfoRefresh = nil
    failPendingRequests(with: CancellationError())
    if cameraStarted {
      await cameraTrack.stop()
      cameraStarted = false
    }
    await negotiations.drain()
    await peerConnection.close()
    await closeBridgeChannel()
    await connection.disconnect()
    activeOffer = nil
    localICECredentials = nil
    pendingAcceptID = nil
    screenPublished = false
    sessionEnded = false
    avModerationComponent = nil
    avModerationEnabled = [:]
    avModerationSelfApproved = [:]
    breakoutRoomsComponent = nil
    pollsComponent = nil
    polls = [:]
    pollOrder = []
    roomPasswordProtected = false
    pendingLocalCandidates.removeAll()
    clearRemoteSourceState()
    participants.removeAll()
    participantOrder.removeAll()
    lobbyRoomJID = nil
    lobbyJoinRequested = false
    lobbyJoined = false
    lobbyOccupants.removeAll()
  }

  private func runReceiveLoop() async {
    defer {
      // Nothing answers once the loop stops; a request left waiting would
      // otherwise hang until its timeout.
      failPendingRequests(with: XMPPConnectionError.notReady)
    }
    while !Task.isCancelled {
      let element: XMPPElement
      do {
        element = try await connection.nextElement()
      } catch is CancellationError {
        return
      } catch {
        // Nothing further will arrive on a transport that cannot be read.
        emit(.failed(message: error.localizedDescription))
        return
      }

      do {
        try await handle(element)
      } catch is CancellationError {
        return
      } catch let error as FatalSignalingError {
        emit(.failed(message: error.underlying.localizedDescription))
        return
      } catch {
        // One stanza could not be processed. The conference itself is still
        // live, so report it and keep reading instead of hanging up on
        // everyone because a single message was unusable.
        emit(
          .warning(
            message: "Ignored a conference message that could not be processed: "
              + error.localizedDescription
          )
        )
      }
    }
  }

  private func handle(_ element: XMPPElement) async throws {
    if let response = XMPPClientCapabilities.jitsiNative.response(to: element) {
      try await connection.send(response)
      return
    }
    switch element.name {
    case "iq":
      try await handleIQ(element)
    case "presence":
      handlePresence(element)
    case "message":
      handleMessage(element)
    default:
      break
    }
  }

  private func handleIQ(_ element: XMPPElement) async throws {
    let type = element[attribute: "type"]
    if let id = element[attribute: "id"], id == pendingAcceptID,
      type == "result" || type == "error"
    {
      pendingAcceptID = nil
      if type == "error" {
        let error = element.child(named: "error")
        let condition = error?.children.first(where: { $0.name != "text" })?.name ?? "unknown error"
        // Jicofo's <text> names the exact objection; without it "bad-request"
        // is undebuggable.
        let text = (error?.child(named: "text")?.text).flatMap { $0.isEmpty ? nil : $0 }
        let detail = text.map { " — \($0)" } ?? ""
        emit(
          .failed(message: "The conference rejected the session answer (\(condition)\(detail))."))
      } else {
        emit(.diagnostic(message: "session-accept acknowledged"))
      }
      return
    }
    if let id = element[attribute: "id"], pendingRequests[id] != nil,
      type == "result" || type == "error"
    {
      if type == "error" {
        let error = element.child(named: "error")
        resolveRequest(
          id: id,
          with: .failure(
            XMPPConnectionError.iqError(
              id: id,
              condition: error?.children.first(where: { $0.name != "text" })?.name,
              text: error?.child(named: "text")?.text
            )
          )
        )
      } else {
        resolveRequest(id: id, with: .success(element))
      }
      return
    }
    guard type == "set" else { return }
    // A moderator asked Jicofo to mute us; the request arrives as a plain
    // IQ from the focus, the media named by the mute element's namespace.
    for media in ["audio", "video"] {
      guard
        let mute = element.child(named: "mute", namespace: "http://jitsi.org/jitmeet/\(media)")
      else { continue }
      try await handleRemoteMute(element: element, mute: mute, media: media)
      return
    }
    guard element.child(named: "jingle", namespace: JingleParser.jingleNamespace) != nil else {
      return
    }
    let incoming = try IncomingJingleIQ(element: element)
    try await connection.send(incoming.acknowledgment())

    emit(
      .diagnostic(
        message: "jingle in: \(incoming.session.action.rawValue) "
          + "focus=\(isFocus(incoming.sender)) "
          + "video=\(remoteVideoSourceNames(in: incoming.session))"))

    // Only the room focus (Jicofo) drives the bridge session this client runs.
    // A session-initiate from any other occupant is a peer's peer-to-peer
    // offer, declined below because answering it hands the peer an SDP it
    // cannot apply and takes its conference down. Every *other* Jingle action
    // from a non-focus sender — its trickled ICE candidates, its terminate —
    // belongs to that same unsupported session and must be ignored: applying a
    // peer's candidate to the bridge connection fails ("Error processing ICE
    // candidate"), and honouring a peer's terminate would close the bridge
    // session outright.
    guard isFocus(incoming.sender) else {
      if incoming.session.action == .sessionInitiate {
        await declineForeignSession(incoming)
      }
      return
    }

    switch incoming.session.action {
    case .sessionInitiate:
      if let activeOffer, activeOffer.session.sessionID == incoming.session.sessionID {
        // A duplicate of the session already accepted; the acknowledgement sent
        // above is all Jicofo is waiting for.
        break
      }
      // A second initiate with a new id is Jicofo replacing the session — a
      // bridge reselect or ICE restart, common right after joining a meeting
      // that is already live — or a re-invite after the previous session was
      // torn down because this client was alone in the room. Either way the
      // closed or mid-negotiation peer connection cannot answer the new offer;
      // rebuild and answer it fresh, as lib-jitsi-meet does.
      //
      // Without an accepted session there is no media at all, so a failure here
      // is the one signaling error the conference cannot continue past.
      let needsFreshConnection = activeOffer != nil || sessionEnded
      do {
        try await negotiations.run {
          if needsFreshConnection { try await self.resetForNewSession() }
          try await self.accept(incoming)
        }
        sessionEnded = false
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw FatalSignalingError(underlying: error)
      }
    case .transportInfo:
      try await addRemoteCandidates(incoming.session)
    case .sessionTerminate:
      let reason = element.child(named: "jingle", namespace: JingleParser.jingleNamespace)?
        .child(named: "reason", namespace: JingleParser.jingleNamespace)?
        .children.first?.name
      emit(.remoteSessionEnded(reason: reason))
      await negotiations.drain()
      await peerConnection.close()
      await closeBridgeChannel()
      activeOffer = nil
      clearRemoteSourceState()
      remoteVideoSourceNames.removeAll()
      // The conference goes on: stay in the room and expect a fresh
      // session-initiate once there are two participants again.
      sessionEnded = true
    case .sourceAdd, .sourceRemove:
      let session = incoming.session
      try await negotiations.run { try await self.applyRemoteSourceUpdate(session) }
    case .contentAdd, .contentRemove:
      emit(.unsupportedAction(incoming.session.action))
    case .sessionAccept, .transportReplace, .transportAccept:
      emit(.unsupportedAction(incoming.session.action))
    }
  }

  /// Honours a focus-relayed mute: mutes the microphone (or stops the
  /// camera), acknowledges the IQ, and tells the app so its toggles follow.
  /// Requests not sent by the focus are ignored, like the reference client;
  /// so are unmutes, which the protocol does not allow remotely.
  private func handleRemoteMute(
    element: XMPPElement,
    mute: XMPPElement,
    media: String
  ) async throws {
    if let id = element[attribute: "id"], let from = element[attribute: "from"] {
      try await connection.send(
        XMPPElement(name: "iq", attributes: ["id": id, "to": from, "type": "result"]))
    }
    guard let from = element[attribute: "from"], isFocus(from), mute.text == "true" else {
      return
    }
    if media == "audio" {
      microphoneMuted = true
      audioTrack.isMuted = true
    } else {
      cameraEnabled = false
      cameraTrack.videoTrack.isEnabled = false
    }
    await sendSourcePresence()
    emit(.mutedByModerator(media: media))
  }

  private func handlePresence(_ element: XMPPElement) {
    guard let from = element[attribute: "from"] else { return }
    if let lobbyRoomJID, XMPPJID.matches(XMPPJID.bare(from), lobbyRoomJID) {
      handleLobbyPresence(element)
    } else if XMPPJID.matches(from, configuration.occupantJID),
      let presence = try? MUCParticipantPresence(element: element)
    {
      updateLocalRole(presence)
    } else if XMPPJID.matches(XMPPJID.bare(from), configuration.roomJID),
      let presence = try? MUCParticipantPresence(element: element)
    {
      updateParticipant(presence)
    }
  }

  /// Tracks the other occupants of the meeting room. The focus (Jicofo joins
  /// under the reserved nickname "focus") is infrastructure, not a
  /// participant; our own presence goes through `updateLocalRole`.
  private func updateParticipant(_ presence: MUCParticipantPresence) {
    guard presence.endpointID != "focus", !presence.isSelf else { return }
    let before = participants
    if presence.isAvailable {
      // Mute states arrive both as legacy elements and per-source SourceInfo;
      // take whichever the sender provided.
      let audioMuted =
        presence.audioMuted
        ?? presence.sources.first(where: { $0.kind == "audio" })?.muted
      let videoMuted =
        presence.videoMuted
        ?? presence.sources.first(where: { $0.kind == "video" })?.muted
      if participants[presence.endpointID] == nil {
        participantOrder.append(presence.endpointID)
      }
      participants[presence.endpointID] = RemoteParticipant(
        id: presence.endpointID,
        displayName: presence.displayName.flatMap { $0.isEmpty ? nil : $0 }
          ?? presence.endpointID,
        audioMuted: audioMuted ?? false,
        videoMuted: videoMuted ?? false,
        isModerator: presence.isModerator,
        handRaised: presence.raisedHandTimestamp != nil,
        realJID: presence.realJID ?? participants[presence.endpointID]?.realJID
      )
    } else {
      participants.removeValue(forKey: presence.endpointID)
      participantOrder.removeAll { $0 == presence.endpointID }
    }
    if participants != before {
      emit(.participantsChanged(participantOrder.compactMap { participants[$0] }))
    }
  }

  private func handleMessage(_ element: XMPPElement) {
    if handleComponentMessage(element) { return }
    guard
      let from = element[attribute: "from"],
      XMPPJID.matches(XMPPJID.bare(from), configuration.roomJID)
    else { return }
    // Group chat. The room reflects our own message back; that echo is
    // skipped because sending already reported the message locally.
    if element[attribute: "type"] == "groupchat",
      let body = element.child(named: "body")?.text.prefix(4_096),
      !body.isEmpty,
      let sender = XMPPJID.resource(from),
      sender != configuration.nickname
    {
      emit(
        .chatMessageReceived(
          ChatMessage(
            id: element[attribute: "id"] ?? UUID().uuidString,
            senderEndpointID: sender,
            senderDisplayName: participants[sender]?.displayName ?? sender,
            text: String(body),
            isLocal: false,
            timestamp: Date()
          )
        )
      )
    }
    // The room says only that *something* about its configuration changed;
    // whether the lobby is among it takes another look at the room.
    if isModerator, MUCRoomNotice.isConfigurationChange(element) {
      scheduleRoomInfoRefresh()
    }
  }

  /// Asks the deployment's main domain which service components it runs;
  /// AV moderation is only offered when the disco identities announce one.
  private func discoverServerComponents() async {
    let id = nextID(prefix: "components")
    do {
      let response = try await request(
        MUCRoomInfoRequest(id: id, roomJID: configuration.xmppDomain).element(),
        id: id
      )
      let identities = response.child(named: "query")?.children.filter { $0.name == "identity" }
      for identity in identities ?? [] {
        switch identity[attribute: "type"] {
        case "av_moderation": avModerationComponent = identity[attribute: "name"]
        case "breakout_rooms": breakoutRoomsComponent = identity[attribute: "name"]
        case "polls": pollsComponent = identity[attribute: "name"]
        default: break
        }
      }
      emit(
        .diagnostic(
          message: "components: av-moderation=\(avModerationComponent ?? "none")"
            + " breakout-rooms=\(breakoutRoomsComponent ?? "none")"
            + " polls=\(pollsComponent ?? "none")"))
    } catch {
      emit(.diagnostic(message: "components: discovery failed (\(error.localizedDescription))"))
    }
  }

  /// Handles a service component's `json-message` payload — AV moderation
  /// or breakout-room state, exactly as the reference parses them. Returns
  /// whether the message was one.
  private func handleComponentMessage(_ element: XMPPElement) -> Bool {
    guard
      let from = element[attribute: "from"],
      let json = element.child(named: "json-message", namespace: "http://jitsi.org/jitmeet")?
        .text,
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else { return false }
    let sender = XMPPJID.bare(from)
    if type == "av_moderation", let component = avModerationComponent,
      XMPPJID.matches(sender, component)
    {
      handleAVModerationMessage(object)
      return true
    }
    if type == "breakout_rooms", let component = breakoutRoomsComponent,
      XMPPJID.matches(sender, component)
    {
      handleBreakoutRoomsMessage(object)
      return true
    }
    if type == "polls", let component = pollsComponent, XMPPJID.matches(sender, component) {
      handlePollsMessage(object)
      return true
    }
    return false
  }

  private func handlePollsMessage(_ object: [String: Any]) {
    switch object["command"] as? String {
    case "new-poll":
      applyPoll(object)
    case "old-polls":
      // The component replays existing polls to a late joiner.
      for poll in object["polls"] as? [[String: Any]] ?? [] {
        applyPoll(poll)
      }
    case "answer-poll":
      guard
        let id = object["pollId"] as? String,
        var poll = polls[id],
        let sender = object["senderId"] as? String,
        let votes = object["answers"] as? [Any]
      else { return }
      for (index, vote) in votes.prefix(poll.answers.count).enumerated() {
        let selected = (vote as? Bool) ?? (vote as? NSNumber)?.boolValue ?? false
        poll.answers[index].voterIDs.removeAll { $0 == sender }
        if selected { poll.answers[index].voterIDs.append(sender) }
      }
      polls[id] = poll
      emitPolls()
    default:
      break
    }
  }

  private func applyPoll(_ object: [String: Any]) {
    guard
      let id = object["pollId"] as? String,
      let question = object["question"] as? String
    else { return }
    let answers = (object["answers"] as? [[String: Any]] ?? []).map { answer in
      // Voters arrive as an array of endpoint ids, or as an id-to-name map
      // from older component versions.
      let voters =
        answer["voters"] as? [String]
        ?? (answer["voters"] as? [String: Any]).map { Array($0.keys) }
        ?? []
      return MeetingPoll.Answer(name: answer["name"] as? String ?? "", voterIDs: voters)
    }
    if polls[id] == nil { pollOrder.append(id) }
    polls[id] = MeetingPoll(
      id: id,
      senderID: object["senderId"] as? String ?? "",
      question: question,
      answers: answers
    )
    emitPolls()
  }

  private func emitPolls() {
    emit(.pollsUpdated(pollOrder.compactMap { polls[$0] }))
  }

  private func handleAVModerationMessage(_ object: [String: Any]) {
    let media = object["mediaType"] as? String ?? "audio"
    if object["whitelists"] != nil {
      // Moderators receive the full whitelist; this client only needs its
      // own approval state, which arrives separately.
      return
    }
    if let enabled = object["enabled"] as? Bool {
      if avModerationEnabled[media] != enabled {
        avModerationEnabled[media] = enabled
        if !enabled { avModerationSelfApproved[media] = nil }
        emit(
          .avModerationChanged(media: media, enabled: enabled, actor: object["actor"] as? String)
        )
      }
      return
    }
    if object["removed"] as? Bool == true {
      avModerationSelfApproved[media] = false
      emit(.avModerationApprovalChanged(media: media, approved: false))
      return
    }
    if object["approved"] as? Bool == true {
      avModerationSelfApproved[media] = true
      emit(.avModerationApprovalChanged(media: media, approved: true))
    }
  }

  private func handleBreakoutRoomsMessage(_ object: [String: Any]) {
    switch object["event"] as? String {
    case "features/breakout-rooms/update":
      guard let rooms = object["rooms"] as? [String: [String: Any]] else { return }
      let parsed = rooms.map { key, value in
        BreakoutRoom(
          id: value["jid"] as? String ?? key,
          name: value["name"] as? String ?? key,
          isMainRoom: value["isMainRoom"] as? Bool ?? false,
          participantCount: (value["participants"] as? [String: Any])?.count ?? 0
        )
      }.sorted { lhs, rhs in
        // Main room first, then by name for a stable menu.
        if lhs.isMainRoom != rhs.isMainRoom { return lhs.isMainRoom }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
      emit(.breakoutRoomsUpdated(parsed))
    case "features/breakout-rooms/move-to-room":
      guard let roomJID = object["roomJid"] as? String else { return }
      emit(.movedToBreakoutRoom(roomJID: roomJID))
    default:
      break
    }
  }

  /// Whether an unmute of `media` must be refused: moderation is on and no
  /// approval has arrived. Moderators are never blocked.
  private func unmuteBlocked(media: String) -> Bool {
    avModerationEnabled[media] == true && avModerationSelfApproved[media] != true && !isModerator
  }

  private func updateLocalRole(_ presence: MUCParticipantPresence) {
    let moderator = presence.isAvailable && presence.isModerator
    guard moderator != isModerator else { return }
    isModerator = moderator
    emit(.moderatorStatusChanged(moderator))
    if moderator {
      scheduleRoomInfoRefresh()
    } else {
      forgetLobby()
    }
  }

  private func scheduleRoomInfoRefresh() {
    roomInfoRefresh = Task { [weak self] in await self?.refreshRoomInfo() }
  }

  private func refreshRoomInfo() async {
    let id = nextID(prefix: "roominfo")
    do {
      let response = try await request(
        MUCRoomInfoRequest(id: id, roomJID: configuration.roomJID).element(),
        id: id
      )
      try await apply(roomInfo: MUCRoomInfo(element: response))
    } catch is CancellationError {
      return
    } catch {
      emit(
        .warning(
          message: "Could not read the meeting's lobby settings: \(error.localizedDescription)"
        )
      )
    }
  }

  private func apply(roomInfo: MUCRoomInfo) async throws {
    if roomInfo.isPasswordProtected != roomPasswordProtected {
      roomPasswordProtected = roomInfo.isPasswordProtected
      emit(.roomPasswordProtectedChanged(roomPasswordProtected))
    }
    let lobby = roomInfo.activeLobbyRoomJID
    if let current = lobbyRoomJID, lobby.map({ XMPPJID.matches($0, current) }) != true {
      if lobbyJoined {
        try? await connection.send(
          MUCLeavePresence(occupantJID: "\(current)/\(configuration.nickname)").element()
        )
      }
      forgetLobby()
    }
    guard let lobby else { return }
    if lobbyRoomJID == nil {
      lobbyRoomJID = lobby
      emit(.lobbyEnabledChanged(true))
    }
    guard isModerator, !lobbyJoinRequested else { return }
    // Moderators sit in the lobby room too: that is how the room shows them
    // who is waiting, and the room hides everyone else from each other.
    lobbyJoinRequested = true
    try await connection.send(
      LobbyJoinPresence(
        lobbyRoomJID: lobby,
        nickname: configuration.nickname,
        displayName: configuration.displayName
      ).element()
    )
  }

  private func forgetLobby() {
    let wasEnabled = lobbyRoomJID != nil
    lobbyRoomJID = nil
    lobbyJoinRequested = false
    lobbyJoined = false
    if !lobbyOccupants.isEmpty {
      lobbyOccupants.removeAll()
      emit(.lobbyKnockersChanged([]))
    }
    if wasEnabled { emit(.lobbyEnabledChanged(false)) }
  }

  private func handleLobbyPresence(_ element: XMPPElement) {
    if let refusal = MUCJoinError(element: element) {
      // Leave room for another attempt on the next configuration change; a
      // lobby room that does not exist yet is the usual reason.
      lobbyJoinRequested = false
      emit(.warning(message: "Could not watch the meeting lobby: \(refusal.localizedDescription)"))
      return
    }
    guard let presence = try? MUCParticipantPresence(element: element) else { return }
    if presence.destroyed != nil {
      forgetLobby()
      return
    }
    if presence.isSelf {
      lobbyJoined = presence.isAvailable
      if !presence.isAvailable {
        lobbyJoinRequested = false
        if !lobbyOccupants.isEmpty {
          lobbyOccupants.removeAll()
          emit(.lobbyKnockersChanged([]))
        }
      }
      return
    }
    // Other moderators watch the lobby as well; only non-moderators are
    // waiting to be let in.
    let waiting = presence.isAvailable && !presence.isModerator
    let before = lobbyOccupants.mapValues(\.knocker)
    if waiting {
      let name = presence.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? presence.endpointID
      lobbyOccupants[presence.endpointID] = LobbyOccupant(
        knocker: LobbyKnocker(id: presence.endpointID, displayName: name),
        realJID: presence.realJID ?? lobbyOccupants[presence.endpointID]?.realJID
      )
    } else {
      lobbyOccupants.removeValue(forKey: presence.endpointID)
    }
    if lobbyOccupants.mapValues(\.knocker) != before {
      emit(.lobbyKnockersChanged(lobbyOccupants.values.map(\.knocker).sorted { $0.id < $1.id }))
    }
  }

  /// Sends an IQ and suspends until its answer comes through the receive
  /// loop. The continuation is registered before anything is sent, so an
  /// answer can never beat the registration.
  private func request(
    _ element: XMPPElement,
    id: String,
    timeout: Duration = .seconds(15)
  ) async throws -> XMPPElement {
    let connection = self.connection
    return try await withCheckedThrowingContinuation { continuation in
      pendingRequests[id] = continuation
      Task { [weak self] in
        do {
          try await connection.send(element)
        } catch {
          await self?.resolveRequest(id: id, with: .failure(error))
        }
      }
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.resolveRequest(
          id: id,
          with: .failure(NativeJingleCoordinatorError.requestTimedOut)
        )
      }
    }
  }

  private func resolveRequest(id: String, with result: Result<XMPPElement, any Error>) {
    guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
    continuation.resume(with: result)
  }

  private func failPendingRequests(with error: any Error) {
    let pending = pendingRequests
    pendingRequests.removeAll()
    for continuation in pending.values { continuation.resume(throwing: error) }
  }

  /// Rebuilds the peer connection so a replacement Jingle session can be
  /// answered from a clean slate.
  ///
  /// Must run inside the `negotiations` queue: it closes the connection the
  /// other negotiation entry points read and swaps in a new one, and the media
  /// loop is torn down and restarted on the new bridge's event stream. Local
  /// capture tracks are unaffected — `accept` re-attaches them to the new
  /// connection — so a running camera keeps producing frames across the reset.
  private func resetForNewSession() async throws {
    mediaTask?.cancel()
    mediaTask = nil
    await peerConnection.close()
    let bridge = PeerConnectionEventBridge()
    let native = try mediaFactory.makePeerConnection(policy: policy, delegate: bridge)
    eventBridge = bridge
    peerConnection = PeerConnectionNegotiator(connection: native)
    activeOffer = nil
    localICECredentials = nil
    pendingAcceptID = nil
    screenPublished = false
    pendingLocalCandidates.removeAll()
    remoteVideoSourceNames.removeAll()
    clearRemoteSourceState()
    await closeBridgeChannel()
    mediaTask = Task { [weak self] in await self?.runMediaLoop() }
  }

  /// Forgets everything known about the remote sources of a session that is
  /// being torn down or replaced — attribution, live tracks, SSRC routing,
  /// and the receive-slot numbering an SSRC-rewriting bridge restarts per
  /// session.
  private func clearRemoteSourceState() {
    videoSourceByTrackID.removeAll()
    remoteVideoTracks.removeAll()
    trackIDByVideoSSRC.removeAll()
    remoteAudioSSRCs.removeAll()
    videoSlotCount = 0
    audioSlotCount = 0
  }

  private func closeBridgeChannel() async {
    bridgeChannelEventsTask?.cancel()
    bridgeChannelEventsTask = nil
    await bridgeChannel?.close()
    bridgeChannel = nil
  }

  /// Whether a Jingle stanza came from Jicofo, the only initiator whose
  /// bridge session this client answers. The focus joins the room under the
  /// reserved nickname `focus`; every other occupant is a peer.
  private func isFocus(_ jid: String) -> Bool {
    XMPPJID.resource(jid) == "focus"
      && XMPPJID.matches(XMPPJID.bare(jid), configuration.roomJID)
  }

  /// Refuses a session this client will not run — a peer's peer-to-peer offer —
  /// with a Jingle `decline`. Best effort: failing to decline is harmless (the
  /// peer simply falls back to the bridge on its own), so it must never fault
  /// the receive loop that is handling our own bridge session.
  private func declineForeignSession(_ incoming: IncomingJingleIQ) async {
    let terminate = JingleIQBuilder().sessionTerminate(
      sessionID: incoming.session.sessionID,
      reason: "decline",
      initiator: incoming.session.initiator ?? incoming.sender,
      to: incoming.sender,
      from: configuration.responderJID,
      id: nextID(prefix: "decline")
    )
    try? await connection.send(terminate)
  }

  private func accept(_ incoming: IncomingJingleIQ) async throws {
    emit(.negotiating(sessionID: incoming.session.sessionID))
    activeOffer = incoming
    noteRemoteVideoSources(from: incoming.session)
    registerRemoteVideoSources(from: incoming.session)
    let offerSDP = try JingleSDPTranslator().offerSDP(from: incoming.session)
    var localVideoTracks: [LocalVideoTrack] = []
    if cameraStarted { localVideoTracks.append(cameraTrack.videoTrack) }
    if screenEnabled { localVideoTracks.append(screenVideoTrack) }
    let answerSDP = try await peerConnection.answer(
      remoteOfferSDP: offerSDP,
      localAudioTrack: audioTrack,
      localVideoTracks: localVideoTracks,
      streamID: configuration.streamID
    )
    let acceptID = nextID(prefix: "accept")
    let response = try JingleIQBuilder().sessionAccept(
      answerSDP: answerSDP,
      incoming: incoming,
      responder: configuration.responderJID,
      id: acceptID,
      sourceMetadataByMediaType: localSourceMetadata()
    )
    pendingAcceptID = acceptID
    // Captured before the accept goes out: candidates start trickling the
    // moment the local description is set, and each one must carry these.
    localICECredentials = ICECredentials(sdp: answerSDP)
    try await connection.send(response)
    // The session-accept carries our ICE ufrag/pwd, so the bridge can only use
    // trickled candidates after it. Flush the ones held during negotiation now.
    await flushPendingLocalCandidates()
    // The bridge's candidates ride inline in the session-initiate, but WebRTC
    // does not reliably ingest inline `a=candidate` lines from a remote offer —
    // the canonical path is `addIceCandidate`. Add them explicitly, or ICE has
    // no remote candidates to check against and sits in `checking` forever.
    try? await addRemoteCandidates(incoming.session)
    await openBridgeChannel(for: incoming.session)
    // A share armed while no session was live (or lost with the previous
    // session on a re-invite) is published as soon as media exists again.
    if screenEnabled, !screenPublished {
      do {
        try await performPublishScreen()
        await sendSourcePresence()
      } catch {
        emit(.warning(message: "Could not publish the armed screen share: \(error.localizedDescription)"))
      }
    }
    emit(.connected(sessionID: incoming.session.sessionID))
  }

  /// Opens the colibri bridge channel advertised in the session-initiate and
  /// asks the bridge to forward remote video. Best effort: a conference can
  /// exist without it, only without incoming video.
  private func openBridgeChannel(for session: JingleSessionDescription) async {
    await closeBridgeChannel()
    guard
      let urlString = session.contents.compactMap({ $0.transport?.bridgeWebSocketURL }).first,
      let url = URL(string: urlString)
    else {
      emit(.diagnostic(message: "bridge-channel: no colibri ws url in session-initiate"))
      return
    }
    // Events flow through one stream and one consumer so they apply in the
    // order the bridge sent them. A detached task per event would let two
    // source remaps land in either order, attributing tiles to the wrong
    // participants.
    let events = AsyncStream<BridgeChannelEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    let channel = BridgeChannel(url: url) { events.continuation.yield($0) }
    bridgeChannelEventsTask = Task { [weak self] in
      for await event in events.stream {
        guard !Task.isCancelled else { return }
        await self?.handleBridgeChannelEvent(event)
      }
    }
    bridgeChannel = channel
    await channel.open()
    emit(.diagnostic(message: "bridge-channel: opened \(url.host ?? urlString)"))
    await sendReceiverVideoConstraints()
  }

  /// Acts on the bridge's control messages and reports them as diagnostics —
  /// the bridge's own account of what it forwards to us and what it wants us
  /// to send is also the first place to look when media freezes.
  /// Internal so tests can inject bridge messages without a live socket.
  func handleBridgeChannelEvent(_ event: BridgeChannelEvent) async {
    switch event {
    case .closed(let reason):
      emit(.diagnostic(message: "bridge-channel: closed (\(reason))"))
    case .message(let message):
      switch message {
      case .forwardedSources(let sources):
        emit(.diagnostic(message: "bridge: forwarding [\(sources.joined(separator: ", "))]"))
      case .senderSourceConstraints(let sourceName, let maxHeight):
        emit(.diagnostic(message: "bridge: sender constraint \(sourceName) maxHeight=\(maxHeight)"))
        await applySenderConstraint(sourceName: sourceName, maxHeight: maxHeight)
      case .senderVideoConstraints(let idealHeight):
        emit(.diagnostic(message: "bridge: sender constraint idealHeight=\(idealHeight)"))
        await applySenderConstraint(
          sourceName: configuration.cameraSourceName,
          maxHeight: idealHeight
        )
      case .serverHello(let version):
        emit(.diagnostic(message: "bridge: hello version=\(version ?? "?")"))
      case .connectionStats(let bandwidth):
        emit(
          .diagnostic(
            message: "bridge: downlink bwe=\(bandwidth.map { String(Int($0)) } ?? "?") bps"))
      case .sourcesRemapped(let media, let sources):
        emit(
          .diagnostic(
            message: "bridge: \(media) sources remapped ["
              + sources.map { "\($0.sourceName)@\($0.ssrc)" }.joined(separator: ", ") + "]"))
        do {
          try await applySourceMap(media: media, sources: sources)
        } catch {
          // Without the remap applied the affected tiles keep decoding a
          // stale source, which is exactly the freeze this message prevents —
          // worth a warning, not just a diagnostic.
          emit(
            .warning(
              message: "Could not apply the bridge's \(media) source map: "
                + error.localizedDescription
            )
          )
        }
      case .dominantSpeaker(let endpointID):
        emit(.diagnostic(message: "bridge: dominant speaker \(endpointID ?? "none")"))
        emit(.dominantSpeakerChanged(endpointID: endpointID))
      case .lastNChanged(let current, _, _):
        emit(.diagnostic(message: "bridge: lastN endpoints [\(current.joined(separator: ", "))]"))
      case .endpointConnectivity(let endpointID, let active):
        emit(.diagnostic(message: "bridge: endpoint \(endpointID) active=\(active)"))
      case .sourceVideoType(let sourceName, let videoType):
        emit(.diagnostic(message: "bridge: source \(sourceName) videoType=\(videoType)"))
        for (trackID, info) in videoSourceByTrackID where info.name == sourceName {
          videoSourceByTrackID[trackID]?.videoType = videoType
        }
        emit(.remoteSourceVideoTypeChanged(sourceName: sourceName, videoType: videoType))
      case .endpointMessage(let from, _, let payload):
        // Reactions travel as endpoint messages with the well-known
        // "endpoint-reaction" payload; other endpoint messages are ignored.
        guard
          case .object(let fields)? = payload,
          case .string("endpoint-reaction")? = fields["name"],
          case .array(let values)? = fields["reactions"]
        else { break }
        let reactions = values.compactMap { value -> String? in
          if case .string(let name) = value { return name }
          return nil
        }
        guard !reactions.isEmpty else { break }
        emit(.reactionsReceived(endpointID: from, reactions: reactions))
      case .unknown(let type):
        emit(.diagnostic(message: "bridge: message \(type)"))
      }
    }
  }

  /// Applies the bridge's cap for one of our outgoing sources. Height 0 means
  /// no receiver wants the source — stop encoding it instead of uploading
  /// video nobody is shown; capture (and the self-preview) keeps running.
  private func applySenderConstraint(sourceName: String, maxHeight: Int) async {
    let trackID: String?
    switch sourceName {
    case configuration.cameraSourceName: trackID = cameraTrack.videoTrack.id
    case configuration.screenSourceName: trackID = screenVideoTrack.id
    default: trackID = nil
    }
    guard let trackID else { return }
    let active = Self.senderConstraintAllowsSending(maxHeight: maxHeight)
    emit(
      .diagnostic(
        message: "sender \(sourceName): \(active ? "resume" : "pause") encodings"
          + " (maxHeight=\(maxHeight))"))
    await peerConnection.setVideoSenderActive(trackID: trackID, active: active)
  }

  /// Whether a bridge sender constraint allows sending at all. The bridge
  /// sends 0 when no receiver wants the source, and a NEGATIVE height (-1)
  /// for "unconstrained" — the web client sets exactly that for a source it
  /// puts on stage, so treating -1 as a pause froze the very source everyone
  /// was watching after a single keyframe.
  static func senderConstraintAllowsSending(maxHeight: Int) -> Bool {
    maxHeight != 0
  }

  /// Applies an SSRC-rewriting bridge's source map (`VideoSourcesMap` /
  /// `AudioSourcesMap`), mirroring lib-jitsi-meet's
  /// `JingleSessionPC.processSourceMap`: the bridge forwards a fixed, small
  /// set of SSRCs and remaps which conference source each one carries. An
  /// SSRC seen for the first time gets a fresh receive slot in the remote
  /// description; a known SSRC only changes attribution — the same WebRTC
  /// track now shows a different participant, so the tile routing must
  /// follow or every remap freezes a tile on stale video.
  private func applySourceMap(media: String, sources: [MappedSource]) async throws {
    var newSources: [RTPSource] = []
    var newGroups: [RTPSourceGroup] = []
    for mapped in sources {
      // The bridge names owners by endpoint id; tolerate a full occupant JID.
      let owner = mapped.owner.map { XMPPJID.resource($0) ?? $0 }
      guard media == "video" else {
        // Audio drives no tile; a new SSRC only has to enter the remote
        // description so WebRTC decodes it at all.
        guard media == "audio", !remoteAudioSSRCs.contains(mapped.ssrc) else { continue }
        remoteAudioSSRCs.insert(mapped.ssrc)
        audioSlotCount += 1
        let slot = "remote-audio-\(audioSlotCount)"
        newSources.append(
          RTPSource(
            ssrc: mapped.ssrc,
            name: mapped.sourceName,
            parameters: slotParameters(slot: slot, mid: mapped.mid)
          )
        )
        emit(
          .diagnostic(
            message: "source-map: audio slot \(slot) <- \(mapped.sourceName)@\(mapped.ssrc)"))
        continue
      }
      let info = RemoteVideoSourceInfo(
        name: mapped.sourceName,
        owner: owner,
        videoType: mapped.videoType,
        isBridgePlaceholder: owner == "jvb" || mapped.sourceName.hasPrefix("jvb-")
      )
      if let trackID = trackIDByVideoSSRC[mapped.ssrc] {
        orphanStaleVideoSlots(named: mapped.sourceName, keeping: trackID)
        let current = videoSourceByTrackID[trackID]
        guard
          current?.name != info.name || current?.owner != info.owner
            || current?.videoType != info.videoType
        else { continue }
        videoSourceByTrackID[trackID] = info
        emit(
          .diagnostic(
            message: "source-map: \(trackID) -> \(mapped.sourceName)@\(mapped.ssrc) "
              + "owner=\(owner ?? "?")"))
        announceRemoteVideoTrack(id: trackID)
      } else {
        orphanStaleVideoSlots(named: mapped.sourceName, keeping: nil)
        videoSlotCount += 1
        let slot = "remote-video-\(videoSlotCount)"
        newSources.append(
          RTPSource(
            ssrc: mapped.ssrc,
            name: mapped.sourceName,
            videoType: mapped.videoType,
            parameters: slotParameters(slot: slot, mid: mapped.mid)
          )
        )
        if let rtx = mapped.rtxSSRC {
          newSources.append(
            RTPSource(
              ssrc: rtx,
              name: mapped.sourceName,
              parameters: slotParameters(slot: slot, mid: nil)
            )
          )
          newGroups.append(RTPSourceGroup(semantics: "FID", sources: [mapped.ssrc, rtx]))
          trackIDByVideoSSRC[rtx] = slot
        }
        trackIDByVideoSSRC[mapped.ssrc] = slot
        videoSourceByTrackID[slot] = info
        emit(
          .diagnostic(
            message: "source-map: video slot \(slot) <- \(mapped.sourceName)@\(mapped.ssrc)"))
      }
    }
    guard !newSources.isEmpty else { return }
    try await negotiations.run { [newSources, newGroups] in
      try await self.addRemoteSlots(media: media, sources: newSources, groups: newGroups)
    }
  }

  /// The parameters of a synthetic receive-slot source: lib-jitsi-meet's
  /// slot msid ("remote-video-1 remote-video-1"), whose track part becomes
  /// the WebRTC track id, plus the bridge-stamped mid when mid demuxing
  /// supplied one.
  private func slotParameters(slot: String, mid: String?) -> [String: String] {
    var parameters = ["msid": "\(slot) \(slot)"]
    if let mid { parameters["mid"] = mid }
    return parameters
  }

  /// A source that moved onto a new SSRC leaves its old track behind, still
  /// labeled with it and now decoding someone else's (or nobody's) video.
  /// The reference client clears that track's owner so the UI stops showing
  /// it; here the stale tile is withdrawn until the bridge remaps its SSRC
  /// to another source.
  private func orphanStaleVideoSlots(named sourceName: String, keeping trackID: String?) {
    for (staleID, info) in videoSourceByTrackID
    where staleID != trackID && info.name == sourceName {
      videoSourceByTrackID[staleID] = RemoteVideoSourceInfo(
        name: nil,
        owner: nil,
        videoType: info.videoType,
        isBridgePlaceholder: info.isBridgePlaceholder
      )
      emit(.remoteVideoTrackRemoved(id: staleID))
    }
  }

  /// Renegotiates the remote description with fresh receive slots for SSRCs
  /// the bridge just started forwarding, through the same source-add path a
  /// Jingle update takes. Runs inside the `negotiations` queue.
  private func addRemoteSlots(
    media: String,
    sources: [RTPSource],
    groups: [RTPSourceGroup]
  ) async throws {
    guard let activeOffer, let remoteSDP = await peerConnection.currentRemoteSDP() else {
      throw NativeJingleCoordinatorError.sessionNotReady
    }
    let update = JingleSessionDescription(
      action: .sourceAdd,
      sessionID: activeOffer.session.sessionID,
      initiator: nil,
      contents: [
        JingleContent(
          name: media,
          description: RTPDescription(media: media, sources: sources, sourceGroups: groups)
        )
      ]
    )
    let updated = try JitsiMultistreamSDP().applyingRemoteSourceUpdate(update, to: remoteSDP)
    _ = try await peerConnection.answerRenegotiation(remoteOfferSDP: updated)
  }

  /// Emits the current description of a live remote video track. Called both
  /// when WebRTC surfaces the track and when a source remap changes what it
  /// carries; the app replaces its copy by track id either way.
  private func announceRemoteVideoTrack(id trackID: String) {
    guard let track = remoteVideoTracks[trackID] else { return }
    let info = videoSourceByTrackID[trackID]
    emit(
      .remoteVideoTrackAdded(
        RemoteVideoStream(
          track: track,
          sourceName: info?.name,
          endpointID: info?.owner,
          videoType: info?.videoType,
          isBridgePlaceholder: info?.isBridgePlaceholder ?? track.id.contains("mixedlabel")
        )
      )
    )
  }

  /// Records the remote video source names carried by a session or source
  /// update, so receiver constraints can name them. Our own camera/screen
  /// sources are excluded — the bridge does not forward our video back to us.
  private func noteRemoteVideoSources(from session: JingleSessionDescription) {
    for name in remoteVideoSourceNames(in: session)
    where !remoteVideoSourceNames.contains(name) {
      remoteVideoSourceNames.append(name)
    }
  }

  /// Keeps the track-id → source map current, so the WebRTC track that later
  /// surfaces for a source can be attributed to its participant. The track id
  /// of a signaled remote source is the track part of its msid. The SSRC →
  /// track routing recorded alongside is what an SSRC-rewriting bridge's
  /// source maps consult, and the audio SSRC set keeps those maps from
  /// re-adding sources the description already has.
  /// Returns the track ids of video sources a source-remove retired, so the
  /// caller can announce their tracks as gone. WebRTC does not reliably fire
  /// a receiver-removed callback when the rejected media line tears down, and
  /// a share that ended would otherwise linger as a frozen tile.
  @discardableResult
  private func registerRemoteVideoSources(from session: JingleSessionDescription) -> [String] {
    var removedTrackIDs: [String] = []
    for content in session.contents {
      let media = content.description?.media
      guard media == "video" || media == "audio" else { continue }
      for source in content.description?.sources ?? [] {
        if media == "audio" {
          if session.action == .sourceRemove {
            remoteAudioSSRCs.remove(source.ssrc)
          } else {
            remoteAudioSSRCs.insert(source.ssrc)
          }
          continue
        }
        guard let msid = source.parameters["msid"] else { continue }
        let parts = msid.split(separator: " ")
        let trackID = parts.count == 2 ? String(parts[1]) : msid
        if session.action == .sourceRemove {
          // Announce the id the app's stream list actually holds: the RTC
          // track id when the track arrived, the signaled one otherwise.
          let announcedID = videoSourceByTrackID[trackID]?.rtcTrackID ?? trackID
          if let alias = videoSourceByTrackID[trackID]?.rtcTrackID {
            videoSourceByTrackID.removeValue(forKey: alias)
            remoteVideoTracks.removeValue(forKey: alias)
          }
          videoSourceByTrackID.removeValue(forKey: trackID)
          trackIDByVideoSSRC.removeValue(forKey: source.ssrc)
          if !removedTrackIDs.contains(announcedID) { removedTrackIDs.append(announcedID) }
          continue
        }
        let owner =
          source.owner.map { XMPPJID.resource($0) ?? $0 }
          ?? source.sourceName.flatMap(Self.endpointID(fromSourceName:))
        trackIDByVideoSSRC[source.ssrc] = trackID
        videoSourceByTrackID[trackID] = RemoteVideoSourceInfo(
          name: source.sourceName,
          owner: owner,
          videoType: source.videoType,
          isBridgePlaceholder: owner == "jvb" || msid.contains("mixedmslabel")
        )
      }
    }
    return removedTrackIDs
  }

  /// "abcd1234-v0" → "abcd1234"; the naming convention shared with the
  /// reference client (`getSourceNameForJitsiTrack`).
  private static func endpointID(fromSourceName name: String) -> String? {
    guard let dash = name.lastIndex(of: "-"), dash != name.startIndex else { return nil }
    return String(name[name.startIndex..<dash])
  }

  /// The remote (non-local) video source names carried by a session, in order.
  private func remoteVideoSourceNames(in session: JingleSessionDescription) -> [String] {
    let mine: Set<String> = [configuration.cameraSourceName, configuration.screenSourceName]
    return
      session.contents
      .filter { $0.description?.media == "video" }
      .flatMap { $0.description?.sources ?? [] }
      .compactMap(\.sourceName)
      .filter { !$0.isEmpty && !mine.contains($0) }
  }

  /// Tells the bridge how much remote video to forward, using the same message
  /// lib-jitsi-meet sends: `lastN` = -1 (every remote source) with a default
  /// per-source height cap. The bridge forwards every source subject to those,
  /// so no source has to be named — matching the reference client removes our
  /// dependence on enumerating remote source names, which we could not do
  /// reliably before a participant's real source was signalled.
  private func sendReceiverVideoConstraints() async {
    guard let bridgeChannel else {
      emit(.diagnostic(message: "recv-constraints: no bridge channel, skipped"))
      return
    }
    let constraints = ReceiverVideoConstraints(
      lastN: -1,
      assumedBandwidthBps: -1,
      defaultConstraints: VideoConstraint(maxHeight: preferredReceiveMaxHeight)
    )
    emit(
      .diagnostic(
        message: "recv-constraints: lastN=-1 defaultMaxHeight=\(preferredReceiveMaxHeight)"))
    try? await bridgeChannel.send(constraints)
  }

  /// The user's receive-quality preference (the web's performance slider):
  /// caps the height of every forwarded remote source. Re-sent immediately
  /// when the bridge channel is up, and used for every later constraint
  /// send.
  public func setPreferredReceiveMaxHeight(_ maxHeight: Int) async {
    preferredReceiveMaxHeight = maxHeight
    await sendReceiverVideoConstraints()
  }

  private func addRemoteCandidates(_ session: JingleSessionDescription) async throws {
    for content in session.contents {
      for candidate in content.transport?.candidates ?? [] {
        // One malformed or mistimed candidate must not abandon the rest, so a
        // single bad trickle cannot leave ICE with no remote candidates at all.
        do {
          var sdp = try JingleCandidateCodec.sdp(candidate, contentName: content.name)
          if sdp.hasPrefix("a=") { sdp.removeFirst(2) }
          // Everything is bundled onto one transport and the offer's media
          // lines are renumbered, so the jingle content names ("audio",
          // "video") no longer match any mid. Adding each candidate to the
          // first media line reaches the shared ICE agent.
          try await peerConnection.addRemoteCandidate(
            sdp: sdp,
            mid: nil,
            mediaLineIndex: 0
          )
        } catch {
          continue
        }
      }
    }
  }

  private func applyRemoteSourceUpdate(_ session: JingleSessionDescription) async throws {
    guard let remoteSDP = await peerConnection.currentRemoteSDP() else {
      throw NativeJingleCoordinatorError.sessionNotReady
    }
    // Register added sources BEFORE renegotiating: WebRTC surfaces the new
    // track during setRemoteDescription, and the actor yields there — the
    // track-added event must find the source in the registry or it goes
    // unattributed (an anonymous, never-staged tile).
    if session.action == .sourceAdd {
      registerRemoteVideoSources(from: session)
    }
    let updated = try JitsiMultistreamSDP().applyingRemoteSourceUpdate(session, to: remoteSDP)
    _ = try await peerConnection.answerRenegotiation(remoteOfferSDP: updated)
    // A newly published remote source needs the bridge to be re-told we want it.
    noteRemoteVideoSources(from: session)
    let removedTrackIDs =
      session.action == .sourceRemove ? registerRemoteVideoSources(from: session) : []
    // Announce removed sources' tracks ourselves: an ended share (or a
    // participant's retired camera) must leave the roster even when WebRTC
    // stays silent about the torn-down receiver.
    for trackID in removedTrackIDs {
      emit(.remoteVideoTrackRemoved(id: trackID))
    }
    await sendReceiverVideoConstraints()
  }

  /// Relays the camera track's device changes — attach/detach and failover
  /// after the active camera vanishes (a closed laptop lid, an unplugged
  /// dock) — so the app can refresh pickers and self-view state.
  private func runCameraLoop() async {
    for await event in cameraTrack.cameraEvents {
      guard !Task.isCancelled else { return }
      switch event {
      case .camerasChanged(let available, let currentDeviceID):
        emit(
          .diagnostic(
            message: "cameras: \(available.count) attached,"
              + " capturing=\(currentDeviceID ?? "none")"))
        emit(.camerasChanged(available: available, currentDeviceID: currentDeviceID))
      }
    }
  }

  private func runMediaLoop() async {
    for await event in eventBridge.events {
      guard !Task.isCancelled else { return }
      do {
        switch event {
        case .connectionStateChanged(let state):
          emit(.peerConnectionState(state))
        case .localCandidate(let candidate):
          try await send(candidate)
        case .remoteVideoTrackAdded(let track, let ssrc):
          remoteVideoTracks[track.id] = track
          // Attribute by SSRC: WebRTC keeps signaled msid track ids only for
          // the initial offer's media lines and synthesizes ids for lines
          // added by renegotiation — which is how every screen share
          // arrives. Alias the source description under the real track id so
          // every later lookup (announce, videoType change, removal) works.
          if let ssrc, let signaledTrackID = trackIDByVideoSSRC[ssrc],
            signaledTrackID != track.id,
            var info = videoSourceByTrackID[signaledTrackID]
          {
            info.rtcTrackID = track.id
            videoSourceByTrackID[signaledTrackID] = info
            videoSourceByTrackID[track.id] = info
          }
          announceRemoteVideoTrack(id: track.id)
        case .remoteVideoTrackRemoved(let id):
          remoteVideoTracks.removeValue(forKey: id)
          emit(.remoteVideoTrackRemoved(id: id))
        case .negotiationNeeded:
          break
        }
      } catch {
        emit(.failed(message: error.localizedDescription))
      }
    }
  }

  private func send(_ candidate: NativeICECandidate) async throws {
    guard let activeOffer else { return }
    guard let credentials = localICECredentials else {
      // No credentials yet: hold the candidate rather than dropping it, so the
      // bridge still receives every local candidate once `accept` flushes them.
      pendingLocalCandidates.append(candidate)
      return
    }
    // The reference client names a trickled candidate's content by the
    // candidate's own sdpMid; the offer's media identifiers are the media-line
    // indices, so the index is the fallback.
    let mid = candidate.mid ?? String(candidate.mediaLineIndex)
    let iq = try JingleIQBuilder().transportInfo(
      sessionID: activeOffer.session.sessionID,
      candidateSDP: candidate.sdp,
      mid: mid,
      credentials: credentials,
      initiator: activeOffer.session.initiator ?? activeOffer.sender,
      to: activeOffer.sender,
      from: configuration.responderJID,
      id: nextID(prefix: "candidate")
    )
    try await connection.send(iq)
  }

  /// Sends every candidate that gathered before our ICE credentials were known.
  private func flushPendingLocalCandidates() async {
    guard localICECredentials != nil, !pendingLocalCandidates.isEmpty else { return }
    let pending = pendingLocalCandidates
    pendingLocalCandidates.removeAll()
    for candidate in pending {
      do { try await send(candidate) } catch { break }
    }
  }

  /// The name and video type for the local sources the session-accept
  /// describes, keyed by media type the way the accept's contents are named.
  /// The camera track binds the video line whenever it is running; only a
  /// screen-share-without-camera session accepts with the desktop source.
  private func localSourceMetadata() -> [String: LocalSourceMetadata] {
    var result = ["audio": LocalSourceMetadata(name: configuration.audioSourceName)]
    result["video"] =
      !cameraStarted && screenEnabled
      ? LocalSourceMetadata(name: configuration.screenSourceName, videoType: "desktop")
      : LocalSourceMetadata(name: configuration.cameraSourceName, videoType: "camera")
    return result
  }

  private func nextID(prefix: String) -> String {
    outgoingSequence &+= 1
    return "sangam-\(prefix)-\(outgoingSequence)"
  }

  private func sendSourcePresence() async {
    var sources: [String: LocalSourcePresence] = [
      configuration.audioSourceName: LocalSourcePresence(muted: microphoneMuted),
      configuration.cameraSourceName: LocalSourcePresence(
        muted: !cameraEnabled,
        videoType: "camera"
      ),
    ]
    if screenPublished {
      sources[configuration.screenSourceName] = LocalSourcePresence(
        muted: !screenEnabled,
        videoType: "desktop"
      )
    }
    do {
      try await connection.send(
        SourceInfoPresenceUpdate(
          occupantJID: configuration.occupantJID,
          audioMuted: microphoneMuted,
          videoMuted: !cameraEnabled,
          sources: sources,
          displayName: configuration.displayName,
          raisedHandTimestamp: raisedHandTimestamp
        ).element()
      )
    } catch {
      emit(
        .warning(
          message: "Could not update conference source presence: \(error.localizedDescription)"))
    }
  }

  private func emit(_ event: NativeJingleEvent) {
    continuation.yield(event)
  }
}

public enum NativeJingleCoordinatorError: Error, Equatable, Sendable {
  case sessionNotReady
  case requestTimedOut
  case notModerator
  case unknownLobbyParticipant
  /// The room did not disclose the participant's address, which the
  /// invitation needs; only moderators are shown it.
  case lobbyParticipantAddressUnknown
  case unknownParticipant
  /// The room did not disclose the participant's real address, which an
  /// affiliation change needs.
  case participantAddressUnknown
  /// The deployment announces no AV moderation component.
  case avModerationUnavailable
  /// The deployment announces no breakout-rooms component.
  case breakoutRoomsUnavailable
  /// The deployment announces no polls component.
  case pollsUnavailable
  /// The room's service does not offer the requested configuration field.
  case roomConfigurationUnsupported
}

extension NativeJingleCoordinatorError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .sessionNotReady: return "The media session is not ready yet."
    case .requestTimedOut: return "The meeting server did not answer in time."
    case .notModerator: return "Only a meeting host can do that."
    case .unknownLobbyParticipant: return "That person is no longer waiting in the lobby."
    case .lobbyParticipantAddressUnknown:
      return "The meeting did not say who is waiting, so they cannot be admitted."
    case .unknownParticipant:
      return "That person is no longer in the meeting."
    case .participantAddressUnknown:
      return "The meeting did not disclose that person's address, so they cannot be promoted."
    case .avModerationUnavailable:
      return "This meeting server does not offer moderation controls."
    case .breakoutRoomsUnavailable:
      return "This meeting server does not offer breakout rooms."
    case .pollsUnavailable:
      return "This meeting server does not offer polls."
    case .roomConfigurationUnsupported:
      return "This meeting server does not offer that room setting."
    }
  }
}

/// Marks a signaling failure that leaves the conference unusable, so the
/// receive loop can tell it apart from a single stanza it could not process.
private struct FatalSignalingError: Error {
  let underlying: any Error
}
