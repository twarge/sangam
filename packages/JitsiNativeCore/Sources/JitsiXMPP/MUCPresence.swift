import Foundation

public enum MUCNamespace {
  public static let muc = "http://jabber.org/protocol/muc"
  public static let user = "http://jabber.org/protocol/muc#user"
  public static let admin = "http://jabber.org/protocol/muc#admin"
  public static let nick = "http://jabber.org/protocol/nick"
  public static let stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas"
  /// Jitsi's own presence and error extensions.
  public static let jitsiMeet = "http://jitsi.org/jitmeet"
}

public struct LocalSourcePresence: Equatable, Codable, Sendable {
  public var muted: Bool
  public var videoType: String?

  public init(muted: Bool, videoType: String? = nil) {
    self.muted = muted
    self.videoType = videoType == "camera" ? nil : videoType
  }
}

/// A presence that enters a multi-user chat room. `XMPPConnection.joinMUC`
/// sends it and then waits for the room's answer addressed to
/// `roomJID/nickname`.
public protocol MUCJoinPresence: Sendable {
  var roomJID: String { get }
  var nickname: String { get }
  func element() throws -> XMPPElement
}

public struct InitialMUCPresence: Equatable, Sendable, MUCJoinPresence {
  public var roomJID: String
  public var nickname: String
  public var displayName: String
  public var password: String?
  public var audioMuted: Bool
  public var videoMuted: Bool
  public var sources: [String: LocalSourcePresence]

  public init(
    roomJID: String,
    nickname: String,
    displayName: String,
    password: String? = nil,
    audioMuted: Bool,
    videoMuted: Bool,
    sources: [String: LocalSourcePresence]
  ) {
    self.roomJID = roomJID
    self.nickname = nickname
    self.displayName = displayName
    self.password = password
    self.audioMuted = audioMuted
    self.videoMuted = videoMuted
    self.sources = sources
  }

  public func element() throws -> XMPPElement {
    var mucChildren: [XMPPElement] = []
    if let password, !password.isEmpty {
      mucChildren.append(XMPPElement(name: "password", text: password))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let sourceData = try encoder.encode(sources)
    guard let sourceJSON = String(data: sourceData, encoding: .utf8) else {
      throw MUCPresenceError.invalidSourceInfo
    }

    return XMPPElement(
      name: "presence",
      attributes: ["to": "\(roomJID)/\(nickname)"],
      children: [
        XMPPElement(
          name: "x",
          namespace: MUCNamespace.muc,
          children: mucChildren
        ),
        XMPPElement(
          name: "nick",
          namespace: MUCNamespace.nick,
          text: displayName
        ),
        XMPPElement(name: "audiomuted", text: audioMuted ? "true" : "false"),
        XMPPElement(name: "videomuted", text: videoMuted ? "true" : "false"),
        XMPPElement(name: "SourceInfo", text: sourceJSON),
      ]
    )
  }
}

public struct SourceInfoPresenceUpdate: Equatable, Sendable {
  public var occupantJID: String
  public var audioMuted: Bool
  public var videoMuted: Bool
  public var sources: [String: LocalSourcePresence]
  /// A MUC presence update replaces the previous one wholesale, so the
  /// display name must ride along on every update or the participant loses
  /// their name in everyone else's roster.
  public var displayName: String?
  /// Epoch milliseconds of when the hand was raised (Jitsi's
  /// `jitsi_participant_raisedHand` participant property); `nil` when lowered.
  public var raisedHandTimestamp: String?

  public init(
    occupantJID: String,
    audioMuted: Bool,
    videoMuted: Bool,
    sources: [String: LocalSourcePresence],
    displayName: String? = nil,
    raisedHandTimestamp: String? = nil
  ) {
    self.occupantJID = occupantJID
    self.audioMuted = audioMuted
    self.videoMuted = videoMuted
    self.sources = sources
    self.displayName = displayName
    self.raisedHandTimestamp = raisedHandTimestamp
  }

  public func element() throws -> XMPPElement {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(sources)
    guard let sourceJSON = String(data: data, encoding: .utf8) else {
      throw MUCPresenceError.invalidSourceInfo
    }
    var children: [XMPPElement] = []
    if let displayName, !displayName.isEmpty {
      children.append(XMPPElement(name: "nick", namespace: MUCNamespace.nick, text: displayName))
    }
    children += [
      XMPPElement(name: "audiomuted", text: audioMuted ? "true" : "false"),
      XMPPElement(name: "videomuted", text: videoMuted ? "true" : "false"),
      XMPPElement(name: "SourceInfo", text: sourceJSON),
    ]
    if let raisedHandTimestamp, !raisedHandTimestamp.isEmpty {
      children.append(XMPPElement(name: "jitsi_participant_raisedHand", text: raisedHandTimestamp))
    }
    return XMPPElement(
      name: "presence",
      attributes: ["to": occupantJID],
      children: children
    )
  }
}

/// Leaves a room the client previously joined.
public struct MUCLeavePresence: Equatable, Sendable {
  public var occupantJID: String

  public init(occupantJID: String) {
    self.occupantJID = occupantJID
  }

  public func element() -> XMPPElement {
    XMPPElement(name: "presence", attributes: ["to": occupantJID, "type": "unavailable"])
  }
}

public struct RemoteSourcePresence: Equatable, Sendable {
  public var name: String
  public var kind: String
  public var muted: Bool
  public var videoType: String?
}

/// The `<destroy/>` notice a room sends its occupants when it is torn down
/// (XEP-0045 §10.9). Jitsi's lobby module uses the alternate room address to
/// tell waiting participants the lobby was switched off and they may join
/// the meeting directly.
public struct MUCRoomDestroyed: Equatable, Sendable {
  public var alternateRoomJID: String?
  public var reason: String?

  public init(alternateRoomJID: String? = nil, reason: String? = nil) {
    self.alternateRoomJID = alternateRoomJID
    self.reason = reason
  }
}

public struct MUCParticipantPresence: Equatable, Sendable {
  public var occupantJID: String
  public var roomJID: String
  public var endpointID: String
  public var displayName: String?
  public var role: String?
  public var affiliation: String?
  /// The occupant's real XMPP address, which the room discloses to moderators
  /// (and to everyone in a non-anonymous room). Needed to invite them.
  public var realJID: String?
  public var isAvailable: Bool
  /// XEP-0045 status codes carried by the `muc#user` extension, e.g. `110`
  /// for the client's own presence or `307` when it was kicked.
  public var statusCodes: Set<String>
  public var destroyed: MUCRoomDestroyed?
  public var audioMuted: Bool?
  public var videoMuted: Bool?
  public var sources: [RemoteSourcePresence]
  /// Set while the occupant's hand is raised (Jitsi's
  /// `jitsi_participant_raisedHand` property, an epoch-milliseconds value).
  public var raisedHandTimestamp: String?

  /// Whether this describes the receiving client's own occupant.
  public var isSelf: Bool { statusCodes.contains("110") }
  /// Whether the occupant was removed by a moderator.
  public var wasKicked: Bool { statusCodes.contains("307") }
  public var isModerator: Bool {
    role == "moderator" || affiliation == "owner" || affiliation == "admin"
  }

  public init(element: XMPPElement, maximumSourceInfoBytes: Int = 65_536) throws {
    guard element.name == "presence", let from = element[attribute: "from"] else {
      throw MUCPresenceError.notPresence
    }
    guard let endpoint = XMPPJID.resource(from), !endpoint.isEmpty else {
      throw MUCPresenceError.missingEndpointID
    }
    occupantJID = from
    roomJID = XMPPJID.bare(from)
    endpointID = endpoint
    isAvailable = element[attribute: "type"] != "unavailable"
    displayName = element.child(named: "nick", namespace: MUCNamespace.nick)?.text
    audioMuted = Self.parseBoolean(element.child(named: "audiomuted")?.text)
    videoMuted = Self.parseBoolean(element.child(named: "videomuted")?.text)
    raisedHandTimestamp = (element.child(named: "jitsi_participant_raisedHand")?.text)
      .flatMap { $0.isEmpty ? nil : $0 }

    let user = element.child(named: "x", namespace: MUCNamespace.user)
    let item = user?.child(named: "item", namespace: MUCNamespace.user)
    role = item?[attribute: "role"]
    affiliation = item?[attribute: "affiliation"]
    realJID = item?[attribute: "jid"]
    statusCodes = Set(
      user?.children(named: "status", namespace: MUCNamespace.user)
        .compactMap { $0[attribute: "code"] } ?? []
    )
    destroyed = user?.child(named: "destroy", namespace: MUCNamespace.user).map { destroy in
      MUCRoomDestroyed(
        alternateRoomJID: destroy[attribute: "jid"].flatMap { $0.isEmpty ? nil : $0 },
        reason: destroy.child(named: "reason")?.text
      )
    }

    if let sourceJSON = element.child(named: "SourceInfo")?.text {
      guard sourceJSON.utf8.count <= maximumSourceInfoBytes else {
        throw MUCPresenceError.sourceInfoTooLarge(limit: maximumSourceInfoBytes)
      }
      let decoded: [String: LocalSourcePresence]
      do {
        decoded = try JSONDecoder().decode(
          [String: LocalSourcePresence].self,
          from: Data(sourceJSON.utf8)
        )
      } catch {
        throw MUCPresenceError.invalidSourceInfo
      }
      guard decoded.count <= 16 else { throw MUCPresenceError.tooManySources(limit: 16) }
      sources = decoded.keys.sorted().compactMap { name in
        guard
          let state = decoded[name],
          let kind = Self.mediaKind(sourceName: name, endpointID: endpoint)
        else { return nil }
        let videoType = kind == "video" ? state.videoType ?? "camera" : nil
        guard videoType == nil || videoType == "camera" || videoType == "desktop" else {
          return nil
        }
        return RemoteSourcePresence(
          name: name,
          kind: kind,
          muted: state.muted,
          videoType: videoType
        )
      }
    } else {
      sources = []
    }
  }

  private static func parseBoolean(_ text: String?) -> Bool? {
    switch text {
    case "true": true
    case "false": false
    default: nil
    }
  }

  private static func mediaKind(sourceName: String, endpointID: String) -> String? {
    let prefix = "\(endpointID)-"
    guard sourceName.hasPrefix(prefix), sourceName.utf8.count <= 128 else { return nil }
    let suffix = sourceName.dropFirst(prefix.count)
    guard suffix.count >= 2, let type = suffix.first else { return nil }
    guard suffix.dropFirst().allSatisfy(\.isNumber) else { return nil }
    switch type {
    case "a": return "audio"
    case "v": return "video"
    default: return nil
    }
  }
}

/// Why a room refused the client's join presence.
///
/// A MUC answers a rejected join with `<presence type="error">` rather than
/// with the self-presence the client is waiting for, so every case here used to
/// look exactly like a join that never completes.
public enum MUCJoinError: Error, Equatable, Sendable {
  /// The room is members-only. Jitsi's lobby module adds the address of the
  /// lobby room where the client may wait for a moderator; `waitingForHost`
  /// is set when the deployment parks guests there until a host arrives.
  case membersOnly(lobbyRoomJID: String?, waitingForHost: Bool)
  case passwordRequired
  case notAllowed(text: String?)
  case roomFull
  case nicknameConflict
  /// Jitsi's lobby refuses anonymous-looking joins without a `<nick/>`.
  case displayNameRequired
  case other(condition: String?, text: String?)

  /// Returns `nil` unless `element` is an error presence.
  public init?(element: XMPPElement) {
    guard
      element.name == "presence",
      element[attribute: "type"] == "error",
      let error = element.child(named: "error")
    else { return nil }

    let condition =
      error.children.first { $0.namespace == MUCNamespace.stanzas && $0.name != "text" }?.name
      ?? error.children.first { $0.name != "text" }?.name
    let text = error.child(named: "text")?.text

    switch condition {
    case "registration-required":
      // Current deployments nest the lobby address inside <error/>; older
      // ones put it at the top level. Accept either.
      let lobbyRoomJID = (error.child(named: "lobbyroom") ?? element.child(named: "lobbyroom"))?
        .text
      self = .membersOnly(
        lobbyRoomJID: lobbyRoomJID.flatMap { $0.isEmpty ? nil : $0 },
        waitingForHost: error.child(named: "waiting-for-host") != nil
      )
    case "not-authorized":
      self = .passwordRequired
    case "not-allowed":
      self = .notAllowed(text: text)
    case "service-unavailable":
      self = .roomFull
    case "conflict":
      self = .nicknameConflict
    case "not-acceptable" where error.child(named: "displayname-required") != nil:
      self = .displayNameRequired
    default:
      self = .other(condition: condition, text: text)
    }
  }
}

extension MUCJoinError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .membersOnly:
      return "This meeting only admits invited participants."
    case .passwordRequired:
      return "This meeting requires a password, which Sangam does not support yet."
    case .notAllowed(let text):
      if let text, !text.isEmpty { return "You are not allowed to join this meeting (\(text))." }
      return "You are not allowed to join this meeting."
    case .roomFull:
      return "This meeting is full."
    case .nicknameConflict:
      return "Someone else in the meeting is already using this identity."
    case .displayNameRequired:
      return "This meeting has a lobby and needs a display name. Enter one and try again."
    case .other(let condition, let text):
      if let text, !text.isEmpty { return "The meeting refused the join: \(text)" }
      if let condition { return "The meeting refused the join (\(condition))." }
      return "The meeting refused the join."
    }
  }
}

public enum MUCPresenceError: Error, Equatable, Sendable {
  case notPresence
  case missingEndpointID
  case invalidSourceInfo
  case sourceInfoTooLarge(limit: Int)
  case tooManySources(limit: Int)
}
