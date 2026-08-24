import Foundation

public enum JingleAction: String, Codable, Sendable {
  case sessionInitiate = "session-initiate"
  case sessionAccept = "session-accept"
  case sessionTerminate = "session-terminate"
  case transportInfo = "transport-info"
  case transportReplace = "transport-replace"
  case transportAccept = "transport-accept"
  case sourceAdd = "source-add"
  case sourceRemove = "source-remove"
  case contentAdd = "content-add"
  case contentRemove = "content-remove"
}

public struct JingleSessionDescription: Equatable, Sendable {
  public var action: JingleAction
  public var sessionID: String
  public var initiator: String?
  public var contents: [JingleContent]
  public var bundle: [String]

  public init(
    action: JingleAction,
    sessionID: String,
    initiator: String?,
    contents: [JingleContent],
    bundle: [String] = []
  ) {
    self.action = action
    self.sessionID = sessionID
    self.initiator = initiator
    self.contents = contents
    self.bundle = bundle
  }
}

public struct JingleContent: Equatable, Sendable {
  public var name: String
  public var creator: String?
  public var senders: String?
  public var description: RTPDescription?
  public var transport: ICETransport?

  public init(
    name: String,
    creator: String? = nil,
    senders: String? = nil,
    description: RTPDescription? = nil,
    transport: ICETransport? = nil
  ) {
    self.name = name
    self.creator = creator
    self.senders = senders
    self.description = description
    self.transport = transport
  }
}

public struct RTPDescription: Equatable, Sendable {
  public var media: String
  public var payloadTypes: [RTPPayloadType]
  public var headerExtensions: [RTPHeaderExtension]
  public var sources: [RTPSource]
  public var sourceGroups: [RTPSourceGroup]
  public var rtcpMux: Bool
  public var extmapAllowMixed: Bool

  public init(
    media: String,
    payloadTypes: [RTPPayloadType] = [],
    headerExtensions: [RTPHeaderExtension] = [],
    sources: [RTPSource] = [],
    sourceGroups: [RTPSourceGroup] = [],
    rtcpMux: Bool = true,
    extmapAllowMixed: Bool = false
  ) {
    self.media = media
    self.payloadTypes = payloadTypes
    self.headerExtensions = headerExtensions
    self.sources = sources
    self.sourceGroups = sourceGroups
    self.rtcpMux = rtcpMux
    self.extmapAllowMixed = extmapAllowMixed
  }
}

public struct RTPPayloadType: Equatable, Sendable {
  public var id: Int
  public var name: String?
  public var clockRate: Int?
  public var channels: Int?
  public var parameters: [String: String]
  public var feedback: [RTPFeedback]

  public init(
    id: Int,
    name: String? = nil,
    clockRate: Int? = nil,
    channels: Int? = nil,
    parameters: [String: String] = [:],
    feedback: [RTPFeedback] = []
  ) {
    self.id = id
    self.name = name
    self.clockRate = clockRate
    self.channels = channels
    self.parameters = parameters
    self.feedback = feedback
  }
}

public struct RTPHeaderExtension: Equatable, Sendable {
  public var id: Int
  public var uri: String
}

public struct RTPFeedback: Equatable, Sendable {
  public var type: String
  public var subtype: String?
}

public struct RTPSource: Equatable, Sendable {
  public var ssrc: UInt32
  /// The Jitsi source name (`<source name="…">`). lib-jitsi-meet signals it as
  /// an XML attribute, never as a `<parameter>`; kept out of `parameters` so it
  /// is not emitted as an `a=ssrc:` attribute either.
  public var name: String?
  /// "camera" or "desktop", again an XML attribute in the reference client.
  public var videoType: String?
  /// The owning occupant, from `<ssrc-info owner="…">`.
  public var owner: String?
  /// `<parameter>` children, which are what becomes `a=ssrc:` attribute lines
  /// in SDP. The reference client only ever signals `msid` here.
  public var parameters: [String: String]

  public init(
    ssrc: UInt32,
    name: String? = nil,
    videoType: String? = nil,
    owner: String? = nil,
    parameters: [String: String] = [:]
  ) {
    self.ssrc = ssrc
    self.name = name
    self.videoType = videoType
    self.owner = owner
    self.parameters = parameters
  }

  public var sourceName: String? { name ?? parameters["name"] }
}

public struct RTPSourceGroup: Equatable, Sendable {
  public var semantics: String
  public var sources: [UInt32]

  public init(semantics: String, sources: [UInt32]) {
    self.semantics = semantics
    self.sources = sources
  }
}

public struct ICETransport: Equatable, Sendable {
  public var usernameFragment: String?
  public var password: String?
  public var candidates: [ICECandidate]
  public var fingerprint: DTLSFingerprint?
  /// The Jitsi Videobridge colibri bridge-channel WebSocket, advertised in the
  /// session-initiate transport. The client connects to it and sends receiver
  /// video constraints; without that the bridge forwards no remote video.
  public var bridgeWebSocketURL: String?

  public init(
    usernameFragment: String? = nil,
    password: String? = nil,
    candidates: [ICECandidate] = [],
    fingerprint: DTLSFingerprint? = nil,
    bridgeWebSocketURL: String? = nil
  ) {
    self.usernameFragment = usernameFragment
    self.password = password
    self.candidates = candidates
    self.fingerprint = fingerprint
    self.bridgeWebSocketURL = bridgeWebSocketURL
  }
}

/// The local ICE username fragment and password, as negotiated in our own
/// session description.
///
/// These must accompany *every* `<transport>` we send, not only the
/// session-accept. Jitsi Videobridge assigns the remote credentials from each
/// transport update it receives, so a trickled candidate sent without them
/// overwrites the bridge's copy with nothing — after which it can no longer
/// sign its own connectivity checks and ICE fails even though our packets are
/// reaching it.
public struct ICECredentials: Equatable, Sendable {
  public var usernameFragment: String
  public var password: String

  public init(usernameFragment: String, password: String) {
    self.usernameFragment = usernameFragment
    self.password = password
  }

  /// Reads the first `a=ice-ufrag:` / `a=ice-pwd:` pair in `sdp`. With BUNDLE
  /// every media section shares one transport, so the first pair is the pair.
  public init?(sdp: String) {
    var fragment: String?
    var password: String?
    for rawLine in sdp.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if fragment == nil, line.hasPrefix("a=ice-ufrag:") {
        fragment = String(line.dropFirst("a=ice-ufrag:".count))
      } else if password == nil, line.hasPrefix("a=ice-pwd:") {
        password = String(line.dropFirst("a=ice-pwd:".count))
      }
      if fragment != nil, password != nil { break }
    }
    guard let fragment, let password, !fragment.isEmpty, !password.isEmpty else { return nil }
    usernameFragment = fragment
    self.password = password
  }
}

public struct ICECandidate: Equatable, Sendable {
  public var foundation: String?
  public var component: Int?
  public var protocolName: String?
  public var priority: UInt64?
  public var ip: String?
  public var port: Int?
  public var type: String?
  public var generation: Int?
  public var relatedAddress: String?
  public var relatedPort: Int?
  public var tcpType: String?
}

public struct DTLSFingerprint: Equatable, Sendable {
  public var hash: String
  public var setup: String?
  public var value: String
}
