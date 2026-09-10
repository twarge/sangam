import Foundation
import JitsiDiscovery
import JitsiMedia
import JitsiXMPP

public struct NativeConferenceJoinOptions: Equatable, Sendable {
  public var serverURL: URL
  public var room: String
  public var displayName: String
  public var token: String?
  public var username: String?
  public var password: String?
  public var waitForHost: Bool
  public var startCamera: Bool
  public var startMicrophoneMuted: Bool
  /// The meeting's own password (XEP-0045 room secret), when it has one.
  public var meetingPassword: String?

  public init(
    serverURL: URL,
    room: String,
    displayName: String,
    token: String? = nil,
    username: String? = nil,
    password: String? = nil,
    waitForHost: Bool = false,
    startCamera: Bool = true,
    startMicrophoneMuted: Bool = false,
    meetingPassword: String? = nil
  ) {
    self.serverURL = serverURL
    self.room = room
    self.displayName = displayName
    self.token = token
    self.username = username
    self.password = password
    self.waitForHost = waitForHost
    self.startCamera = startCamera
    self.startMicrophoneMuted = startMicrophoneMuted
    self.meetingPassword = meetingPassword
  }
}

/// Milestones a join reports while it is still in progress.
public enum NativeConferenceJoinProgress: Equatable, Sendable {
  /// The meeting has a lobby; the client is waiting in it for a moderator to
  /// admit it. `waitingForHost` is set by deployments that park everyone in
  /// the lobby until a host arrives, rather than until a moderator decides.
  case waitingInLobby(waitingForHost: Bool)
  /// A join stage began. Purely informational: the stages between opening the
  /// connection and entering the room take from milliseconds to forever (a
  /// camera permission prompt, a focus that never reports ready), and a stall
  /// with no stage marker in the log cannot be localized afterwards.
  case stage(NativeConferenceJoinStage)
}

/// The sequential stages of a join, reported through
/// `NativeConferenceJoinProgress.stage` as each one begins.
public enum NativeConferenceJoinStage: String, Equatable, Sendable {
  case openingConnection = "opening XMPP connection"
  case allocatingFocus = "asking Jicofo for the conference"
  case discoveringICEServers = "discovering ICE relays"
  case startingCamera = "starting the camera"
  case joiningRoom = "joining the meeting room"
}

public struct NativeConferenceHandle: Sendable {
  public var coordinator: NativeJingleCoordinator
  public var deployment: DeploymentConfiguration
  public var boundJID: String
  public var roomJID: String
  public var occupantJID: String
  public var focus: FocusConferenceResponse
}

public enum NativeConferenceBootstrapError: Error, Equatable, Sendable {
  case invalidRoom
  case focusNotReady
  case invalidFocusResponse
  case focusHTTPStatus(Int)
  case authenticationRequired
  case invalidCredentials
  /// The meeting admits invited members only and offers no lobby to wait in.
  case membersOnly
  /// The meeting ended while the client was waiting in its lobby.
  case meetingEnded
  /// The room requires a meeting password (and none, or a wrong one, was
  /// given).
  case passwordRequired
  /// The server refuses guest connections outright: an account is needed to
  /// get as far as the meeting.
  case guestAccessUnavailable
  /// The server offers no username-and-password sign-in, so the credentials
  /// were never even tried.
  case passwordLoginUnavailable
}

extension NativeConferenceBootstrapError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidRoom: return "The room name is not valid."
    case .focusNotReady: return "The Jitsi conference focus did not become ready."
    case .invalidFocusResponse: return "The conference service returned an invalid response."
    case .focusHTTPStatus(let status):
      return "The conference service rejected the request (HTTP \(status))."
    case .authenticationRequired:
      return "A host account is required to create this meeting."
    case .invalidCredentials:
      return "The username or password was not accepted."
    case .membersOnly:
      return "This meeting only admits invited participants."
    case .meetingEnded:
      return "The meeting ended before you were admitted."
    case .passwordRequired:
      return "This meeting requires a password."
    case .guestAccessUnavailable:
      return "This server requires an account to join a meeting."
    case .passwordLoginUnavailable:
      return "This server does not accept username and password sign-in."
    }
  }
}

public struct NativeConferenceBootstrap: Sendable {
  /// How long an ordinary join waits for Jicofo to report a ready conference
  /// before giving up. Only the explicit wait-for-a-host mode retries past it.
  static let focusReadyTimeout: Int = 20

  public var discoveryClient: DiscoveryClient

  public init(discoveryClient: DiscoveryClient = .init()) {
    self.discoveryClient = discoveryClient
  }

  /// Joins a conference. `progress` is called for milestones that happen
  /// before the join completes and that the user should see — today, only
  /// being parked in the meeting's lobby.
  public func connect(
    _ options: NativeConferenceJoinOptions,
    progress: @escaping @Sendable (NativeConferenceJoinProgress) -> Void = { _ in }
  ) async throws -> NativeConferenceHandle {
    let room = options.room.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !room.isEmpty,
      room.utf8.count <= 1_024,
      !room.contains("/")
    else { throw NativeConferenceBootstrapError.invalidRoom }

    let deployment = try await discoveryClient.discover(baseURL: options.serverURL)
    // Bare 8-hex-char id, matching upstream's randomHexString(8): deployed
    // jitsi-meet webapps parse a source name's owner with split('-')[0], so a
    // dash inside the endpoint id breaks their screen-share tile binding.
    let endpointID = String(UUID().uuidString.prefix(8)).lowercased()
    // A room with an @ is already a full MUC address — how breakout rooms
    // are named, since they live on their own MUC service.
    let roomJID = room.contains("@") ? room : "\(room)@\(deployment.mucDomain)"
    let username = options.username?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasCredentials = username?.isEmpty == false && options.password?.isEmpty == false
    let xmppConnectionDomain =
      hasCredentials
      ? deployment.xmppDomain
      : deployment.anonymousDomain ?? deployment.xmppDomain
    let credential: XMPPCredential =
      if let username, let password = options.password, hasCredentials {
        .plain(
          username: username.split(separator: "@").first.map(String.init) ?? username,
          password: password)
      } else {
        .anonymous
      }
    progress(.stage(.openingConnection))
    let connection: XMPPConnection
    let boundJID: String
    do {
      // The SASL exchange happens here, so this is where a refused password is
      // answered — before there is a connection to tear down, and outside the
      // join's own error handling below.
      (connection, boundJID) = try await openConnection(
        deployment: deployment,
        room: room,
        domain: xmppConnectionDomain,
        credential: credential,
        endpointID: endpointID,
        token: options.token
      )
    } catch {
      throw Self.joinError(from: error, hasCredentials: hasCredentials)
    }

    do {
      progress(.stage(.allocatingFocus))
      let focus = try await allocateFocus(
        connection: connection,
        deployment: deployment,
        roomJID: roomJID,
        token: options.token,
        waitForHost: options.waitForHost
      )
      // Ask the deployment for its relays before opening the peer connection.
      // Without them the only candidates are host addresses, so a videobridge
      // whose media port is firewalled off is simply unreachable.
      progress(.stage(.discoveringICEServers))
      let iceServers = await Self.iceServers(
        connection: connection,
        domain: deployment.xmppDomain
      )
      let jingleConfiguration = NativeJingleConfiguration(
        responderJID: boundJID,
        occupantJID: "\(roomJID)/\(endpointID)",
        displayName: options.displayName,
        audioTrackID: "\(endpointID)-audio-track",
        cameraTrackID: "\(endpointID)-camera-track",
        audioSourceName: "\(endpointID)-a0",
        cameraSourceName: "\(endpointID)-v0",
        screenSourceName: "\(endpointID)-v1",
        // Anonymous joins bind on the guest domain, but service components
        // (AV moderation, speaker stats) announce on the main one.
        xmppDomain: deployment.xmppDomain
      )
      let coordinator: NativeJingleCoordinator
      do {
        coordinator = try NativeJingleCoordinator(
          connection: connection,
          configuration: jingleConfiguration,
          policy: PeerConnectionPolicy(iceServers: iceServers)
        )
      } catch WebRTCMediaError.peerConnectionCreationFailed where !iceServers.isEmpty {
        // A deployment's advertised ICE set can be malformed in ways WebRTC
        // rejects wholesale; joining without relays still beats not joining.
        coordinator = try NativeJingleCoordinator(
          connection: connection,
          configuration: jingleConfiguration,
          policy: PeerConnectionPolicy()
        )
      }

      // Bring the camera up before entering the room. Starting capture can
      // block on a permission prompt, and Jicofo probes a new occupant with
      // disco#info as soon as it sees one — it gives up and leaves the room if
      // that goes unanswered for about fifteen seconds. Joining only once the
      // slow local work is finished keeps the receive loop able to answer
      // immediately.
      if options.startCamera {
        progress(.stage(.startingCamera))
        try await coordinator.startCamera()
      }

      progress(.stage(.joiningRoom))
      let selfPresence = try await joinRoom(
        connection: connection,
        presence: InitialMUCPresence(
          roomJID: roomJID,
          nickname: endpointID,
          displayName: options.displayName,
          password: options.meetingPassword,
          audioMuted: options.startMicrophoneMuted,
          videoMuted: !options.startCamera,
          sources: [
            "\(endpointID)-a0": LocalSourcePresence(
              muted: options.startMicrophoneMuted
            ),
            "\(endpointID)-v0": LocalSourcePresence(
              muted: !options.startCamera,
              videoType: "camera"
            ),
          ]
        ),
        progress: progress
      )
      // Start reading before announcing anything, so Jicofo's capability probe
      // is answered the moment it arrives.
      await coordinator.start()
      // The join consumed the room's answer to our own presence; the
      // coordinator needs it to know whether this client moderates the room.
      await coordinator.noteLocalPresence(selfPresence)
      await coordinator.setMicrophoneMuted(options.startMicrophoneMuted)
      await coordinator.setCameraEnabled(options.startCamera)
      return NativeConferenceHandle(
        coordinator: coordinator,
        deployment: deployment,
        boundJID: boundJID,
        roomJID: roomJID,
        occupantJID: "\(roomJID)/\(endpointID)",
        focus: focus
      )
    } catch {
      Self.tearDown(connection)
      throw Self.joinError(from: error, hasCredentials: hasCredentials)
    }
  }

  /// Translates a stream-level refusal into the join error the sign-in card
  /// knows how to act on, so the person joining is told which of the things
  /// they can change is wrong. Anything that is not a negotiation failure —
  /// a cancellation, a transport error — passes through untouched.
  static func joinError(from error: any Error, hasCredentials: Bool) -> any Error {
    guard let negotiation = error as? XMPPNegotiationError else { return error }
    switch negotiation {
    case .authenticationFailed:
      // Anonymous binding is refused by deployments that require an account;
      // with credentials in hand the same refusal is about those credentials.
      return hasCredentials
        ? NativeConferenceBootstrapError.invalidCredentials
        : NativeConferenceBootstrapError.guestAccessUnavailable
    case .missingMechanism("ANONYMOUS"):
      return NativeConferenceBootstrapError.guestAccessUnavailable
    case .missingMechanism("PLAIN"):
      return NativeConferenceBootstrapError.passwordLoginUnavailable
    default:
      return negotiation
    }
  }

  /// Joins the meeting room, waiting in its lobby first when the room is
  /// members-only.
  ///
  /// The lobby wait is open-ended: only the user leaving (task cancellation)
  /// or a moderator's decision ends it. Once admitted, the client is a member
  /// of the room and the same presence that was refused is accepted.
  private func joinRoom(
    connection: XMPPConnection,
    presence: InitialMUCPresence,
    progress: @Sendable (NativeConferenceJoinProgress) -> Void
  ) async throws -> MUCParticipantPresence {
    do {
      return try await connection.joinMUC(presence)
    } catch MUCJoinError.passwordRequired {
      throw NativeConferenceBootstrapError.passwordRequired
    } catch MUCJoinError.membersOnly(let lobbyRoomJID, let waitingForHost) {
      guard let lobbyRoomJID else { throw NativeConferenceBootstrapError.membersOnly }
      progress(.waitingInLobby(waitingForHost: waitingForHost))
      let lobby = LobbyAdmission(
        connection: connection,
        lobbyRoomJID: lobbyRoomJID,
        meetingRoomJID: presence.roomJID,
        nickname: presence.nickname,
        displayName: presence.displayName
      )
      var admitted = presence
      switch try await lobby.wait() {
      case .admitted(let password):
        admitted.password = password ?? presence.password
      case .lobbyDisabled:
        break
      case .meetingEnded:
        throw NativeConferenceBootstrapError.meetingEnded
      }
      let joined = try await connection.joinMUC(admitted)
      // Like lib-jitsi-meet, leave the lobby only once the meeting room has
      // let us in, so a refused re-join does not also lose our place in line.
      await lobby.leave()
      return joined
    }
  }

  /// Opens the first transport that actually works and completes the XMPP
  /// handshake on it.
  ///
  /// A deployment can advertise an endpoint its reverse proxy does not route —
  /// `config.js` naming an XMPP WebSocket while nginx has no location for it is
  /// a common half-finished state. Falling back to the other transport beats
  /// refusing to join a deployment whose own web client would also be stuck.
  private func openConnection(
    deployment: DeploymentConfiguration,
    room: String,
    domain: String,
    credential: XMPPCredential,
    endpointID: String,
    token: String?
  ) async throws -> (XMPPConnection, String) {
    var lastError: (any Error)?
    for makeSocket in transportCandidates(deployment: deployment, room: room, token: token) {
      let socket: any XMPPTextSocket
      do {
        socket = try makeSocket()
      } catch {
        lastError = error
        continue
      }
      let connection = XMPPConnection(
        transport: XMPPWebSocketTransport(socket: socket),
        negotiator: XMPPStreamNegotiator(
          domain: domain,
          resource: endpointID,
          credential: credential,
          bindID: "sangam-bind-\(UUID().uuidString.lowercased())"
        )
      )
      do {
        return (connection, try await connection.connect())
      } catch {
        Self.tearDown(connection)
        // Anything that is not the endpoint's own fault — a rejected password,
        // say — is the deployment's real answer, and must be reported rather
        // than retried against a different transport.
        guard Self.isTransportFailure(error) else { throw error }
        // The endpoint is unusable; try the next one.
        lastError = error
      }
    }
    throw lastError ?? DiscoveryError.invalidResponse
  }

  /// Transports to attempt, most capable first. The JWT (when the
  /// deployment uses token auth — meet.jit.si's SSO, JaaS) rides the
  /// connection URL: prosody validates `?token=` at session time.
  private func transportCandidates(
    deployment: DeploymentConfiguration,
    room: String,
    token: String?
  ) -> [() throws -> any XMPPTextSocket] {
    let webSocket: () throws -> any XMPPTextSocket = {
      #if canImport(Network)
        try NetworkXMPPTextSocket(
          url: Self.appending(
            queryItems: [("room", room), ("token", token)],
            to: deployment.xmppWebSocketURL),
          preflightURL: deployment.webSocketKeepAliveURL
        )
      #else
        URLSessionXMPPTextSocket(
          url: Self.appending(
            queryItems: [("token", token)], to: deployment.xmppWebSocketURL),
          preflightURL: deployment.webSocketKeepAliveURL
        )
      #endif
    }
    guard let boshURL = deployment.boshURL else { return [webSocket] }
    let bosh: () throws -> any XMPPTextSocket = {
      URLSessionXMPPBOSHSocket(
        url: Self.appending(queryItems: [("token", token)], to: boshURL),
        domain: deployment.xmppDomain,
        preflightURL: deployment.webSocketKeepAliveURL
      )
    }
    return deployment.prefersBOSH ? [bosh, webSocket] : [webSocket, bosh]
  }

  /// True when the endpoint itself could not be used, as opposed to the server
  /// answering and refusing us.
  private static func isTransportFailure(_ error: any Error) -> Bool {
    if error is NetworkXMPPSocketError { return true }
    if error is URLError { return true }
    if let bosh = error as? XMPPBOSHError {
      switch bosh {
      case .httpStatus, .invalidResponse, .missingSessionID: return true
      case .responseTooLarge, .terminated: return false
      }
    }
    if let transport = error as? XMPPTransportError {
      return transport == .notConnected || transport == .unsupportedFrame
    }
    return false
  }

  /// Best-effort relay discovery. A deployment that does not implement
  /// XEP-0215 answers with an IQ error, which only means no relays are on
  /// offer; direct connectivity may still work, so the join continues.
  private static func iceServers(
    connection: XMPPConnection,
    domain: String
  ) async -> [ICEServer] {
    guard let services = try? await connection.discoverExternalServices(domain: domain) else {
      return []
    }
    if ProcessInfo.processInfo.environment["SANGAM_LIVE_PROBE"] != nil {
      print("PROBE services: \(services.map { "\($0.kind) \($0.iceURL)" })")
    }
    return services.compactMap { service in
      switch service.kind {
      case .stun, .stuns:
        return ICEServer(urls: [service.iceURL])
      case .turn, .turns:
        // A restricted relay without credentials cannot be used, and passing
        // it to WebRTC only slows gathering down.
        guard let username = service.username, let password = service.password else {
          return service.isRestricted ? nil : ICEServer(urls: [service.iceURL])
        }
        return ICEServer(urls: [service.iceURL], username: username, credential: password)
      }
    }
  }

  /// Closes a connection the join has already given up on, without making the
  /// caller wait for it. Reporting "this room needs a host" is what the person
  /// staring at the join screen is waiting for; a courteous protocol shutdown
  /// is not, and on BOSH it can take as long as the server's poll hold.
  private static func tearDown(_ connection: XMPPConnection) {
    Task { await connection.disconnect() }
  }

  private static func appending(queryItems: [(String, String?)], to url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    var existing = components.queryItems ?? []
    for (name, value) in queryItems {
      guard let value, !value.isEmpty, !existing.contains(where: { $0.name == name }) else {
        continue
      }
      existing.append(URLQueryItem(name: name, value: value))
    }
    components.queryItems = existing
    return components.url ?? url
  }

  private func allocateFocus(
    connection: XMPPConnection,
    deployment: DeploymentConfiguration,
    roomJID: String,
    token: String?,
    waitForHost: Bool
  ) async throws -> FocusConferenceResponse {
    let machineUID = UUID().uuidString.lowercased()

    // Waiting for a host is an explicit, cancellable user choice, so that mode
    // keeps retrying. An ordinary join must not: a focus that never reports
    // ready would otherwise leave the join screen spinning forever.
    let deadline =
      waitForHost ? nil : ContinuousClock.now.advanced(by: .seconds(Self.focusReadyTimeout))
    var attempt = 0
    while !Task.isCancelled {
      if let deadline, ContinuousClock.now >= deadline {
        throw NativeConferenceBootstrapError.focusNotReady
      }
      attempt += 1
      do {
        let response: FocusConferenceResponse
        if let requestURL = deployment.conferenceRequestURL {
          response = try await allocateFocusOverHTTP(
            url: requestURL,
            roomJID: roomJID,
            machineUID: machineUID,
            token: token
          )
        } else {
          response = try await connection.allocateConference(
            FocusConferenceRequest(
              id: "sangam-focus-\(attempt)-\(UUID().uuidString.lowercased())",
              focusJID: deployment.focusJID,
              roomJID: roomJID,
              machineUID: machineUID,
              token: token,
              properties: [
                "disableRtx": "false",
                "startAudioMuted": "false",
                "startVideoMuted": "false",
                "visitors-version": "1",
              ]
            )
          )
        }
        if response.ready { return response }
      } catch XMPPConnectionError.iqError(_, let condition, _)
        where condition == "not-authorized"
      {
        guard waitForHost else { throw NativeConferenceBootstrapError.authenticationRequired }
      }
      try await Task.sleep(for: .seconds(waitForHost ? 2 : 0.5))
    }
    throw CancellationError()
  }

  private func allocateFocusOverHTTP(
    url: URL,
    roomJID: String,
    machineUID: String,
    token: String?
  ) async throws -> FocusConferenceResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "machineUid": machineUID,
      "properties": ["rtcstatsEnabled": false, "visitors-version": 1],
      "room": roomJID,
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw NativeConferenceBootstrapError.invalidFocusResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw NativeConferenceBootstrapError.focusHTTPStatus(response.statusCode)
    }
    let result = try JSONDecoder().decode(HTTPFocusResponse.self, from: data)
    return FocusConferenceResponse(
      ready: result.ready,
      focusJID: result.focusJid,
      sessionID: result.sessionId,
      identity: result.identity,
      vnode: result.vnode,
      properties: result.properties ?? [:]
    )
  }

  private struct HTTPFocusResponse: Decodable {
    var ready: Bool
    var focusJid: String?
    var sessionId: String?
    var identity: String?
    var vnode: String?
    var properties: [String: String]?
  }
}
