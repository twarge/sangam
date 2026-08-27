import JitsiJingle
import JitsiXMPP
import Testing

@testable import JitsiConference

/// Exercises the coordinator's signaling contract with Jicofo: what it
/// acknowledges, what it reports, and what it refuses. These paths run before
/// any SDP is installed, so they do not depend on a negotiable transport.
@Suite
struct CoordinatorSignalingTests {
  @Test
  func acknowledgesSessionInitiateBeforeAttemptingNegotiation() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    // The fixture carries a placeholder DTLS fingerprint, so negotiation cannot
    // succeed. Jicofo still has to see an acknowledgement, otherwise it retries
    // the offer forever.
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-1",
        action: "session-initiate",
        body: Self.audioContent
      )
    )

    #expect(
      await eventually {
        await harness.socket.stanzasAfterBootstrap()
          .contains { $0.contains("id=\"offer-1\"") && $0.contains("type=\"result\"") }
      }
    )
  }

  @Test
  func reportsUnsupportedJingleActionsAndStillAcknowledgesThem() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(id: "add-1", action: "content-add")
    )

    #expect(
      await eventually {
        await harness.events.contains {
          if case .unsupportedAction(.contentAdd) = $0 { return true }
          return false
        }
      }
    )
    #expect(
      await harness.socket.stanzasAfterBootstrap()
        .contains { $0.contains("id=\"add-1\"") && $0.contains("type=\"result\"") }
    )
  }

  @Test
  func endsTheSessionWhenTheRemoteTerminatesIt() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(
        id: "bye-1",
        action: "session-terminate",
        body: "<reason><gone/></reason>"
      )
    )

    #expect(
      await eventually {
        await harness.events.contains {
          if case .remoteSessionEnded(let reason) = $0 { return reason == "gone" }
          return false
        }
      }
    )
  }

  @Test
  func answersServiceDiscoveryWithoutTreatingItAsJingle() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    await harness.socket.push(
      """
      <iq from="\(TestConference.focusJID)" id="disco-1" \
      to="\(TestConference.responderJID)" type="get">
        <query xmlns="http://jabber.org/protocol/disco#info"/>
      </iq>
      """
    )

    #expect(
      await eventually {
        await harness.socket.stanzasAfterBootstrap().contains {
          $0.contains("id=\"disco-1\"") && $0.contains("disco#info")
            && $0.contains("type=\"result\"")
        }
      }
    )
    #expect(await harness.events.isEmpty)
  }

  /// The counterpart to the resilience below: a session that cannot be
  /// accepted leaves no media path at all, so it must still be reported as a
  /// failure rather than shrugged off.
  @Test
  func reportsFailureWhenTheOfferedSessionCannotBeAccepted() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    // The placeholder fingerprint in this fixture is not a SHA-256 digest, so
    // WebRTC refuses the description.
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-1",
        action: "session-initiate",
        body: Self.audioContent
      )
    )

    #expect(
      await eventually {
        await harness.events.contains {
          if case .failed = $0 { return true }
          return false
        }
      }
    )
  }

  /// A stanza the coordinator cannot process used to break out of the receive
  /// loop, which ends the conference for everyone. Only a dead transport or a
  /// rejected session-initiate should do that.
  @Test
  func keepsReadingAfterAStanzaItCannotProcess() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    // A source-add naming media that no offer ever established: the update
    // cannot be applied, because no session has been negotiated at all.
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "bad-1",
        action: "source-add",
        body: """
          <content creator="initiator" name="99" senders="both">
            <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
              <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="1"/>
            </description>
          </content>
          """
      )
    )
    #expect(
      await eventually {
        await harness.events.contains {
          if case .warning = $0 { return true }
          return false
        }
      }
    )

    // The loop must still be alive: a following stanza is answered normally.
    await harness.socket.push(
      TestConference.jingleIQ(id: "after-1", action: "content-add")
    )
    #expect(
      await eventually {
        await harness.socket.stanzasAfterBootstrap()
          .contains { $0.contains("id=\"after-1\"") && $0.contains("type=\"result\"") }
      },
      "the receive loop stopped after a message it could not process"
    )

    let ended = await harness.events.contains {
      switch $0 {
      case .failed, .remoteSessionEnded: return true
      default: return false
      }
    }
    #expect(!ended, "an unprocessable message ended the conference")
  }

  /// Found against a live deployment: a second participant's web client tries
  /// a direct peer-to-peer session when only two people are in the room. The
  /// bridge-only native client must not answer a peer's offer — sending it an
  /// SDP it cannot apply crashes its whole conference. It declines instead.
  @Test
  func declinesAPeerToPeerSessionInitiateFromAnotherParticipant() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    // A P2P offer comes from a peer's occupant, not from the room's focus.
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "p2p-1",
        action: "session-initiate",
        sid: "p2psid",
        from: "\(TestConference.roomJID)/72dcd87f",
        body: Self.audioContent
      )
    )

    // It is acknowledged and then declined with a session-terminate...
    let declined = await eventuallyValue {
      await harness.socket.stanzasAfterBootstrap()
        .first { $0.contains("session-terminate") }
    }
    let terminate = try #require(declined, "the peer-to-peer offer was not declined")
    #expect(terminate.contains("<decline"))
    #expect(terminate.contains("to=\"\(TestConference.roomJID)/72dcd87f\""))
    #expect(terminate.contains("sid=\"p2psid\""))

    // ...and it must never be accepted or reported as a media session.
    #expect(
      await harness.socket.stanzasAfterBootstrap().allSatisfy { !$0.contains("session-accept") }
    )
    let started = await harness.events.contains {
      switch $0 {
      case .connected, .negotiating, .failed: return true
      default: return false
      }
    }
    #expect(!started, "a peer-to-peer offer started or failed a media session")
  }

  /// The other half of the P2P defence: a peer does not only offer a session,
  /// it also trickles that session's ICE candidates and eventually terminates
  /// it. None of those may touch the bridge session — a peer's candidate fails
  /// to apply to the bridge connection ("Error processing ICE candidate"), and
  /// honouring a peer's terminate would tear the bridge session down.
  @Test
  func ignoresBridgeJingleActionsFromNonFocusOccupants() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    let peer = "\(TestConference.roomJID)/72dcd87f"
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "peer-cand",
        action: "transport-info",
        from: peer,
        body: """
          <content creator="initiator" name="audio">
            <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="pu" pwd="ppwd">
              <candidate component="1" foundation="1" generation="0" ip="192.0.2.10" port="10000" \
          priority="2130706431" protocol="udp" type="host"/>
            </transport>
          </content>
          """
      )
    )
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "peer-term",
        action: "session-terminate",
        from: peer,
        body: "<reason><success/></reason>"
      )
    )

    // Both are acknowledged at the transport level, as any received IQ is...
    #expect(
      await eventually {
        let sent = await harness.socket.stanzasAfterBootstrap()
        return sent.contains { $0.contains("id=\"peer-cand\"") && $0.contains("type=\"result\"") }
          && sent.contains { $0.contains("id=\"peer-term\"") && $0.contains("type=\"result\"") }
      }
    )
    // ...but neither disturbs the bridge session: no end, no processing warning.
    let disturbed = await harness.events.contains {
      switch $0 {
      case .remoteSessionEnded, .warning, .failed: return true
      default: return false
      }
    }
    #expect(!disturbed, "a non-focus Jingle stanza disturbed the bridge session")
  }

  /// Sharing with no media session live (alone in the meeting) arms the share
  /// instead of failing; nothing is signalled until a session exists.
  @Test
  func armsScreenShareBeforeASessionExists() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    try await harness.coordinator.publishScreen()

    #expect(
      await eventually {
        await harness.events.contains {
          if case .screenSharingChanged(true) = $0 { return true }
          return false
        }
      }
    )
    #expect(
      await harness.socket.stanzasAfterBootstrap().allSatisfy { !$0.contains("source-add") },
      "an armed share was signalled without a session"
    )
  }

  /// Other occupants' presences build the participant roster — with the
  /// focus (Jicofo) excluded, since it is infrastructure, not a person.
  @Test
  func tracksRoomParticipantsFromPresence() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    await harness.socket.push(
      """
      <presence from="\(TestConference.roomJID)/focus" to="\(TestConference.responderJID)">
        <x xmlns="http://jabber.org/protocol/muc#user">\
      <item role="moderator" affiliation="owner"/></x>
      </presence>
      """
    )
    await harness.socket.push(
      """
      <presence from="\(TestConference.roomJID)/72dcd87f" to="\(TestConference.responderJID)">
        <nick xmlns="http://jabber.org/protocol/nick">Ada</nick>
        <audiomuted>true</audiomuted>
        <x xmlns="http://jabber.org/protocol/muc#user">\
      <item role="participant" affiliation="member"/></x>
      </presence>
      """
    )
    #expect(
      await eventually {
        await harness.events.contains {
          if case .participantsChanged(let list) = $0 {
            return list == [
              RemoteParticipant(
                id: "72dcd87f",
                displayName: "Ada",
                audioMuted: true,
                videoMuted: false,
                isModerator: false,
                handRaised: false,
                realJID: nil
              )
            ]
          }
          return false
        }
      }
    )

    await harness.socket.push(
      """
      <presence from="\(TestConference.roomJID)/72dcd87f" \
      to="\(TestConference.responderJID)" type="unavailable"/>
      """
    )
    #expect(
      await eventually {
        await harness.events.contains {
          if case .participantsChanged(let list) = $0 { return list.isEmpty }
          return false
        }
      }
    )
    let sawFocus = await harness.events.contains {
      if case .participantsChanged(let list) = $0 {
        return list.contains { $0.id == "focus" }
      }
      return false
    }
    #expect(!sawFocus, "the focus occupant was listed as a participant")
  }

  /// The room grants moderator to a remaining occupant when the previous
  /// moderator leaves; the promotion must surface as an event.
  @Test
  func reportsModeratorStatusWhenTheRoomPromotesUs() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    await harness.socket.push(
      """
      <presence from="\(TestConference.roomJID)/native" to="\(TestConference.responderJID)">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item role="moderator" affiliation="owner"/>
          <status code="110"/>
        </x>
      </presence>
      """
    )
    #expect(
      await eventually {
        await harness.events.contains {
          if case .moderatorStatusChanged(true) = $0 { return true }
          return false
        }
      }
    )
  }

  @Test
  func sendsAndReceivesGroupChat() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    try await harness.coordinator.sendChatMessage("Hello from native")
    #expect(
      await eventually {
        await harness.socket.stanzasAfterBootstrap().contains {
          $0.contains("type=\"groupchat\"") && $0.contains("Hello from native")
        }
      }
    )
    // The local message is reported back for the sender's own transcript.
    #expect(
      await eventually {
        await harness.events.contains {
          if case .chatMessageReceived(let message) = $0 {
            return message.isLocal && message.text == "Hello from native"
          }
          return false
        }
      }
    )

    await harness.socket.push(
      """
      <message from="\(TestConference.roomJID)/72dcd87f" type="groupchat" id="m1">
        <body>hi native</body>
      </message>
      """
    )
    // The room reflects our own message back; that echo must not be repeated.
    await harness.socket.push(
      """
      <message from="\(TestConference.roomJID)/native" type="groupchat" id="echo1">
        <body>Hello from native</body>
      </message>
      """
    )
    await harness.socket.push(
      """
      <message from="\(TestConference.roomJID)/72dcd87f" type="groupchat" id="m2">
        <body>marker</body>
      </message>
      """
    )
    #expect(
      await eventually {
        await harness.events.contains {
          if case .chatMessageReceived(let message) = $0 { return message.text == "marker" }
          return false
        }
      }
    )
    let received = await harness.events.compactMap { event -> ChatMessage? in
      if case .chatMessageReceived(let message) = event { return message }
      return nil
    }
    #expect(
      received.contains {
        !$0.isLocal && $0.text == "hi native" && $0.senderEndpointID == "72dcd87f"
      }
    )
    #expect(
      !received.contains { !$0.isLocal && $0.text == "Hello from native" },
      "the room's echo of the local message was reported twice"
    )
  }

  @Test
  func raisesAndLowersTheHandInPresence() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    await harness.coordinator.setHandRaised(true)
    #expect(
      await eventually {
        await harness.socket.stanzasAfterBootstrap().contains {
          $0.contains("jitsi_participant_raisedHand")
        }
      }
    )

    await harness.coordinator.setHandRaised(false)
    #expect(
      await eventually {
        let presences = await harness.socket.stanzasAfterBootstrap().filter {
          $0.contains("<presence")
        }
        // A presence update replaces the previous one, so lowering the hand
        // means the newest presence no longer carries the property.
        return presences.count >= 2
          && presences.last?.contains("jitsi_participant_raisedHand") == false
      }
    )
  }

  @Test
  func moderatorCanKickAndPromoteParticipants() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    // Moderation is refused until the room grants the role.
    await #expect(throws: NativeJingleCoordinatorError.notModerator) {
      try await harness.coordinator.kickParticipant(id: "72dcd87f")
    }

    await harness.socket.push(
      """
      <presence from="\(TestConference.roomJID)/native" to="\(TestConference.responderJID)">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item role="moderator" affiliation="owner"/>
          <status code="110"/>
        </x>
      </presence>
      """
    )
    await harness.socket.push(
      """
      <presence from="\(TestConference.roomJID)/72dcd87f" to="\(TestConference.responderJID)">
        <nick xmlns="http://jabber.org/protocol/nick">Ada</nick>
        <x xmlns="http://jabber.org/protocol/muc#user">\
      <item role="participant" affiliation="member" jid="ada@example.test/web"/></x>
      </presence>
      """
    )
    _ = await eventually {
      await harness.events.contains {
        if case .participantsChanged(let list) = $0 { return !list.isEmpty }
        return false
      }
    }

    // Kick: a muc#admin role change addressed by nickname.
    let kick = Task { try await harness.coordinator.kickParticipant(id: "72dcd87f") }
    let kickStanza = await eventuallyValue {
      await harness.socket.stanzasAfterBootstrap().first {
        $0.contains("role=\"none\"") && $0.contains("nick=\"72dcd87f\"")
      }
    }
    let kickIQ = try #require(kickStanza, "no kick IQ was sent")
    await harness.socket.push(
      "<iq from=\"\(TestConference.roomJID)\" id=\"\(Self.stanzaID(of: kickIQ))\" type=\"result\"/>"
    )
    try await kick.value

    // Grant moderator: an affiliation change addressed by real JID.
    let grant = Task { try await harness.coordinator.grantModerator(id: "72dcd87f") }
    let grantStanza = await eventuallyValue {
      await harness.socket.stanzasAfterBootstrap().first {
        $0.contains("affiliation=\"owner\"") && $0.contains("jid=\"ada@example.test/web\"")
      }
    }
    let grantIQ = try #require(grantStanza, "no grant-moderator IQ was sent")
    await harness.socket.push(
      "<iq from=\"\(TestConference.roomJID)\" id=\"\(Self.stanzaID(of: grantIQ))\" type=\"result\"/>"
    )
    try await grant.value
  }

  /// The bridge's sender constraints: 0 pauses (nobody is watching), any
  /// positive height caps, and -1 means UNCONSTRAINED — the value the web
  /// client sets for the source it features on stage. Pausing on -1 froze
  /// stage sources after one keyframe.
  @Test
  func treatsNegativeSenderConstraintAsUnconstrained() {
    #expect(!NativeJingleCoordinator.senderConstraintAllowsSending(maxHeight: 0))
    #expect(NativeJingleCoordinator.senderConstraintAllowsSending(maxHeight: -1))
    #expect(NativeJingleCoordinator.senderConstraintAllowsSending(maxHeight: 180))
    #expect(NativeJingleCoordinator.senderConstraintAllowsSending(maxHeight: 2160))
  }

  /// The `id` attribute of a serialized stanza.
  private static func stanzaID(of stanza: String) -> String {
    guard let range = stanza.range(of: "id=\"") else { return "" }
    return String(stanza[range.upperBound...].prefix { $0 != "\"" })
  }

  @Test
  func publishesMicrophoneStateAsSourcePresence() async throws {
    let harness = try await Harness()
    defer { harness.tearDown() }

    await harness.coordinator.setMicrophoneMuted(true)

    let presence = await harness.socket.stanzasAfterBootstrap()
      .first { $0.contains("<presence") }
    let stanza = try #require(presence)
    #expect(stanza.contains("\(TestConference.roomJID)/native"))
    #expect(stanza.contains("<audiomuted"))
  }

  private static let audioContent = """
    <content creator="initiator" name="audio" senders="both">
      <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
        <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
        <rtcp-mux/>
      </description>
      <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="remote-a" \
    pwd="remote-a-password">
        <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" \
    setup="actpass">AA:BB:CC:DD</fingerprint>
      </transport>
    </content>
    """
}

/// One connected coordinator wired to a scripted socket, with its event stream
/// drained into a list the tests can assert against.
private struct Harness {
  let socket: ScriptedSocket
  let coordinator: NativeJingleCoordinator
  private let log: EventLog
  private let pump: Task<Void, Never>

  init() async throws {
    socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    coordinator = try TestConference.coordinator(connection: connection)
    let log = EventLog()
    self.log = log
    let events = coordinator.events
    pump = Task { for await event in events { await log.append(event) } }
    await coordinator.start()
  }

  var events: [NativeJingleEvent] {
    get async { await log.events }
  }

  func tearDown() {
    pump.cancel()
  }
}

private actor EventLog {
  private(set) var events: [NativeJingleEvent] = []

  func append(_ event: NativeJingleEvent) {
    events.append(event)
  }
}
