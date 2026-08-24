import Foundation
import Testing

@testable import JitsiXMPP

@Test
func negotiatesAnonymousSASLAndResourceBinding() throws {
  var negotiator = XMPPStreamNegotiator(
    domain: "meet.example.test",
    resource: "gafsaf-device",
    credential: .anonymous,
    bindID: "bind-7"
  )

  let start = try negotiator.start()
  #expect(start == [.send(XMPPStreamNegotiator.openFrame(domain: "meet.example.test"))])

  let preAuth = try XMPPParser().parse(
    """
    <features xmlns="http://etherx.jabber.org/streams">
      <mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
        <mechanism>ANONYMOUS</mechanism>
      </mechanisms>
    </features>
    """
  )
  let authentication = try negotiator.receive(preAuth)
  #expect(authentication.first?.xml?.contains("mechanism=\"ANONYMOUS\"") == true)

  let success = try XMPPParser().parse(
    "<success xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\"/>"
  )
  #expect(try negotiator.receive(success).count == 1)

  let postAuth = try XMPPParser().parse(
    """
    <features xmlns="http://etherx.jabber.org/streams">
      <bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"/>
    </features>
    """
  )
  let binding = try negotiator.receive(postAuth)
  #expect(binding.first?.xml?.contains("id=\"bind-7\"") == true)
  #expect(binding.first?.xml?.contains("gafsaf-device") == true)

  let result = try XMPPParser().parse(
    """
    <iq id="bind-7" type="result">
      <bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">
        <jid>guest@meet.example.test/gafsaf-device</jid>
      </bind>
    </iq>
    """
  )
  #expect(
    try negotiator.receive(result) == [.ready(jid: "guest@meet.example.test/gafsaf-device")]
  )
  #expect(negotiator.state == .ready(jid: "guest@meet.example.test/gafsaf-device"))
}

@Test
func refusesUnavailableAuthenticationMechanism() throws {
  var negotiator = XMPPStreamNegotiator(
    domain: "meet.example.test",
    resource: "native",
    credential: .anonymous
  )
  _ = try negotiator.start()
  let features = try XMPPParser().parse(
    """
    <features xmlns="http://etherx.jabber.org/streams">
      <mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
        <mechanism>PLAIN</mechanism>
      </mechanisms>
    </features>
    """
  )
  #expect(throws: XMPPNegotiationError.missingMechanism("ANONYMOUS")) {
    try negotiator.receive(features)
  }
}

@Test
func plainAuthenticationDoesNotLeakRawPassword() throws {
  var negotiator = XMPPStreamNegotiator(
    domain: "meet.example.test",
    resource: "native",
    credential: .plain(username: "person", password: "sensitive")
  )
  _ = try negotiator.start()
  let features = try XMPPParser().parse(
    """
    <features xmlns="http://etherx.jabber.org/streams">
      <mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
        <mechanism>PLAIN</mechanism>
      </mechanisms>
    </features>
    """
  )
  let action = try negotiator.receive(features)
  let xml = try #require(action.first?.xml)
  #expect(!xml.contains("sensitive"))
  #expect(xml.contains(Data("\0person\0sensitive".utf8).base64EncodedString()))
}

@Test
func transportEnforcesConnectionAndFrameBounds() async throws {
  let socket = RecordingSocket(receiveMessages: [.text("<presence/>")])
  let transport = XMPPWebSocketTransport(socket: socket, maximumFrameBytes: 32)

  await #expect(throws: XMPPTransportError.notConnected) {
    try await transport.send("<presence/>")
  }

  try await transport.connect()
  try await transport.send("<presence/>")
  #expect(try await transport.receive().name == "presence")
  await #expect(throws: XMPPTransportError.frameTooLarge(limit: 32)) {
    try await transport.send(String(repeating: "x", count: 33))
  }
  await transport.close()

  #expect(await socket.sent == ["<presence/>"])
  #expect(await socket.startCount == 1)
  #expect(await socket.closeCount == 1)
}

extension XMPPNegotiationAction {
  fileprivate var xml: String? {
    guard case .send(let xml) = self else { return nil }
    return xml
  }
}

private actor RecordingSocket: XMPPTextSocket {
  var sent: [String] = []
  var startCount = 0
  var closeCount = 0
  private var receiveMessages: [XMPPWebSocketMessage]

  init(receiveMessages: [XMPPWebSocketMessage]) {
    self.receiveMessages = receiveMessages
  }

  func start() {
    startCount += 1
  }

  func send(_ text: String) {
    sent.append(text)
  }

  func receive() throws -> XMPPWebSocketMessage {
    guard !receiveMessages.isEmpty else { throw TestSocketError.noMessage }
    return receiveMessages.removeFirst()
  }

  func close() {
    closeCount += 1
  }
}

private enum TestSocketError: Error {
  case noMessage
}
