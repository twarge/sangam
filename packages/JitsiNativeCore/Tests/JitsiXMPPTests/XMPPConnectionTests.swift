import Testing

@testable import JitsiXMPP

@Test
func performsCompleteSignalingBootstrapAndBuffersEarlyPresence() async throws {
  let frames: [XMPPWebSocketMessage] = [
    .text(
      """
      <features xmlns="http://etherx.jabber.org/streams">
        <mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><mechanism>ANONYMOUS</mechanism></mechanisms>
      </features>
      """
    ),
    .text("<success xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\"/>"),
    .text(
      """
      <features xmlns="http://etherx.jabber.org/streams">
        <bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"/>
      </features>
      """
    ),
    .text(
      """
      <iq id="bind-test" type="result"><bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"><jid>guest@example.test/native</jid></bind></iq>
      """
    ),
    .text("<presence from=\"room@conference.example.test/early-user\"/>"),
    .text(
      """
      <iq id="focus-test" type="result">
        <conference xmlns="http://jitsi.org/protocol/focus" ready="true" focusjid="focus@auth.example.test/focus" session-id="session"/>
      </iq>
      """
    ),
    .text(
      """
      <presence from="room@conference.example.test/native">
        <nick xmlns="http://jabber.org/protocol/nick">Native</nick>
        <x xmlns="http://jabber.org/protocol/muc#user"><item affiliation="member" role="participant"/><status code="110"/></x>
      </presence>
      """
    ),
  ]
  let socket = ConnectionTestSocket(frames: frames)
  let transport = XMPPWebSocketTransport(socket: socket)
  let connection = XMPPConnection(
    transport: transport,
    negotiator: XMPPStreamNegotiator(
      domain: "example.test",
      resource: "native",
      credential: .anonymous,
      bindID: "bind-test"
    )
  )

  #expect(try await connection.connect() == "guest@example.test/native")
  let focus = try await connection.allocateConference(
    FocusConferenceRequest(
      id: "focus-test",
      focusJID: "focus.example.test",
      roomJID: "room@conference.example.test",
      machineUID: "machine"
    )
  )
  #expect(focus.ready)
  #expect(focus.sessionID == "session")

  let selfPresence = try await connection.joinMUC(
    InitialMUCPresence(
      roomJID: "room@conference.example.test",
      nickname: "native",
      displayName: "Native",
      audioMuted: false,
      videoMuted: false,
      sources: [:]
    )
  )
  #expect(selfPresence.endpointID == "native")
  #expect(
    try await connection.nextElement()[attribute: "from"]
      == "room@conference.example.test/early-user")

  await connection.disconnect()
  let sent = await socket.sent
  #expect(sent.count == 7)
  #expect(sent.contains(where: { $0.contains("focus-test") }))
  #expect(sent.contains(where: { $0.contains("room@conference.example.test/native") }))
}

@Test
func surfacesCorrelatedIQErrors() async throws {
  let socket = ConnectionTestSocket(
    frames: bootstrapFrames(bindID: "bind") + [
      .text("<iq id=\"request-1\" type=\"error\"><error type=\"cancel\"/></iq>")
    ]
  )
  let connection = XMPPConnection(
    transport: XMPPWebSocketTransport(socket: socket),
    negotiator: XMPPStreamNegotiator(
      domain: "example.test",
      resource: "native",
      credential: .anonymous,
      bindID: "bind"
    )
  )
  _ = try await connection.connect()

  await #expect(
    throws: XMPPConnectionError.iqError(
      id: "request-1",
      condition: nil,
      text: nil
    )
  ) {
    try await connection.request(
      XMPPElement(name: "iq", attributes: ["id": "request-1", "type": "get"]),
      id: "request-1"
    )
  }
}

/// A members-only room answers the join with an error presence instead of a
/// self-presence. Treating that as "not ours yet" left the join waiting for a
/// confirmation that was never coming.
@Test
func surfacesRoomRefusalsInsteadOfWaitingForSelfPresence() async throws {
  let socket = ConnectionTestSocket(
    frames: bootstrapFrames(bindID: "bind") + [
      .text("<presence from=\"room@conference.example.test/other\"/>"),
      .text(
        """
        <presence from="room@conference.example.test/native" type="error">
          <error type="auth" code="407">
            <registration-required xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>
            <lobbyroom xmlns="http://jitsi.org/jitmeet">room@lobby.example.test</lobbyroom>
          </error>
        </presence>
        """
      ),
    ]
  )
  let connection = XMPPConnection(
    transport: XMPPWebSocketTransport(socket: socket),
    negotiator: XMPPStreamNegotiator(
      domain: "example.test",
      resource: "native",
      credential: .anonymous,
      bindID: "bind"
    )
  )
  _ = try await connection.connect()

  await #expect(
    throws: MUCJoinError.membersOnly(lobbyRoomJID: "room@lobby.example.test", waitingForHost: false)
  ) {
    try await connection.joinMUC(
      InitialMUCPresence(
        roomJID: "room@conference.example.test",
        nickname: "native",
        displayName: "Native",
        audioMuted: false,
        videoMuted: false,
        sources: [:]
      )
    )
  }
  // Stanzas read past on the way to the refusal are still delivered later.
  #expect(
    try await connection.nextElement()[attribute: "from"]
      == "room@conference.example.test/other")
}

private func bootstrapFrames(bindID: String) -> [XMPPWebSocketMessage] {
  [
    .text(
      """
      <features xmlns="http://etherx.jabber.org/streams"><mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><mechanism>ANONYMOUS</mechanism></mechanisms></features>
      """
    ),
    .text("<success xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\"/>"),
    .text(
      "<features xmlns=\"http://etherx.jabber.org/streams\"><bind xmlns=\"urn:ietf:params:xml:ns:xmpp-bind\"/></features>"
    ),
    .text(
      "<iq id=\"\(bindID)\" type=\"result\"><bind xmlns=\"urn:ietf:params:xml:ns:xmpp-bind\"><jid>guest@example.test/native</jid></bind></iq>"
    ),
  ]
}

private actor ConnectionTestSocket: XMPPTextSocket {
  var sent: [String] = []
  private var frames: [XMPPWebSocketMessage]

  init(frames: [XMPPWebSocketMessage]) {
    self.frames = frames
  }

  func start() {}

  func send(_ text: String) {
    sent.append(text)
  }

  func receive() throws -> XMPPWebSocketMessage {
    guard !frames.isEmpty else { throw ConnectionTestError.noFrame }
    return frames.removeFirst()
  }

  func close() {}
}

private enum ConnectionTestError: Error {
  case noFrame
}
