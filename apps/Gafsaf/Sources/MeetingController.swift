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
    case switchCamera
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

  @Published private(set) var connectionState: ConnectionState = .connecting {
    didSet {
      if connectionState != oldValue {
        GafsafLog.event("connectionState \(oldValue) -> \(connectionState)")
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

  private var commandHandler: ((Command) -> Void)?
  private var pendingCommands: [Command] = []

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

  /// Called by the meeting surface when a chat message arrives while the
  /// panel is closed, so the chat button can show how much was missed.
  func noteUnreadChatMessage() {
    guard !isChatOpen else { return }
    unreadChatCount += 1
  }

  func switchCamera() {
    send(.switchCamera)
  }

  func hangUp() {
    send(.hangUp)
  }

  func didJoin() {
    connectionState = .joined
    errorMessage = nil
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
    case .sendChatMessage, .sendReaction, .kickParticipant, .grantModerator, .switchCamera,
      .authenticate, .waitForHost, .cancelWaiting, .admitLobbyParticipant, .denyLobbyParticipant,
      .hangUp:
      break
    }

    if let commandHandler {
      commandHandler(command)
    } else {
      pendingCommands.append(command)
    }
  }
}

/// Opt-in diagnostic log for bring-up. Silent unless `GAFSAF_LOG` is set in the
/// process environment, so release builds stay quiet by default. It records
/// lifecycle events and error text only — never XMPP, SDP, or media payloads —
/// which keeps it within the architecture's "no protocol payload logging"
/// rule while still showing the sequence of events that led somewhere.
enum GafsafLog {
  nonisolated static let isEnabled =
    ProcessInfo.processInfo.environment["GAFSAF_LOG"].map { !$0.isEmpty && $0 != "0" } ?? false

  nonisolated static func event(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    FileHandle.standardError.write(Data("[gafsaf \(timestamp())] \(message())\n".utf8))
  }

  nonisolated private static func timestamp() -> String {
    let now = Calendar.current.dateComponents(
      [.hour, .minute, .second, .nanosecond], from: Date())
    return String(
      format: "%02d:%02d:%02d.%03d",
      now.hour ?? 0, now.minute ?? 0, now.second ?? 0, (now.nanosecond ?? 0) / 1_000_000)
  }
}
