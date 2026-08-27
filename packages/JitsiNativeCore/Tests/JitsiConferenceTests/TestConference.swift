import Foundation
import JitsiJingle
import JitsiXMPP

@testable import JitsiConference

/// Whether tests may spin up real WebRTC media. `RTCPeerConnectionFactory`
/// initializes a CoreAudio device module, and on a headless CI runner with no
/// audio device that init blocks forever — starving the cooperative pool and
/// freezing every other in-flight test with it. GitHub sets `CI` on runners.
let mediaHardwareAvailable = ProcessInfo.processInfo.environment["CI"] == nil

/// An `XMPPTextSocket` whose incoming frames are supplied by the test rather
/// than a server. `receive()` suspends when the script runs dry, so a
/// coordinator's receive loop parks between stanzas exactly as it would against
/// a live connection.
actor ScriptedSocket: XMPPTextSocket {
  private(set) var sent: [String] = []
  private var frames: [XMPPWebSocketMessage]
  private var waiters: [CheckedContinuation<XMPPWebSocketMessage, any Error>] = []
  private var closed = false

  init(frames: [XMPPWebSocketMessage]) {
    self.frames = frames
  }

  func start() {}

  func send(_ text: String) {
    sent.append(text)
  }

  func receive() async throws -> XMPPWebSocketMessage {
    if !frames.isEmpty { return frames.removeFirst() }
    guard !closed else { throw ScriptedSocketError.closed }
    return try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func close() {
    closed = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume(throwing: ScriptedSocketError.closed) }
  }

  /// Whether a reader is parked waiting for the next frame.
  var isAwaitingFrame: Bool { !waiters.isEmpty }

  var isClosed: Bool { closed }

  /// Delivers a stanza to whichever task is currently reading, or queues it.
  func push(_ xml: String) {
    let frame = XMPPWebSocketMessage.text(xml)
    if waiters.isEmpty {
      frames.append(frame)
    } else {
      waiters.removeFirst().resume(returning: frame)
    }
  }

  /// Everything the client wrote after the four bootstrap frames.
  func stanzasAfterBootstrap() -> [String] {
    Array(sent.dropFirst(TestConference.bootstrapSentFrameCount))
  }
}

enum ScriptedSocketError: Error {
  case closed
}

enum TestConference {
  /// `open`, SASL `auth`, stream restart, and resource `bind`.
  static let bootstrapSentFrameCount = 4

  static let responderJID = "guest@example.test/native"
  static let roomJID = "room@conference.example.test"
  static let focusJID = "focus@example.test/focus"

  static func socket() -> ScriptedSocket {
    ScriptedSocket(frames: [
      .text(
        """
        <features xmlns="http://etherx.jabber.org/streams"><mechanisms \
        xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><mechanism>ANONYMOUS</mechanism>\
        </mechanisms></features>
        """
      ),
      .text("<success xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\"/>"),
      .text(
        """
        <features xmlns="http://etherx.jabber.org/streams">\
        <bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"/></features>
        """
      ),
      .text(
        """
        <iq id="bind-test" type="result"><bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">\
        <jid>\(responderJID)</jid></bind></iq>
        """
      ),
    ])
  }

  static func connectedConnection(socket: ScriptedSocket) async throws -> XMPPConnection {
    let connection = XMPPConnection(
      transport: XMPPWebSocketTransport(socket: socket),
      negotiator: XMPPStreamNegotiator(
        domain: "example.test",
        resource: "native",
        credential: .anonymous,
        bindID: "bind-test"
      )
    )
    _ = try await connection.connect()
    return connection
  }

  static func coordinator(connection: XMPPConnection) throws -> NativeJingleCoordinator {
    try NativeJingleCoordinator(
      connection: connection,
      configuration: NativeJingleConfiguration(
        responderJID: responderJID,
        occupantJID: "\(roomJID)/native"
      )
    )
  }

  /// The focus's occupant in the room. Jicofo joins under the reserved
  /// nickname `focus`, and its Jingle stanzas come from this address.
  static let focusOccupantJID = "\(roomJID)/focus"

  /// A Jingle IQ addressed to the client, wrapping `jingle` payload markup.
  /// Sent from the in-room focus, as a real Jicofo session is.
  static func jingleIQ(
    id: String,
    action: String,
    sid: String = "sid-1",
    from: String = focusOccupantJID,
    body: String = ""
  ) -> String {
    """
    <iq from="\(from)" id="\(id)" to="\(responderJID)" type="set">
      <jingle xmlns="urn:xmpp:jingle:1" action="\(action)" initiator="\(from)" \
    sid="\(sid)">\(body)</jingle>
    </iq>
    """
  }
}

/// Polls `condition` until it holds or the budget expires. Used instead of a
/// fixed sleep so the tests stay fast when the coordinator reacts promptly and
/// still fail loudly when it never does.
func eventually(
  timeout: Duration = .seconds(5),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}
