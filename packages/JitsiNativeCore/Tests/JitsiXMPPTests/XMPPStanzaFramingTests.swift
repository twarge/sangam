import Testing

@testable import JitsiXMPP

// RFC 7395 sends each stanza as a standalone XML document, so a stanza that is
// not explicitly in `jabber:client` draws `unsupported-stanza-type` from a
// WebSocket server. BOSH masked the omission by re-namespacing body children,
// which is why it survived until the first live WebSocket deployment.

@Test
func qualifiesBareStanzasWithTheClientNamespace() async throws {
  let socket = FramingCaptureSocket()
  let transport = XMPPWebSocketTransport(socket: socket)
  try await transport.connect()

  try await transport.send(XMPPElement(name: "iq", attributes: ["id": "x", "type": "set"]))
  try await transport.send(XMPPElement(name: "presence"))
  try await transport.send(XMPPElement(name: "message", attributes: ["to": "a@b"]))

  let sent = await socket.sent
  #expect(sent.count == 3)
  for frame in sent {
    #expect(frame.contains("xmlns=\"jabber:client\""), "unqualified stanza frame: \(frame)")
  }
}

@Test
func leavesExplicitNamespacesAndNonStanzasAlone() async throws {
  let socket = FramingCaptureSocket()
  let transport = XMPPWebSocketTransport(socket: socket)
  try await transport.connect()

  try await transport.send(
    XMPPElement(name: "iq", namespace: "jabber:server", attributes: ["id": "x"])
  )
  try await transport.send(
    XMPPElement(name: "close", namespace: "urn:ietf:params:xml:ns:xmpp-framing")
  )

  let sent = await socket.sent
  #expect(sent[0].contains("xmlns=\"jabber:server\""))
  #expect(!sent[0].contains("jabber:client"))
  #expect(sent[1].contains("xmlns=\"urn:ietf:params:xml:ns:xmpp-framing\""))
}

@Test
func bindsTheResourceInTheClientNamespace() throws {
  var negotiator = XMPPStreamNegotiator(
    domain: "example.test",
    resource: "native",
    credential: .anonymous,
    bindID: "bind-1"
  )
  _ = try negotiator.start()
  _ = try negotiator.receive(
    XMPPParser().parse(
      """
      <features xmlns="http://etherx.jabber.org/streams"><mechanisms \
      xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><mechanism>ANONYMOUS</mechanism>\
      </mechanisms></features>
      """
    )
  )
  _ = try negotiator.receive(
    XMPPParser().parse("<success xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\"/>")
  )
  let actions = try negotiator.receive(
    XMPPParser().parse(
      """
      <features xmlns="http://etherx.jabber.org/streams">\
      <bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"/></features>
      """
    )
  )
  guard case .send(let bindXML) = actions.first else {
    Issue.record("no bind action emitted")
    return
  }
  #expect(bindXML.contains("xmlns=\"jabber:client\""))
  #expect(bindXML.contains("urn:ietf:params:xml:ns:xmpp-bind"))
}

private actor FramingCaptureSocket: XMPPTextSocket {
  private(set) var sent: [String] = []

  func start() {}

  func send(_ text: String) {
    sent.append(text)
  }

  func receive() async throws -> XMPPWebSocketMessage {
    throw FramingCaptureError.noFrames
  }

  func close() {}
}

private enum FramingCaptureError: Error {
  case noFrames
}
