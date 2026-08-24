import JitsiBridge
import JitsiJingle
import JitsiXMPP
import Testing

@testable import JitsiConference

/// Drives an SSRC-rewriting bridge's `VideoSourcesMap`/`AudioSourcesMap`
/// messages through the coordinator and a real WebRTC peer connection. The
/// bridge forwards a fixed set of SSRCs and remaps which conference source
/// each carries; these tests cover the three things a remap must do — create
/// a receive slot for a new SSRC, re-attribute the existing track of a known
/// SSRC, and withdraw the stale tile of a source that moved elsewhere.
@Suite
struct CoordinatorSourceMapTests {
  @Test
  func createsAReceiveSlotForANewVideoSSRC() async throws {
    let harness = try await SourceMapHarness()
    defer { harness.tearDown() }
    try await harness.establishSession()

    await harness.coordinator.handleBridgeChannelEvent(
      .message(
        .sourcesRemapped(
          media: "video",
          sources: [
            MappedSource(
              sourceName: "webabcd12-v0",
              owner: "webabcd12",
              ssrc: 555_001,
              rtxSSRC: 555_002,
              videoType: "camera"
            )
          ]
        )
      )
    )

    // The renegotiated remote description carries the slot's msid, so the
    // WebRTC track surfaces under the slot id, already attributed.
    let attributed = await eventually {
      await harness.events.contains {
        guard case .remoteVideoTrackAdded(let stream) = $0 else { return false }
        return stream.id == "remote-video-1"
          && stream.sourceName == "webabcd12-v0"
          && stream.endpointID == "webabcd12"
          && stream.videoType == "camera"
      }
    }
    let observed = await harness.events
    #expect(attributed, "no attributed track surfaced for the new slot: \(observed)")
    #expect(
      !observed.contains {
        if case .failed = $0 { return true }
        return false
      },
      "the slot renegotiation failed: \(observed)"
    )
  }

  @Test
  func reattributesAKnownSSRCWhenTheBridgeRemapsIt() async throws {
    let harness = try await SourceMapHarness()
    defer { harness.tearDown() }
    try await harness.establishSession()

    await harness.coordinator.handleBridgeChannelEvent(
      .message(
        .sourcesRemapped(
          media: "video",
          sources: [
            MappedSource(sourceName: "webabcd12-v0", owner: "webabcd12", ssrc: 555_001)
          ]
        )
      )
    )
    _ = await eventually {
      await harness.events.contains {
        guard case .remoteVideoTrackAdded(let stream) = $0 else { return false }
        return stream.id == "remote-video-1"
      }
    }

    // The bridge now puts a different participant's source on the same SSRC.
    // The same track must be re-announced under its new owner — a client
    // that keeps the old attribution shows the wrong person, frozen.
    await harness.coordinator.handleBridgeChannelEvent(
      .message(
        .sourcesRemapped(
          media: "video",
          sources: [
            MappedSource(
              sourceName: "other9876-v0",
              owner: "other9876",
              ssrc: 555_001,
              videoType: "desktop"
            )
          ]
        )
      )
    )

    let switched = await eventually {
      await harness.events.contains {
        guard case .remoteVideoTrackAdded(let stream) = $0 else { return false }
        return stream.id == "remote-video-1"
          && stream.sourceName == "other9876-v0"
          && stream.endpointID == "other9876"
          && stream.videoType == "desktop"
      }
    }
    let observed = await harness.events
    #expect(switched, "the remapped track was not re-announced: \(observed)")
  }

  @Test
  func reattributesAnOfferSignaledSSRC() async throws {
    let harness = try await SourceMapHarness()
    defer { harness.tearDown() }
    try await harness.establishSession()

    // SSRC 2222 arrived in the session-initiate (msid track "remote-track").
    // A remap of that SSRC must find the signaled track, not create a slot.
    await harness.coordinator.handleBridgeChannelEvent(
      .message(
        .sourcesRemapped(
          media: "video",
          sources: [
            MappedSource(sourceName: "webabcd12-v0", owner: "webabcd12", ssrc: 2_222)
          ]
        )
      )
    )

    let reattributed = await eventually {
      await harness.events.contains {
        guard case .remoteVideoTrackAdded(let stream) = $0 else { return false }
        return stream.id == "remote-track" && stream.endpointID == "webabcd12"
      }
    }
    let observed = await harness.events
    #expect(reattributed, "the signaled track was not re-attributed: \(observed)")
  }

  @Test
  func withdrawsTheStaleSlotWhenASourceMovesToANewSSRC() async throws {
    let harness = try await SourceMapHarness()
    defer { harness.tearDown() }
    try await harness.establishSession()

    await harness.coordinator.handleBridgeChannelEvent(
      .message(
        .sourcesRemapped(
          media: "video",
          sources: [
            MappedSource(sourceName: "webabcd12-v0", owner: "webabcd12", ssrc: 555_001)
          ]
        )
      )
    )
    _ = await eventually {
      await harness.events.contains {
        guard case .remoteVideoTrackAdded(let stream) = $0 else { return false }
        return stream.id == "remote-video-1"
      }
    }

    // The same source moves onto a brand-new SSRC. Slot 1 still decodes the
    // old SSRC — whatever that now carries — so its tile must be withdrawn.
    await harness.coordinator.handleBridgeChannelEvent(
      .message(
        .sourcesRemapped(
          media: "video",
          sources: [
            MappedSource(sourceName: "webabcd12-v0", owner: "webabcd12", ssrc: 555_003)
          ]
        )
      )
    )

    let withdrawn = await eventually {
      await harness.events.contains {
        if case .remoteVideoTrackRemoved(let id) = $0 { return id == "remote-video-1" }
        return false
      }
    }
    let observed = await harness.events
    #expect(withdrawn, "the stale slot was not withdrawn: \(observed)")
    let movedToNewSlot = await eventually {
      await harness.events.contains {
        guard case .remoteVideoTrackAdded(let stream) = $0 else { return false }
        return stream.id == "remote-video-2" && stream.sourceName == "webabcd12-v0"
      }
    }
    #expect(movedToNewSlot, "the source did not surface on its new slot: \(observed)")
  }

  @Test
  func addsNewAudioSSRCsToTheRemoteDescriptionExactlyOnce() async throws {
    let harness = try await SourceMapHarness()
    defer { harness.tearDown() }
    try await harness.establishSession()

    let map = ColibriMessage.sourcesRemapped(
      media: "audio",
      sources: [
        MappedSource(sourceName: "webabcd12-a0", owner: "webabcd12", ssrc: 666_001)
      ]
    )
    await harness.coordinator.handleBridgeChannelEvent(.message(map))
    // The same map again — the bridge repeats mappings — must not grow the
    // description a second time.
    await harness.coordinator.handleBridgeChannelEvent(.message(map))

    let slotDiagnostics = await harness.events.filter {
      guard case .diagnostic(let message) = $0 else { return false }
      return message.contains("audio slot")
    }
    #expect(
      slotDiagnostics.count == 1,
      "expected exactly one audio slot for a repeated mapping: \(slotDiagnostics)"
    )
    let failures = await harness.events.filter {
      if case .failed = $0 { return true }
      return false
    }
    #expect(failures.isEmpty, "the audio slot renegotiation failed: \(failures)")
  }
}

/// 32 bytes of SHA-256-shaped digest; structure is what WebRTC validates.
private let fingerprint = (0..<32)
  .map { String(format: "%02X", ($0 * 9 + 5) % 256) }
  .joined(separator: ":")

/// A bundled Jicofo offer with one signaled remote video source (SSRC 2222,
/// msid track "remote-track"), the shape an SSRC-rewriting session starts
/// from before any source maps arrive.
private let bundledOffer = """
  <content creator="initiator" name="audio" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="remotea" \
  pwd="remote-a-password-value">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" \
  setup="actpass">\(fingerprint)</fingerprint>
    </transport>
  </content>
  <content creator="initiator" name="video" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
      <payload-type id="96" name="VP8" clockrate="90000"/>
      <rtcp-mux/>
      <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="2222" name="remote-v0">
        <parameter name="msid" value="remote-stream remote-track"/>
      </source>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="remotev" \
  pwd="remote-v-password-value">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" \
  setup="actpass">\(fingerprint)</fingerprint>
    </transport>
  </content>
  <group xmlns="urn:xmpp:jingle:apps:grouping:0" semantics="BUNDLE">
    <content name="audio"/>
    <content name="video"/>
  </group>
  """

private struct SourceMapHarness {
  let socket: ScriptedSocket
  let coordinator: NativeJingleCoordinator
  private let log: SourceMapEventLog
  private let pump: Task<Void, Never>

  init() async throws {
    socket = TestConference.socket()
    let connection = try await TestConference.connectedConnection(socket: socket)
    coordinator = try TestConference.coordinator(connection: connection)
    let log = SourceMapEventLog()
    self.log = log
    let events = coordinator.events
    pump = Task { for await event in events { await log.append(event) } }
    await coordinator.start()
  }

  var events: [NativeJingleEvent] {
    get async { await log.events }
  }

  /// Pushes the session-initiate and waits until the coordinator accepted it,
  /// so source maps land on an established session as they do live.
  func establishSession() async throws {
    await socket.push(
      TestConference.jingleIQ(id: "offer-1", action: "session-initiate", body: bundledOffer)
    )
    let connected = await eventually {
      await events.contains {
        if case .connected = $0 { return true }
        return false
      }
    }
    let observed = await events
    try #require(connected, "the session was never established: \(observed)")
  }

  func tearDown() {
    pump.cancel()
  }
}

private actor SourceMapEventLog {
  private(set) var events: [NativeJingleEvent] = []

  func append(_ event: NativeJingleEvent) {
    events.append(event)
  }
}
