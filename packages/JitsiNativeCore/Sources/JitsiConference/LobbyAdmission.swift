import Foundation
import JitsiXMPP

/// How a wait in the lobby ended.
public enum LobbyAdmissionOutcome: Equatable, Sendable {
  /// A moderator let the client in; the meeting room can be joined now.
  case admitted(password: String?)
  /// The lobby was switched off while the client waited, so the meeting room
  /// can be joined directly.
  case lobbyDisabled
  /// The lobby was torn down without pointing anywhere, which only happens
  /// when the meeting itself ended.
  case meetingEnded(reason: String?)
}

public enum LobbyAdmissionError: Error, Equatable, Sendable {
  /// A moderator refused the request to join.
  case accessDenied
  case removedFromLobby
}

extension LobbyAdmissionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .accessDenied: return "The host did not admit you to the meeting."
    case .removedFromLobby: return "You were removed from the meeting's lobby."
    }
  }
}

/// Waits in a Jitsi lobby room until a moderator decides.
///
/// Mirrors lib-jitsi-meet's `Lobby`: the client joins the lobby MUC under the
/// nickname it will use in the meeting, then watches its own stream for one of
/// three signals — a mediated invitation from the meeting room (admitted), a
/// kick from the lobby (denied), or the lobby's destruction (switched off, or
/// the meeting ended). Nothing else arrives while waiting except the server's
/// capability probes, which are answered so the session stays alive.
public struct LobbyAdmission: Sendable {
  public var connection: XMPPConnection
  public var lobbyRoomJID: String
  public var meetingRoomJID: String
  public var nickname: String
  public var displayName: String
  public var capabilities: XMPPClientCapabilities

  public var lobbyOccupantJID: String { "\(lobbyRoomJID)/\(nickname)" }

  public init(
    connection: XMPPConnection,
    lobbyRoomJID: String,
    meetingRoomJID: String,
    nickname: String,
    displayName: String,
    capabilities: XMPPClientCapabilities = .jitsiNative
  ) {
    self.connection = connection
    self.lobbyRoomJID = lobbyRoomJID
    self.meetingRoomJID = meetingRoomJID
    self.nickname = nickname
    self.displayName = displayName
    self.capabilities = capabilities
  }

  /// Enters the lobby and suspends until a moderator decides, the lobby goes
  /// away, or the task is cancelled.
  ///
  /// Cancellation closes the connection: the read this wait is parked in does
  /// not observe cancellation by itself, and closing the stream is also what
  /// removes the client from the lobby so moderators stop seeing a ghost.
  public func wait() async throws -> LobbyAdmissionOutcome {
    let connection = self.connection
    return try await withTaskCancellationHandler {
      do {
        return try await run()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      Task { await connection.disconnect() }
    }
  }

  /// Leaves the lobby room once the outcome no longer needs it.
  public func leave() async {
    try? await connection.send(MUCLeavePresence(occupantJID: lobbyOccupantJID).element())
  }

  private func run() async throws -> LobbyAdmissionOutcome {
    _ = try await connection.joinMUC(
      LobbyJoinPresence(lobbyRoomJID: lobbyRoomJID, nickname: nickname, displayName: displayName)
    )
    while true {
      try Task.checkCancellation()
      let element = try await connection.nextElement()
      if let response = capabilities.response(to: element) {
        try await connection.send(response)
        continue
      }
      if let invitation = MUCInvitation(element: element) {
        if XMPPJID.matches(invitation.roomJID, meetingRoomJID) {
          return .admitted(password: invitation.password)
        }
        continue
      }
      guard
        element.name == "presence",
        let from = element[attribute: "from"],
        XMPPJID.matches(XMPPJID.bare(from), lobbyRoomJID),
        let presence = try? MUCParticipantPresence(element: element)
      else { continue }
      if let destroyed = presence.destroyed {
        return destroyed.alternateRoomJID == nil
          ? .meetingEnded(reason: destroyed.reason)
          : .lobbyDisabled
      }
      guard presence.isSelf, !presence.isAvailable else { continue }
      throw presence.wasKicked
        ? LobbyAdmissionError.accessDenied
        : LobbyAdmissionError.removedFromLobby
    }
  }
}
