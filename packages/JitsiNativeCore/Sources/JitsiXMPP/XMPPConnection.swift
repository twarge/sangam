import Foundation

public actor XMPPConnection {
  private let transport: XMPPWebSocketTransport
  private var negotiator: XMPPStreamNegotiator
  private var bufferedElements: [XMPPElement] = []
  private var boundJID: String?

  public init(transport: XMPPWebSocketTransport, negotiator: XMPPStreamNegotiator) {
    self.transport = transport
    self.negotiator = negotiator
  }

  public func connect(maximumNegotiationFrames: Int = 32) async throws -> String {
    try await transport.connect()
    try await perform(negotiator.start())

    for _ in 0..<maximumNegotiationFrames {
      let element = try await transport.receive()
      let actions = try negotiator.receive(element)
      for action in actions {
        switch action {
        case .send(let xml):
          try await transport.send(xml)
        case .ready(let jid):
          boundJID = jid
          return jid
        }
      }
    }
    throw XMPPConnectionError.negotiationFrameLimit(maximumNegotiationFrames)
  }

  public func send(_ element: XMPPElement) async throws {
    guard boundJID != nil else { throw XMPPConnectionError.notReady }
    try await transport.send(element)
  }

  public func request(
    _ element: XMPPElement,
    id: String,
    maximumUnmatchedFrames: Int = 128
  ) async throws -> XMPPElement {
    try await send(element)
    for _ in 0..<maximumUnmatchedFrames {
      let incoming = try await transport.receive()
      if incoming.name == "iq", incoming[attribute: "id"] == id {
        if incoming[attribute: "type"] == "error" {
          let error = incoming.child(named: "error")
          let condition = error?.children.first(where: { $0.name != "text" })?.name
          let text = error?.child(named: "text")?.text
          throw XMPPConnectionError.iqError(id: id, condition: condition, text: text)
        }
        return incoming
      }
      bufferedElements.append(incoming)
    }
    throw XMPPConnectionError.unmatchedFrameLimit(maximumUnmatchedFrames)
  }

  public func allocateConference(
    _ request: FocusConferenceRequest,
    maximumUnmatchedFrames: Int = 128
  ) async throws -> FocusConferenceResponse {
    let response = try await self.request(
      request.element(),
      id: request.id,
      maximumUnmatchedFrames: maximumUnmatchedFrames
    )
    return try FocusConferenceResponse(element: response)
  }

  /// Joins a room and returns the room's confirmation (the self-presence).
  ///
  /// A room that refuses the join answers with an error presence instead, and
  /// that must surface as a thrown `MUCJoinError`: a members-only room's
  /// refusal carries the lobby address the caller needs, and swallowing any
  /// refusal would leave the join waiting for a confirmation that never comes.
  public func joinMUC(
    _ presence: some MUCJoinPresence,
    maximumUnmatchedFrames: Int = 128
  ) async throws -> MUCParticipantPresence {
    try await send(presence.element())
    let expectedOccupant = "\(presence.roomJID)/\(presence.nickname)"
    for _ in 0..<maximumUnmatchedFrames {
      let incoming = try await transport.receive()
      if incoming.name == "presence", let from = incoming[attribute: "from"] {
        let isOwnOccupant = XMPPJID.matches(from, expectedOccupant)
        if isOwnOccupant || XMPPJID.matches(from, presence.roomJID),
          let refusal = MUCJoinError(element: incoming)
        {
          throw refusal
        }
        if isOwnOccupant, Self.isSelfPresence(incoming) {
          return try MUCParticipantPresence(element: incoming)
        }
      }
      bufferedElements.append(incoming)
    }
    throw XMPPConnectionError.unmatchedFrameLimit(maximumUnmatchedFrames)
  }

  public func nextElement() async throws -> XMPPElement {
    guard boundJID != nil else { throw XMPPConnectionError.notReady }
    if !bufferedElements.isEmpty {
      return bufferedElements.removeFirst()
    }
    return try await transport.receive()
  }

  public func disconnect() async {
    if boundJID != nil {
      try? await transport.send(
        XMPPElement(
          name: "close",
          namespace: "urn:ietf:params:xml:ns:xmpp-framing"
        )
      )
    }
    boundJID = nil
    bufferedElements.removeAll()
    await transport.close()
  }

  private func perform(_ actions: [XMPPNegotiationAction]) async throws {
    for action in actions {
      if case .send(let xml) = action {
        try await transport.send(xml)
      }
    }
  }

  private static func isSelfPresence(_ element: XMPPElement) -> Bool {
    let user = element.child(
      named: "x",
      namespace: "http://jabber.org/protocol/muc#user"
    )
    return user?.children(
      named: "status",
      namespace: "http://jabber.org/protocol/muc#user"
    ).contains(where: { $0[attribute: "code"] == "110" }) == true
  }
}

public enum XMPPConnectionError: Error, Equatable, Sendable {
  case notReady
  case negotiationFrameLimit(Int)
  case unmatchedFrameLimit(Int)
  case iqError(id: String, condition: String?, text: String?)
}

extension XMPPConnectionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notReady:
      return "The XMPP connection is not ready."
    case .negotiationFrameLimit:
      return "The XMPP server did not finish authentication."
    case .unmatchedFrameLimit:
      return "The XMPP server did not answer the request."
    case .iqError(_, let condition, let text):
      if let text, let condition { return "\(text) (\(condition))" }
      return text ?? condition ?? "The conference service rejected the request."
    }
  }
}
