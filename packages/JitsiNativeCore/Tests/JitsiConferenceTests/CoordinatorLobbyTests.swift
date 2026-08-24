import JitsiXMPP
import Testing

@testable import JitsiConference

/// The moderator's side of the lobby: learning the room has one, watching who
/// is waiting, and admitting or turning them away.
@Suite
struct CoordinatorLobbyTests {
  private static let lobbyRoomJID = "room@lobby.example.test"

  @Test
  func moderatorLooksUpTheLobbyAndWatchesIt() async throws {
    let harness = try await LobbyHarness()
    defer { harness.tearDown() }

    try await harness.becomeModeratorWithLobby()

    // Someone knocks: their lobby presence carries the name to show and the
    // address an invitation needs.
    await harness.socket.push(Self.knock(nick: "abcd1234", name: "Guest One"))
    #expect(
      await eventually {
        await harness.events.contains {
          if case .lobbyKnockersChanged(let knockers) = $0 {
            return knockers == [LobbyKnocker(id: "abcd1234", displayName: "Guest One")]
          }
          return false
        }
      }
    )

    // Another moderator looking at the lobby is not a knocker.
    await harness.socket.push(
      """
      <presence from="\(Self.lobbyRoomJID)/other-host">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item affiliation="owner" role="moderator" jid="host2@example.test/h"/>
        </x>
      </presence>
      """
    )
    await harness.socket.push(Self.knock(nick: "efgh5678", name: "Guest Two"))
    #expect(
      await eventually {
        await harness.events.contains {
          if case .lobbyKnockersChanged(let knockers) = $0 { return knockers.count == 2 }
          return false
        }
      }
    )
    let names = await harness.events.compactMap { event -> [String]? in
      if case .lobbyKnockersChanged(let knockers) = event { return knockers.map(\.displayName) }
      return nil
    }
    #expect(names.last == ["Guest One", "Guest Two"])

    // A knocker giving up disappears from the list.
    await harness.socket.push(
      "<presence from=\"\(Self.lobbyRoomJID)/efgh5678\" type=\"unavailable\"/>"
    )
    #expect(
      await eventually {
        await harness.events.contains {
          if case .lobbyKnockersChanged(let knockers) = $0 {
            return knockers.map(\.id) == ["abcd1234"]
          }
          return false
        }
      }
    )
  }

  @Test
  func admitsByInvitingTheKnockerIntoTheMeetingRoom() async throws {
    let harness = try await LobbyHarness()
    defer { harness.tearDown() }
    try await harness.becomeModeratorWithLobby()
    await harness.socket.push(Self.knock(nick: "abcd1234", name: "Guest One"))
    _ = await eventually { await harness.knockerIDs == ["abcd1234"] }

    try await harness.coordinator.admitLobbyParticipant(id: "abcd1234")

    let invite = await harness.socket.stanzasAfterBootstrap().first { $0.contains("<invite") }
    let stanza = try #require(invite, "no invitation was sent")
    #expect(stanza.hasPrefix("<message"))
    #expect(stanza.contains("to=\"\(TestConference.roomJID)\""))
    #expect(stanza.contains("to=\"guest-abcd1234@guest.example.test/abcd1234\""))
  }

  @Test
  func deniesByKickingTheKnockerOutOfTheLobby() async throws {
    let harness = try await LobbyHarness()
    defer { harness.tearDown() }
    try await harness.becomeModeratorWithLobby()
    await harness.socket.push(Self.knock(nick: "abcd1234", name: "Guest One"))
    _ = await eventually { await harness.knockerIDs == ["abcd1234"] }

    let coordinator = harness.coordinator
    let denial = Task { try await coordinator.denyLobbyParticipant(id: "abcd1234") }
    let kick = await eventuallyValue {
      await harness.socket.stanzasAfterBootstrap().first { $0.contains("muc#admin") }
    }
    let stanza = try #require(kick, "no kick was sent")
    #expect(stanza.contains("to=\"\(Self.lobbyRoomJID)\""))
    #expect(stanza.contains("nick=\"abcd1234\""))
    #expect(stanza.contains("role=\"none\""))

    // The denial resolves with the room's answer, routed through the loop.
    let id = try #require(Self.attribute("id", in: stanza))
    await harness.socket.push("<iq from=\"\(Self.lobbyRoomJID)\" id=\"\(id)\" type=\"result\"/>")
    try await denial.value
  }

  @Test
  func surfacesARefusedDenial() async throws {
    let harness = try await LobbyHarness()
    defer { harness.tearDown() }
    try await harness.becomeModeratorWithLobby()
    await harness.socket.push(Self.knock(nick: "abcd1234", name: "Guest One"))
    _ = await eventually { await harness.knockerIDs == ["abcd1234"] }

    let coordinator = harness.coordinator
    let denial = Task { try await coordinator.denyLobbyParticipant(id: "abcd1234") }
    let kick = await eventuallyValue {
      await harness.socket.stanzasAfterBootstrap().first { $0.contains("muc#admin") }
    }
    let kickStanza = try #require(kick, "no kick was sent")
    let id = try #require(Self.attribute("id", in: kickStanza))
    await harness.socket.push(
      """
      <iq from="\(Self.lobbyRoomJID)" id="\(id)" type="error">
        <error type="auth"><forbidden xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error>
      </iq>
      """
    )

    await #expect(throws: XMPPConnectionError.iqError(id: id, condition: "forbidden", text: nil)) {
      try await denial.value
    }
  }

  @Test
  func refusesLobbyActionsFromNonModerators() async throws {
    let harness = try await LobbyHarness()
    defer { harness.tearDown() }

    await #expect(throws: NativeJingleCoordinatorError.notModerator) {
      try await harness.coordinator.admitLobbyParticipant(id: "anyone")
    }
    #expect(await harness.socket.stanzasAfterBootstrap().isEmpty)
  }

  /// The room announces configuration changes without saying what changed;
  /// the lobby being switched off is found by asking again.
  @Test
  func forgetsTheLobbyWhenTheRoomConfigurationDropsIt() async throws {
    let harness = try await LobbyHarness()
    defer { harness.tearDown() }
    try await harness.becomeModeratorWithLobby()
    await harness.socket.push(Self.knock(nick: "abcd1234", name: "Guest One"))
    _ = await eventually { await harness.knockerIDs == ["abcd1234"] }

    await harness.socket.push(
      """
      <message from="\(TestConference.roomJID)" type="groupchat">
        <x xmlns="http://jabber.org/protocol/muc#user"><status code="104"/></x>
      </message>
      """
    )
    let request = await eventuallyValue {
      await harness.socket.stanzasAfterBootstrap().filter { $0.contains("disco#info") }.dropFirst()
        .first
    }
    let lookup = try #require(request, "no second lookup")
    let id = try #require(Self.attribute("id", in: lookup))
    await harness.socket.push(
      """
      <iq from="\(TestConference.roomJID)" id="\(id)" type="result">
        <query xmlns="http://jabber.org/protocol/disco#info">
          <feature var="http://jabber.org/protocol/muc"/>
        </query>
      </iq>
      """
    )

    #expect(
      await eventually {
        await harness.events.contains {
          if case .lobbyEnabledChanged(false) = $0 { return true }
          return false
        }
      }
    )
    #expect(await harness.knockerIDs == [])
    // Leaving the lobby room is part of forgetting it.
    #expect(
      await harness.socket.stanzasAfterBootstrap().contains {
        $0.contains("type=\"unavailable\"") && $0.contains("to=\"\(Self.lobbyRoomJID)/native\"")
      }
    )
  }

  private static func knock(nick: String, name: String) -> String {
    """
    <presence from="\(lobbyRoomJID)/\(nick)" to="\(TestConference.responderJID)">
      <nick xmlns="http://jabber.org/protocol/nick">\(name)</nick>
      <x xmlns="http://jabber.org/protocol/muc#user">
        <item affiliation="none" role="participant" jid="guest-\(nick)@guest.example.test/\(nick)"/>
      </x>
    </presence>
    """
  }

  static func attribute(_ name: String, in stanza: String) -> String? {
    guard let range = stanza.range(of: "\(name)=\"") else { return nil }
    let rest = stanza[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
  }
}

/// Polls `value` until it is non-nil or the budget expires.
func eventuallyValue<T: Sendable>(
  timeout: Duration = .seconds(5),
  _ value: @Sendable () async -> T?
) async -> T? {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if let found = await value() { return found }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await value()
}

private struct LobbyHarness {
  let socket: ScriptedSocket
  let coordinator: NativeJingleCoordinator
  private let log: LobbyEventLog
  private let pump: Task<Void, Never>

  init() async throws {
    socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    coordinator = try TestConference.coordinator(connection: connection)
    let log = LobbyEventLog()
    self.log = log
    let events = coordinator.events
    pump = Task { for await event in events { await log.append(event) } }
    await coordinator.start()
  }

  var events: [NativeJingleEvent] {
    get async { await log.events }
  }

  /// The most recently reported set of knockers.
  var knockerIDs: [String]? {
    get async {
      await events.reversed().lazy.compactMap { event -> [String]? in
        if case .lobbyKnockersChanged(let knockers) = event { return knockers.map(\.id) }
        return nil
      }.first
    }
  }

  /// Plays the room making this client a moderator of a room whose lobby is
  /// on: the self-presence, the room lookup it triggers, and the lobby join.
  func becomeModeratorWithLobby() async throws {
    await coordinator.noteLocalPresence(
      try MUCParticipantPresence(
        element: try XMPPParser().parse(
          """
          <presence from="\(TestConference.roomJID)/native">
            <x xmlns="http://jabber.org/protocol/muc#user">
              <item affiliation="owner" role="moderator"/>
              <status code="110"/>
            </x>
          </presence>
          """
        )
      )
    )
    let request = await eventuallyValue {
      await socket.stanzasAfterBootstrap().first { $0.contains("disco#info") }
    }
    let lookup = try #require(request, "becoming moderator did not look the room up")
    #expect(lookup.contains("to=\"\(TestConference.roomJID)\""))
    let id = try #require(CoordinatorLobbyTests.attribute("id", in: lookup))
    await socket.push(
      """
      <iq from="\(TestConference.roomJID)" id="\(id)" type="result">
        <query xmlns="http://jabber.org/protocol/disco#info">
          <feature var="http://jabber.org/protocol/muc"/>
          <feature var="muc_membersonly"/>
          <x xmlns="jabber:x:data" type="result">
            <field var="muc#roominfo_lobbyroom"><value>room@lobby.example.test</value></field>
          </x>
        </query>
      </iq>
      """
    )
    let joined = await eventually {
      await socket.stanzasAfterBootstrap().contains {
        $0.contains("<presence") && $0.contains("to=\"room@lobby.example.test/native\"")
      }
    }
    #expect(joined, "moderator did not join the lobby room")
    await socket.push(
      """
      <presence from="room@lobby.example.test/native">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item affiliation="owner" role="moderator"/>
          <status code="110"/>
        </x>
      </presence>
      """
    )
  }

  func tearDown() {
    pump.cancel()
  }
}

private actor LobbyEventLog {
  private(set) var events: [NativeJingleEvent] = []

  func append(_ event: NativeJingleEvent) {
    events.append(event)
  }
}
