import JitsiJingle
import JitsiXMPP
import Testing

@testable import JitsiConference

/// Drives a full Jicofo offer through the coordinator and a real WebRTC peer
/// connection, so the Jingle -> SDP -> answer -> session-accept path is
/// exercised end to end rather than one translator at a time.
///
/// The DTLS fingerprint below only has to be well formed: no handshake happens
/// without ICE connectivity, but WebRTC rejects the whole description if the
/// digest is not a 32-byte SHA-256 value.
@Suite
struct CoordinatorNegotiationTests {
  @Test
  func answersJicofoOfferWithASessionAccept() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
    )

    let negotiated = await eventually {
      await harness.events.contains {
        if case .connected(let sessionID) = $0 { return sessionID == "sid-1" }
        return false
      }
    }
    let observed = await harness.events
    #expect(negotiated, "coordinator never reported a negotiated session: \(observed)")

    let accept = await harness.socket.stanzasAfterBootstrap()
      .first { $0.contains("session-accept") }
    let stanza = try #require(accept, "no session-accept was sent")
    #expect(stanza.contains("sid=\"sid-1\""))
    #expect(stanza.contains("responder=\"\(TestConference.responderJID)\""))
    // The answer must carry the client's own transport, not echo Jicofo's.
    #expect(stanza.contains("<fingerprint"))
    #expect(!stanza.contains("remote-a-password"))
  }

  /// Found against a live deployment: WebRTC did not ingest the bridge's
  /// candidates from the inline `a=candidate` lines of the offer, so ICE had no
  /// remote candidates and stayed in `checking`. They must be added explicitly.
  @Test
  func addsTheBridgeCandidatesCarriedInTheSessionInitiate() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }

    // The bundled offer carries a candidate on each of its two contents. Before
    // the fix WebRTC held zero remote candidates and ICE stayed in `checking`;
    // afterwards it holds the ones the coordinator added explicitly.
    let remoteCandidates = await eventually {
      await harness.coordinator.remoteCandidateCount() > 0
    }
    #expect(remoteCandidates, "bridge candidates were not added explicitly")
  }

  @Test
  func emitsNegotiatingBeforeConnected() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }

    let events = await harness.events
    let negotiatingIndex = events.firstIndex {
      if case .negotiating = $0 { return true }
      return false
    }
    let connectedIndex = events.firstIndex {
      if case .connected = $0 { return true }
      return false
    }
    let negotiating = try #require(negotiatingIndex, "no .negotiating event")
    let connected = try #require(connectedIndex, "no .connected event")
    #expect(negotiating < connected)
  }

  /// A camera-off participant has a receive-only video media line. Letting
  /// WebRTC choose a transceiver for the desktop track used to bind it to that
  /// line instead of the one allocated for the new source, leaving the Jingle
  /// source-add with no local sources to describe.
  @Test
  func publishesScreenWhenNoCameraIsAlreadySending() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }

    try await harness.coordinator.publishScreen()

    let sourceAdd = await harness.socket.stanzasAfterBootstrap()
      .first { $0.contains("source-add") }
    let stanza = try #require(sourceAdd, "no source-add was signalled for the desktop track")
    // The video type travels as an XML attribute of <source>, and the content
    // is named by media type — both as lib-jitsi-meet signals a local source.
    #expect(stanza.contains("videoType=\"desktop\""))
    #expect(stanza.contains("name=\"video\""))
    #expect(stanza.contains("name=\"native-v1\""))

    let sharing = await harness.events.contains {
      if case .screenSharingChanged(true) = $0 { return true }
      return false
    }
    #expect(sharing)
  }

  /// The receive loop handles one stanza at a time, so remote updates alone
  /// cannot interleave. The dangerous pair is a *local* publication racing the
  /// loop: `publishScreen` reads the installed remote SDP, derives an expanded
  /// offer from it, and renegotiates, and every `await` in that sequence used
  /// to hand the actor back to an incoming `source-add` that rewrites the very
  /// SDP being derived from. WebRTC then rejects the stale description.
  @Test
  func serializesLocalPublicationAgainstRemoteSourceUpdates() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }

    // Start a local screen publication and flood remote source updates at the
    // same time, so both drivers are inside the coordinator together.
    let coordinator = harness.coordinator
    let publication = Task { try await coordinator.publishScreen() }
    for index in 0..<6 {
      await harness.socket.push(
        TestConference.jingleIQ(
          id: "race-\(index)",
          action: "source-add",
          body: Self.sourceAddContent(mid: "\(20 + index)", ssrc: 7_000 + index)
        )
      )
    }

    try await publication.value

    _ = await eventually {
      await harness.socket.stanzasAfterBootstrap()
        .contains { $0.contains("id=\"race-5\"") && $0.contains("type=\"result\"") }
    }

    // What this test does guard: no negotiation may be corrupted by another
    // one running through it. A `.failed` event here means WebRTC rejected a
    // description that a concurrent sequence had already moved past.
    let failures = await harness.events.filter {
      if case .failed = $0 { return true }
      return false
    }
    #expect(failures.isEmpty, "a negotiation was corrupted by an overlapping one: \(failures)")

    let sharing = await harness.events.contains {
      if case .screenSharingChanged(true) = $0 { return true }
      return false
    }
    #expect(sharing, "screen publication did not survive the overlapping updates")
  }

  @Test
  func handlesABurstOfRemoteSourceUpdates() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }

    // Fire several source updates back to back with no pause between them.
    for index in 0..<6 {
      await harness.socket.push(
        TestConference.jingleIQ(
          id: "source-\(index)",
          action: "source-add",
          body: Self.sourceAddContent(mid: "\(2 + index)", ssrc: 9_000 + index)
        )
      )
    }

    // Every one of them must be acknowledged, and none may leave the session
    // in a failed state.
    #expect(
      await eventually {
        let sent = await harness.socket.stanzasAfterBootstrap()
        return (0..<6).allSatisfy { index in
          sent.contains { $0.contains("id=\"source-\(index)\"") && $0.contains("type=\"result\"") }
        }
      }
    )
    let failures = await harness.events.filter {
      if case .failed = $0 { return true }
      return false
    }
    #expect(failures.isEmpty, "negotiation failed: \(failures)")
  }

  /// Found against a live deployment: right after joining an already-active
  /// meeting, Jicofo sends a second `session-initiate` with a new id (a bridge
  /// reselect / ICE restart). Answering it on the first session's peer
  /// connection fails, so the coordinator must rebuild and answer it fresh.
  @Test
  func acceptsAReplacementSessionWithANewID() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-1", action: "session-initiate", sid: "sid-1", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected(let sid) = $0 { return sid == "sid-1" }
        return false
      }
    }

    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-2", action: "session-initiate", sid: "sid-2", body: bundledOffer)
    )
    let renegotiated = await eventually {
      await harness.events.contains {
        if case .connected(let sid) = $0 { return sid == "sid-2" }
        return false
      }
    }
    let observed = await harness.events
    #expect(renegotiated, "coordinator did not accept the replacement session: \(observed)")
    #expect(
      !observed.contains {
        if case .failed = $0 { return true }
        return false
      },
      "the replacement session reported a failure: \(observed)"
    )

    // The fresh answer references the new session id, not the retired one.
    let accepts = await harness.socket.stanzasAfterBootstrap().filter {
      $0.contains("session-accept")
    }
    #expect(accepts.contains { $0.contains("sid=\"sid-2\"") })
  }

  /// A duplicate `session-initiate` for the session already accepted is just
  /// acknowledged; it must not tear the working connection down and rebuild it.
  @Test
  func ignoresADuplicateSessionInitiate() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-1", action: "session-initiate", sid: "sid-1", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }

    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-1b", action: "session-initiate", sid: "sid-1", body: bundledOffer)
    )
    // It is acknowledged like every IQ...
    #expect(
      await eventually {
        await harness.socket.stanzasAfterBootstrap()
          .contains { $0.contains("id=\"offer-1b\"") && $0.contains("type=\"result\"") }
      }
    )
    // ...but produces exactly one accepted session, not a second one.
    let connectedCount = await harness.events.filter {
      if case .connected = $0 { return true }
      return false
    }.count
    #expect(connectedCount == 1, "a duplicate initiate started a second negotiation")
  }

  /// Mirrors a live deployment: joining a meeting that already has a web
  /// participant, whose sources arrive JSON-encoded in the session-initiate —
  /// no `<source>` XML at all. The expanded offer must negotiate against a
  /// real WebRTC peer connection and produce a session-accept.
  @Test
  func acceptsAnOfferWithJSONEncodedSourcesFromALiveMeeting() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    let body =
      bundledOffer + """
        <json-message xmlns="http://jitsi.org/jitmeet">{"sources":{\
        "web1abcd":[[{"s":111111,"n":"web1abcd-v0","m":"web1abcd-video-1 track-v"},\
        {"s":111112,"n":"web1abcd-v0","m":"web1abcd-video-1 track-v"}],[["f",111111,111112]],\
        [{"s":222222,"n":"web1abcd-a0","m":"web1abcd-audio-1 track-a"}],[]],\
        "jvb":[[],[],[{"s":333333,"n":"jvb-a0","m":"mixedmslabel mixedlabelaudio0"}],[]]}}\
        </json-message>
        """
    await harness.socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: body)
    )

    let negotiated = await eventually {
      await harness.events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }
    let observed = await harness.events
    #expect(negotiated, "the JSON-encoded offer was not negotiated: \(observed)")
    let failures = observed.filter {
      if case .failed = $0 { return true }
      return false
    }
    #expect(failures.isEmpty, "negotiating the JSON-encoded offer failed: \(failures)")

    let accept = await harness.socket.stanzasAfterBootstrap()
      .first { $0.contains("session-accept") }
    let stanza = try #require(accept, "no session-accept was sent")
    #expect(stanza.contains("name=\"audio\""))
    #expect(stanza.contains("name=\"video\""))

    // Each remote video track is attributed to its source and owner, and the
    // bridge's mixed placeholder is flagged so the app can hide it.
    let events = await harness.events
    let streams = events.compactMap { event -> RemoteVideoStream? in
      if case .remoteVideoTrackAdded(let stream) = event { return stream }
      return nil
    }
    let webStream = try #require(
      streams.first { $0.sourceName == "web1abcd-v0" },
      "the web participant's video was not attributed: \(streams.map(\.id))"
    )
    #expect(webStream.endpointID == "web1abcd")
    #expect(webStream.videoType == "camera")
    #expect(!webStream.isBridgePlaceholder)
  }

  /// Jicofo tears the media session down when this client is the only one
  /// left, and re-invites when someone joins again. The client must stay in
  /// the conference and answer the fresh offer on a rebuilt peer connection.
  @Test
  func answersAReinviteAfterTheSessionWasTerminated() async throws {
    let harness = try await NegotiationHarness()
    defer { harness.tearDown() }

    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-1", action: "session-initiate", sid: "sid-1", body: bundledOffer)
    )
    _ = await eventually {
      await harness.events.contains {
        if case .connected(let sid) = $0 { return sid == "sid-1" }
        return false
      }
    }

    // Everyone else leaves: Jicofo expires the session.
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "bye-1",
        action: "session-terminate",
        sid: "sid-1",
        body: "<reason><expired/></reason>"
      )
    )
    _ = await eventually {
      await harness.events.contains {
        if case .remoteSessionEnded(let reason) = $0 { return reason == "expired" }
        return false
      }
    }

    // Someone joins again: Jicofo re-invites with a new session id.
    await harness.socket.push(
      TestConference.jingleIQ(
        id: "offer-2", action: "session-initiate", sid: "sid-2", body: bundledOffer)
    )
    let reconnected = await eventually {
      await harness.events.contains {
        if case .connected(let sid) = $0 { return sid == "sid-2" }
        return false
      }
    }
    let observed = await harness.events
    #expect(reconnected, "the re-invite was not answered: \(observed)")
    #expect(
      !observed.contains {
        if case .failed = $0 { return true }
        return false
      },
      "the re-invite failed: \(observed)"
    )
    let accepts = await harness.socket.stanzasAfterBootstrap().filter {
      $0.contains("session-accept")
    }
    #expect(accepts.contains { $0.contains("sid=\"sid-2\"") })
  }

  /// Mirrors Jicofo: a source-add's content is named by media type — which
  /// media line the source lands on is the client's decision, and each newly
  /// published source gets its own new one.
  private static func sourceAddContent(mid: String, ssrc: Int) -> String {
    """
    <content creator="initiator" name="video" senders="both">
      <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
        <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="\(ssrc)" name="remote-v\(mid)">
          <parameter name="msid" value="remote-stream remote-track-\(ssrc)"/>
          <ssrc-info xmlns="http://jitsi.org/jitmeet" owner="room@conference.example.test/remote"/>
        </source>
      </description>
    </content>
    """
  }
}

/// 32 bytes of SHA-256-shaped digest. Structure is what WebRTC validates.
private let fingerprint = (0..<32)
  .map { String(format: "%02X", ($0 * 7 + 11) % 256) }
  .joined(separator: ":")

private let bundledOffer = """
  <content creator="initiator" name="audio" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2">
        <parameter name="minptime" value="10"/>
        <parameter name="useinbandfec" value="1"/>
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="transport-cc"/>
      </payload-type>
      <rtp-hdrext xmlns="urn:xmpp:jingle:apps:rtp:rtp-hdrext:0" id="1" \
  uri="urn:ietf:params:rtp-hdrext:ssrc-audio-level"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="remotea" \
  pwd="remote-a-password-value">
      <candidate component="1" foundation="1" generation="0" ip="192.0.2.10" port="10000" \
  priority="2130706431" protocol="udp" type="host"/>
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" \
  setup="actpass">\(fingerprint)</fingerprint>
    </transport>
  </content>
  <content creator="initiator" name="video" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
      <payload-type id="96" name="VP8" clockrate="90000">
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="nack"/>
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="nack" subtype="pli"/>
      </payload-type>
      <rtcp-mux/>
      <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="2222">
        <parameter name="cname" value="remote-video"/>
        <parameter name="msid" value="remote-stream remote-track"/>
        <parameter name="name" value="remote-v0"/>
      </source>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="remotev" \
  pwd="remote-v-password-value">
      <candidate component="1" foundation="2" generation="0" ip="198.51.100.8" port="443" \
  priority="1677734911" protocol="udp" type="host"/>
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" \
  setup="actpass">\(fingerprint)</fingerprint>
    </transport>
  </content>
  <group xmlns="urn:xmpp:jingle:apps:grouping:0" semantics="BUNDLE">
    <content name="audio"/>
    <content name="video"/>
  </group>
  """

private struct NegotiationHarness {
  let socket: ScriptedSocket
  let coordinator: NativeJingleCoordinator
  private let log: NegotiationEventLog
  private let pump: Task<Void, Never>

  init() async throws {
    socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    coordinator = try TestConference.coordinator(connection: connection)
    let log = NegotiationEventLog()
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

private actor NegotiationEventLog {
  private(set) var events: [NativeJingleEvent] = []

  func append(_ event: NativeJingleEvent) {
    events.append(event)
  }
}

/// Found against a live Jitsi Videobridge: it takes the remote ICE credentials
/// from every transport update, so a trickled candidate sent without `ufrag`
/// and `pwd` erased the bridge's copy and every one of its connectivity checks
/// then failed with `key=null`. The session-accept alone is not enough.
@Test
func stampsICECredentialsOnEveryTrickledCandidate() async throws {
  let harness = try await NegotiationHarness()
  defer { harness.tearDown() }

  await harness.socket.push(
    TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
  )
  // A real peer connection gathers host candidates as soon as the local
  // description is installed, so transport-info stanzas follow the accept.
  let trickled = await eventually {
    await harness.socket.stanzasAfterBootstrap().contains { $0.contains("transport-info") }
  }
  #expect(trickled, "no candidate was trickled after the session-accept")

  let sent = await harness.socket.stanzasAfterBootstrap()
  let accept = try #require(sent.first { $0.contains("session-accept") })
  let acceptCredentials = try #require(
    ICECredentials(sdp: CoordinatorNegotiationTests.iceLines(in: accept)),
    "could not read ufrag/pwd from the session-accept"
  )
  let candidates = sent.filter { $0.contains("transport-info") }
  #expect(!candidates.isEmpty)
  for stanza in candidates {
    #expect(
      stanza.contains("ufrag=\"\(acceptCredentials.usernameFragment)\""),
      "transport-info without the accept's ufrag: \(stanza.prefix(300))"
    )
    #expect(
      stanza.contains("pwd=\"\(acceptCredentials.password)\""),
      "transport-info without the accept's pwd: \(stanza.prefix(300))"
    )
  }
}

extension CoordinatorNegotiationTests {
  /// Lifts the `ufrag`/`pwd` attributes out of a serialized Jingle stanza into
  /// the SDP attribute form `ICECredentials` parses, so one parser serves both.
  fileprivate static func iceLines(in stanza: String) -> String {
    func attribute(_ name: String) -> String? {
      guard let range = stanza.range(of: "\(name)=\"") else { return nil }
      return String(stanza[range.upperBound...].prefix { $0 != "\"" })
    }
    guard let ufrag = attribute("ufrag"), let pwd = attribute("pwd") else { return "" }
    return "a=ice-ufrag:\(ufrag)\na=ice-pwd:\(pwd)\n"
  }
}
