import JitsiXMPP
import Testing

@testable import JitsiConference

/// The joiner's side of the lobby: knock, wait, and act on the moderator's
/// decision. Driven through a scripted socket so each outcome is exercised
/// against the exact stanzas Prosody's lobby module sends.
@Suite
struct LobbyAdmissionTests {
  private static let lobbyRoomJID = "room@lobby.example.test"

  @Test
  func knocksAndJoinsWhenInvited() async throws {
    let socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    let lobby = Self.admission(connection: connection)
    let waiting = Task { try await lobby.wait() }

    // The knock is a plain join of the lobby room carrying the display name.
    #expect(
      await eventually {
        await socket.stanzasAfterBootstrap().contains {
          $0.contains("<presence") && $0.contains("to=\"\(Self.lobbyRoomJID)/native\"")
            && $0.contains("Guest One")
        }
      }
    )
    await socket.push(Self.lobbySelfPresence())
    // Something unrelated must not end the wait, and the server's probes are
    // still answered while waiting.
    await socket.push(
      """
      <iq from="example.test" id="ping-1" to="\(TestConference.responderJID)" type="get">
        <ping xmlns="urn:xmpp:ping"/>
      </iq>
      """
    )
    #expect(
      await eventually {
        await socket.stanzasAfterBootstrap().contains {
          $0.contains("id=\"ping-1\"") && $0.contains("type=\"result\"")
        }
      }
    )
    await socket.push(
      """
      <message from="\(TestConference.roomJID)" to="\(TestConference.responderJID)">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <invite from="host@example.test/host"><reason/></invite>
        </x>
      </message>
      """
    )

    #expect(try await waiting.value == .admitted(password: nil))
  }

  @Test
  func reportsDenialWhenKickedOutOfTheLobby() async throws {
    let socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    let waiting = Task { try await Self.admission(connection: connection).wait() }

    await socket.push(Self.lobbySelfPresence())
    // Another knocker leaving is not about us.
    await socket.push(
      "<presence from=\"\(Self.lobbyRoomJID)/someone-else\" type=\"unavailable\"/>"
    )
    await socket.push(
      """
      <presence from="\(Self.lobbyRoomJID)/native" type="unavailable">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item affiliation="none" role="none"><reason>Not admitted.</reason></item>
          <status code="110"/>
          <status code="307"/>
        </x>
      </presence>
      """
    )

    await #expect(throws: LobbyAdmissionError.accessDenied) {
      try await waiting.value
    }
  }

  @Test
  func joinsDirectlyWhenTheLobbyIsSwitchedOff() async throws {
    let socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    let waiting = Task { try await Self.admission(connection: connection).wait() }

    await socket.push(Self.lobbySelfPresence())
    await socket.push(
      """
      <presence from="\(Self.lobbyRoomJID)/native" type="unavailable">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item affiliation="none" role="none"/>
          <destroy jid="\(TestConference.roomJID)"><reason>Lobby room closed.</reason></destroy>
          <status code="110"/>
        </x>
      </presence>
      """
    )

    #expect(try await waiting.value == .lobbyDisabled)
  }

  @Test
  func reportsTheMeetingEndingWhileWaiting() async throws {
    let socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    let waiting = Task { try await Self.admission(connection: connection).wait() }

    await socket.push(Self.lobbySelfPresence())
    await socket.push(
      """
      <presence from="\(Self.lobbyRoomJID)/native" type="unavailable">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item affiliation="none" role="none"/>
          <destroy><reason>Lobby room closed.</reason></destroy>
          <status code="110"/>
        </x>
      </presence>
      """
    )

    #expect(try await waiting.value == .meetingEnded(reason: "Lobby room closed."))
  }

  @Test
  func surfacesTheLobbyRefusingTheKnock() async throws {
    let socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    let waiting = Task { try await Self.admission(connection: connection).wait() }

    await socket.push(
      """
      <presence from="\(Self.lobbyRoomJID)/native" type="error">
        <error type="cancel"><not-allowed xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error>
      </presence>
      """
    )

    await #expect(throws: MUCJoinError.notAllowed(text: nil)) {
      try await waiting.value
    }
  }

  /// Leaving while parked in the lobby has to end the wait promptly and take
  /// the connection down with it; a read blocked on a quiet socket would
  /// otherwise keep a ghost knocker in the lobby for as long as the process
  /// lives.
  @Test
  func cancellationClosesTheConnectionAndEndsTheWait() async throws {
    let socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    let waiting = Task { try await Self.admission(connection: connection).wait() }

    await socket.push(Self.lobbySelfPresence())
    _ = await eventually { await socket.isAwaitingFrame }
    waiting.cancel()

    await #expect(throws: CancellationError.self) {
      try await waiting.value
    }
    #expect(await socket.isClosed)
  }

  private static func admission(connection: XMPPConnection) -> LobbyAdmission {
    LobbyAdmission(
      connection: connection,
      lobbyRoomJID: lobbyRoomJID,
      meetingRoomJID: TestConference.roomJID,
      nickname: "native",
      displayName: "Guest One"
    )
  }

  private static func lobbySelfPresence() -> String {
    """
    <presence from="\(lobbyRoomJID)/native" to="\(TestConference.responderJID)">
      <x xmlns="http://jabber.org/protocol/muc#user">
        <item affiliation="none" role="participant"/>
        <status code="110"/>
      </x>
    </presence>
    """
  }
}
