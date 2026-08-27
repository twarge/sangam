import Foundation

/// Stanzas for Jitsi's lobby ("waiting room"), as implemented by Prosody's
/// `mod_muc_lobby_rooms`.
///
/// A meeting room with the lobby switched on is a members-only MUC. Anyone
/// else who tries to join is turned away with the address of a paired lobby
/// room, waits there, and is let in when a moderator sends the meeting room a
/// mediated invitation for them (which grants them membership), or turned
/// away for good when a moderator kicks them out of the lobby.

/// Presence that enters a lobby room, either to wait in it or — for a
/// moderator — to watch who is waiting.
public struct LobbyJoinPresence: Equatable, Sendable, MUCJoinPresence {
  /// The lobby room's address.
  public var roomJID: String
  public var nickname: String
  public var displayName: String

  public var occupantJID: String { "\(roomJID)/\(nickname)" }

  public init(lobbyRoomJID: String, nickname: String, displayName: String) {
    roomJID = lobbyRoomJID
    self.nickname = nickname
    self.displayName = displayName
  }

  public func element() -> XMPPElement {
    var children = [XMPPElement(name: "x", namespace: MUCNamespace.muc)]
    if !displayName.isEmpty {
      children.append(XMPPElement(name: "nick", namespace: MUCNamespace.nick, text: displayName))
    }
    return XMPPElement(name: "presence", attributes: ["to": occupantJID], children: children)
  }
}

/// A mediated invitation (XEP-0045 §7.8.2). Sending one to a members-only
/// room as its owner makes the invitees members, which is how a Jitsi
/// moderator admits people from the lobby.
public struct MUCInviteMessage: Equatable, Sendable {
  public var roomJID: String
  public var inviteeJIDs: [String]

  public init(roomJID: String, inviteeJIDs: [String]) {
    self.roomJID = roomJID
    self.inviteeJIDs = inviteeJIDs
  }

  public func element() -> XMPPElement {
    XMPPElement(
      name: "message",
      attributes: ["to": roomJID],
      children: [
        XMPPElement(
          name: "x",
          namespace: MUCNamespace.user,
          children: inviteeJIDs.map { XMPPElement(name: "invite", attributes: ["to": $0]) }
        )
      ]
    )
  }
}

/// An invitation the room forwarded to this client.
public struct MUCInvitation: Equatable, Sendable {
  public var roomJID: String
  public var inviterJID: String?
  public var reason: String?
  public var password: String?

  /// Returns `nil` unless `element` is a message carrying a MUC invitation.
  public init?(element: XMPPElement) {
    guard
      element.name == "message",
      let from = element[attribute: "from"],
      let user = element.child(named: "x", namespace: MUCNamespace.user),
      let invite = user.child(named: "invite")
    else { return nil }
    roomJID = XMPPJID.bare(from)
    inviterJID = invite[attribute: "from"]
    reason = Self.nonEmpty(invite.child(named: "reason")?.text)
    password = Self.nonEmpty(user.child(named: "password")?.text)
  }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
  }
}

/// Removes an occupant from a room (XEP-0045 §8.2). Kicking someone out of
/// the lobby is how a Jitsi moderator refuses them entry.
public struct MUCKickRequest: Equatable, Sendable {
  public var id: String
  public var roomJID: String
  public var nickname: String
  public var reason: String?

  public init(id: String, roomJID: String, nickname: String, reason: String? = nil) {
    self.id = id
    self.roomJID = roomJID
    self.nickname = nickname
    self.reason = reason
  }

  public func element() -> XMPPElement {
    var item = XMPPElement(name: "item", attributes: ["nick": nickname, "role": "none"])
    if let reason, !reason.isEmpty {
      item.children = [XMPPElement(name: "reason", text: reason)]
    }
    return XMPPElement(
      name: "iq",
      attributes: ["id": id, "to": roomJID, "type": "set"],
      children: [XMPPElement(name: "query", namespace: MUCNamespace.admin, children: [item])]
    )
  }
}

/// Asks Jicofo to mute an occupant — Jitsi's remote-mute moderation. The IQ
/// goes to the focus occupant of the room; the target is named by full
/// occupant JID and the media by the mute element's namespace. The protocol
/// deliberately has no remote unmute: people unmute themselves.
public struct JitsiMuteRequest: Equatable, Sendable {
  public var id: String
  public var roomJID: String
  public var targetNickname: String
  /// "audio" or "video", selecting the namespace exactly as the reference
  /// client does.
  public var media: String

  public init(id: String, roomJID: String, targetNickname: String, media: String) {
    self.id = id
    self.roomJID = roomJID
    self.targetNickname = targetNickname
    self.media = media
  }

  public func element() -> XMPPElement {
    XMPPElement(
      name: "iq",
      attributes: ["id": id, "to": "\(roomJID)/focus", "type": "set"],
      children: [
        XMPPElement(
          name: "mute",
          namespace: "http://jitsi.org/jitmeet/\(media)",
          attributes: ["jid": "\(roomJID)/\(targetNickname)"],
          text: "true"
        )
      ]
    )
  }
}

/// Changes an occupant's affiliation (XEP-0045 §10.3). Jitsi's "grant
/// moderator" makes the target an owner, addressed by real JID — which the
/// room only discloses to moderators.
public struct MUCAffiliationRequest: Equatable, Sendable {
  public var id: String
  public var roomJID: String
  public var jid: String
  public var affiliation: String

  public init(id: String, roomJID: String, jid: String, affiliation: String) {
    self.id = id
    self.roomJID = roomJID
    self.jid = jid
    self.affiliation = affiliation
  }

  public func element() -> XMPPElement {
    XMPPElement(
      name: "iq",
      attributes: ["id": id, "to": roomJID, "type": "set"],
      children: [
        XMPPElement(
          name: "query",
          namespace: MUCNamespace.admin,
          children: [
            XMPPElement(name: "item", attributes: ["affiliation": affiliation, "jid": jid])
          ]
        )
      ]
    )
  }
}

/// Asks a room about itself (XEP-0045 §6.4). Jitsi adds the lobby room's
/// address to the answer while the lobby is on.
public struct MUCRoomInfoRequest: Equatable, Sendable {
  public var id: String
  public var roomJID: String

  public init(id: String, roomJID: String) {
    self.id = id
    self.roomJID = roomJID
  }

  public func element() -> XMPPElement {
    XMPPElement(
      name: "iq",
      attributes: ["id": id, "to": roomJID, "type": "get"],
      children: [
        XMPPElement(name: "query", namespace: XMPPClientCapabilities.discoInfoNamespace)
      ]
    )
  }
}

public struct MUCRoomInfo: Equatable, Sendable {
  public static let dataFormsNamespace = "jabber:x:data"

  public var isMembersOnly: Bool
  public var isPasswordProtected: Bool
  /// Present only while the lobby is switched on.
  public var lobbyRoomJID: String?
  public var meetingID: String?

  /// The lobby room to watch or wait in, or `nil` when the lobby is off.
  public var activeLobbyRoomJID: String? { isMembersOnly ? lobbyRoomJID : nil }

  public init(
    isMembersOnly: Bool,
    isPasswordProtected: Bool = false,
    lobbyRoomJID: String? = nil,
    meetingID: String? = nil
  ) {
    self.isMembersOnly = isMembersOnly
    self.isPasswordProtected = isPasswordProtected
    self.lobbyRoomJID = lobbyRoomJID
    self.meetingID = meetingID
  }

  public init(element: XMPPElement) throws {
    guard
      element.name == "iq",
      element[attribute: "type"] == "result",
      let query = element.child(
        named: "query",
        namespace: XMPPClientCapabilities.discoInfoNamespace
      )
    else { throw MUCRoomInfoError.invalidResponse }

    let features = Set(query.children(named: "feature").compactMap { $0[attribute: "var"] })
    isMembersOnly = features.contains("muc_membersonly")
    isPasswordProtected = features.contains("muc_passwordprotected")

    let fields = query.children(named: "x", namespace: Self.dataFormsNamespace)
      .flatMap { $0.children(named: "field") }
    func value(_ name: String) -> String? {
      let text = fields.first { $0[attribute: "var"] == name }?.child(named: "value")?.text
      guard let text, !text.isEmpty else { return nil }
      return text
    }
    lobbyRoomJID = value("muc#roominfo_lobbyroom")
    meetingID = value("muc#roominfo_meetingId")
  }
}

public enum MUCRoomInfoError: Error, Equatable, Sendable {
  case invalidResponse
}

extension MUCRoomInfoError: LocalizedError {
  public var errorDescription: String? {
    "The meeting room returned an invalid description of itself."
  }
}

public enum MUCRoomNotice {
  /// True for the message a room broadcasts when its configuration changed
  /// (status code 104, XEP-0045 §10.2.1) — Jitsi sends it when the lobby is
  /// switched on or off.
  public static func isConfigurationChange(_ element: XMPPElement) -> Bool {
    guard
      element.name == "message",
      let user = element.child(named: "x", namespace: MUCNamespace.user)
    else { return false }
    return user.children(named: "status").contains { $0[attribute: "code"] == "104" }
  }
}
