import Combine
import Foundation

@MainActor
final class MeetingController: ObservableObject {
  enum Command: Sendable {
    case setAudioMuted(Bool)
    case setVideoMuted(Bool)
    case setScreenSharing(Bool)
    case setHandRaised(Bool)
    case sendChatMessage(String)
    case sendReaction(String)
    case kickParticipant(id: String)
    case grantModerator(id: String)
    case muteParticipant(id: String)
    case setReceiveQuality(maxHeight: Int)
    case setAudioModeration(enabled: Bool)
    case allowToSpeak(id: String)
    case setBackgroundBlur(enabled: Bool)
    case togglePictureInPicture
    case createBreakoutRoom(subject: String)
    case removeBreakoutRoom(jid: String)
    case joinBreakoutRoom(jid: String)
    case sendParticipantToBreakoutRoom(id: String, roomJID: String)
    case switchCamera(deviceID: String)
    case authenticate(username: String, password: String)
    case waitForHost
    case cancelWaiting
    case admitLobbyParticipant(id: String)
    case denyLobbyParticipant(id: String)
    case hangUp
  }

  enum ConnectionState: Equatable {
    case connecting
    case joined
    case accessRequired
    case waitingForHost
    /// The meeting has a lobby; a host has to let us in.
    case waitingInLobby
    case failed
    case ended
  }

  /// Someone waiting in the meeting's lobby, shown to hosts with admit and
  /// deny controls.
  struct LobbyRequest: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
  }

  /// A camera the user can pick from the video button's context menu.
  struct CameraOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
  }

  /// One room in the breakout roster (including the main room), for the
  /// Breakout Rooms menu.
  struct BreakoutRoomOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isMainRoom: Bool
    let participantCount: Int
  }

  @Published private(set) var connectionState: ConnectionState = .connecting {
    didSet {
      if connectionState != oldValue {
        SangamLog.event("connectionState \(oldValue) -> \(connectionState)")
      }
    }
  }
  @Published private(set) var isAudioMuted = false
  @Published private(set) var isVideoMuted = false
  @Published private(set) var isScreenSharing = false
  @Published private(set) var isHandRaised = false
  @Published var isChatOpen = false {
    didSet { if isChatOpen { unreadChatCount = 0 } }
  }
  @Published private(set) var unreadChatCount = 0
  /// The default layout is a collapsible sidebar of video sources (self on
  /// top) beside a stage featuring the pinned or dominant speaker; this
  /// switches to the equal-tile grid instead.
  @Published var usesTileGrid = false
  @Published var errorMessage: String?
  @Published private(set) var accessMessage: String?
  /// Whether the lobby wait ends when a host arrives rather than when one
  /// decides; changes the wording of the waiting card.
  @Published private(set) var lobbyWaitsForHost = false
  @Published private(set) var lobbyRequests: [LobbyRequest] = []
  @Published private(set) var cameras: [CameraOption] = []
  /// The camera currently capturing; nil when none is (every camera gone).
  @Published private(set) var currentCameraID: String?
  /// The address other people join with, for the invite button.
  @Published private(set) var meetingLink: URL?
  /// Whether this client moderates the room; gates the moderation controls.
  @Published private(set) var isModerator = false
  /// Room-wide audio moderation: while on, participants need approval to
  /// unmute.
  @Published private(set) var audioModerationOn = false
  /// How much of the window's left edge the floating sidebar occupies, so
  /// the toolbar can center itself over the visible stage.
  @Published private(set) var sidebarInset: CGFloat = 0
  /// The iOS settings pane; macOS uses the Settings window instead.
  @Published var showsSettingsPane = false
  /// System Picture in Picture: availability and whether it is up.
  @Published private(set) var pipAvailable = false
  @Published private(set) var isPiPActive = false
  /// The deployment's breakout-room roster; empty when none exist (or the
  /// server runs no component).
  @Published private(set) var breakoutRooms: [BreakoutRoomOption] = []

  private var commandHandler: ((Command) -> Void)?
  private var pendingCommands: [Command] = []
  private let settings = AppSettings.shared
  private var settingsObservers: Set<AnyCancellable> = []

  init() {
    // Preferences apply live: a change in the Settings window (or the More
    // menu, which edits the same object) reaches the running meeting.
    settings.$receiveQuality
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] height in self?.send(.setReceiveQuality(maxHeight: height)) }
      .store(in: &settingsObservers)
    settings.$backgroundBlur
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] enabled in self?.send(.setBackgroundBlur(enabled: enabled)) }
      .store(in: &settingsObservers)
  }

  func attach(commandHandler: @escaping (Command) -> Void) {
    self.commandHandler = commandHandler
    let commands = pendingCommands
    pendingCommands.removeAll()
    commands.forEach(commandHandler)
  }

  func detach() {
    commandHandler = nil
  }

  func toggleAudio() {
    send(.setAudioMuted(!isAudioMuted))
  }

  func toggleVideo() {
    send(.setVideoMuted(!isVideoMuted))
  }

  func toggleScreenSharing() {
    send(.setScreenSharing(!isScreenSharing))
  }

  func toggleHandRaised() {
    send(.setHandRaised(!isHandRaised))
  }

  func toggleChat() {
    isChatOpen.toggle()
  }

  func toggleLayout() {
    usesTileGrid.toggle()
  }

  func sendChatMessage(_ text: String) {
    send(.sendChatMessage(text))
  }

  func sendReaction(_ name: String) {
    send(.sendReaction(name))
  }

  func kickParticipant(_ id: String) {
    send(.kickParticipant(id: id))
  }

  func grantModerator(_ id: String) {
    send(.grantModerator(id: id))
  }

  func muteParticipant(_ id: String) {
    send(.muteParticipant(id: id))
  }

  /// Called by the meeting surface when a chat message arrives while the
  /// panel is closed, so the chat button can show how much was missed.
  func noteUnreadChatMessage() {
    guard !isChatOpen else { return }
    unreadChatCount += 1
  }

  func selectCamera(id: String) {
    guard id != currentCameraID else { return }
    send(.switchCamera(deviceID: id))
  }

  /// Cycles to the next attached camera — the iOS toolbar's front/back flip.
  func flipCamera() {
    guard cameras.count > 1 else { return }
    let index = cameras.firstIndex { $0.id == currentCameraID } ?? 0
    send(.switchCamera(deviceID: cameras[(index + 1) % cameras.count].id))
  }

  func didChangeCameras(_ cameras: [CameraOption], currentID: String?) {
    self.cameras = cameras
    currentCameraID = currentID
  }

  func didSetMeetingLink(_ link: URL) {
    meetingLink = link
  }

  func setAudioModeration(_ enabled: Bool) {
    audioModerationOn = enabled
    send(.setAudioModeration(enabled: enabled))
  }

  func allowToSpeak(_ id: String) {
    send(.allowToSpeak(id: id))
  }

  func didChangeAudioModeration(_ enabled: Bool) {
    audioModerationOn = enabled
  }

  func didChangeModeratorStatus(_ moderator: Bool) {
    isModerator = moderator
  }

  func didChangeSidebarInset(_ inset: CGFloat) {
    sidebarInset = inset
  }

  func togglePictureInPicture() {
    send(.togglePictureInPicture)
  }

  func didChangePictureInPicture(available: Bool, active: Bool) {
    pipAvailable = available
    isPiPActive = active
  }

  func createBreakoutRoom() {
    let count = breakoutRooms.filter { !$0.isMainRoom }.count
    send(.createBreakoutRoom(subject: "Room \(count + 1)"))
  }

  func removeBreakoutRoom(_ jid: String) {
    send(.removeBreakoutRoom(jid: jid))
  }

  func joinBreakoutRoom(_ jid: String) {
    send(.joinBreakoutRoom(jid: jid))
  }

  func sendParticipantToBreakoutRoom(_ id: String, roomJID: String) {
    send(.sendParticipantToBreakoutRoom(id: id, roomJID: roomJID))
  }

  func didChangeBreakoutRooms(_ rooms: [BreakoutRoomOption]) {
    breakoutRooms = rooms
  }

  /// A breakout-room move rejoins from scratch; the meeting view shows the
  /// connecting state until the new room is up.
  func didStartSwitchingRooms() {
    connectionState = .connecting
    errorMessage = nil
  }

  func hangUp() {
    send(.hangUp)
  }

  func didJoin() {
    connectionState = .joined
    errorMessage = nil
    // Bring the fresh conference in line with the stored preferences.
    if settings.receiveQuality != 720 {
      send(.setReceiveQuality(maxHeight: settings.receiveQuality))
    }
    if settings.backgroundBlur {
      send(.setBackgroundBlur(enabled: true))
    }
  }

  func requireAccess(message: String? = nil) {
    connectionState = .accessRequired
    accessMessage = message
    errorMessage = nil
  }

  func authenticate(username: String, password: String) {
    connectionState = .connecting
    accessMessage = nil
    send(.authenticate(username: username, password: password))
  }

  func waitForHost() {
    connectionState = .waitingForHost
    accessMessage = nil
    send(.waitForHost)
  }

  func cancelWaiting() {
    connectionState = .accessRequired
    send(.cancelWaiting)
  }

  func didEnterLobby(waitingForHost: Bool) {
    connectionState = .waitingInLobby
    lobbyWaitsForHost = waitingForHost
    accessMessage = nil
    errorMessage = nil
  }

  func didChangeLobbyRequests(_ requests: [LobbyRequest]) {
    lobbyRequests = requests
  }

  func admitLobbyParticipant(_ id: String) {
    send(.admitLobbyParticipant(id: id))
  }

  func denyLobbyParticipant(_ id: String) {
    send(.denyLobbyParticipant(id: id))
  }

  func didEnd(error: String? = nil) {
    errorMessage = error
    // A clean end returns to the join screen. A failure must not: routing it
    // through `.ended` dismisses the meeting view (MeetingView dismisses on
    // `.ended`) in the same runloop turn the error alert would appear, so the
    // alert is torn down with the view and the user is dropped back to the
    // join screen with nothing explaining why. `.failed` keeps the view up and
    // shows the message with a Back button.
    connectionState = error == nil ? .ended : .failed
  }

  func didFailToJoin(error: String) {
    connectionState = .failed
    errorMessage = error
  }

  func didChangeAudioMuted(_ muted: Bool) {
    isAudioMuted = muted
  }

  func didChangeVideoMuted(_ muted: Bool) {
    isVideoMuted = muted
  }

  func didChangeScreenSharing(_ sharing: Bool) {
    isScreenSharing = sharing
  }

  func report(error: String) {
    errorMessage = error
  }

  private func send(_ command: Command) {
    switch command {
    case .setAudioMuted(let muted):
      isAudioMuted = muted
    case .setVideoMuted(let muted):
      isVideoMuted = muted
    case .setScreenSharing(let sharing):
      isScreenSharing = sharing
    case .setHandRaised(let raised):
      isHandRaised = raised
    case .sendChatMessage, .sendReaction, .kickParticipant, .grantModerator, .muteParticipant,
      .setReceiveQuality, .setAudioModeration, .allowToSpeak, .setBackgroundBlur,
      .togglePictureInPicture, .createBreakoutRoom, .removeBreakoutRoom, .joinBreakoutRoom,
      .sendParticipantToBreakoutRoom, .switchCamera, .authenticate, .waitForHost,
      .cancelWaiting, .admitLobbyParticipant, .denyLobbyParticipant, .hangUp:
      break
    }

    if let commandHandler {
      commandHandler(command)
    } else {
      pendingCommands.append(command)
    }
  }
}

/// Opt-in diagnostic log for bring-up. Silent unless `SANGAM_LOG` is set in the
/// process environment, so release builds stay quiet by default. It records
/// lifecycle events and error text only — never XMPP, SDP, or media payloads —
/// which keeps it within the architecture's "no protocol payload logging"
/// rule while still showing the sequence of events that led somewhere.
enum SangamLog {
  nonisolated static let isEnabled =
    ProcessInfo.processInfo.environment["SANGAM_LOG"].map { !$0.isEmpty && $0 != "0" } ?? false

  nonisolated static func event(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    FileHandle.standardError.write(Data("[sangam \(timestamp())] \(message())\n".utf8))
  }

  nonisolated private static func timestamp() -> String {
    let now = Calendar.current.dateComponents(
      [.hour, .minute, .second, .nanosecond], from: Date())
    return String(
      format: "%02d:%02d:%02d.%03d",
      now.hour ?? 0, now.minute ?? 0, now.second ?? 0, (now.nanosecond ?? 0) / 1_000_000)
  }
}
