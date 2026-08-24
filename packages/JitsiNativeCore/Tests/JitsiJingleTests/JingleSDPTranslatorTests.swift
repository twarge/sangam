import Testing

@testable import JitsiJingle
@testable import JitsiXMPP

private let nativeOffer = """
  <jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" initiator="focus@example.test/focus" sid="native-1">
    <content creator="initiator" name="audio" senders="both">
      <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
        <payload-type id="111" name="opus" clockrate="48000" channels="2">
          <parameter name="minptime" value="10"/>
          <parameter name="useinbandfec" value="1"/>
          <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="transport-cc"/>
        </payload-type>
        <rtp-hdrext xmlns="urn:xmpp:jingle:apps:rtp:rtp-hdrext:0" id="1" uri="urn:ietf:params:rtp-hdrext:ssrc-audio-level"/>
        <rtcp-mux/>
      </description>
      <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="remote-a" pwd="remote-a-password">
        <candidate component="1" foundation="1" generation="0" ip="192.0.2.10" port="10000" priority="2130706431" protocol="udp" type="host"/>
        <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" setup="actpass">AA:BB:CC:DD</fingerprint>
      </transport>
    </content>
    <content creator="initiator" name="video" senders="both">
      <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
        <payload-type id="96" name="VP8" clockrate="90000">
          <parameter name="x-google-start-bitrate" value="800"/>
          <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="nack"/>
          <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="nack" subtype="pli"/>
        </payload-type>
        <rtp-hdrext xmlns="urn:xmpp:jingle:apps:rtp:rtp-hdrext:0" id="5" uri="http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"/>
        <extmap-allow-mixed xmlns="urn:xmpp:jingle:apps:rtp:rtp-hdrext:0"/>
        <rtcp-mux/>
        <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="2222">
          <parameter name="cname" value="remote-video"/>
          <parameter name="msid" value="remote-stream remote-track"/>
          <parameter name="name" value="remote-v0"/>
          <parameter name="videoType" value="desktop"/>
        </source>
        <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="3333">
          <parameter name="cname" value="remote-video"/>
        </source>
        <ssrc-group xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" semantics="FID">
          <source ssrc="2222"/>
          <source ssrc="3333"/>
        </ssrc-group>
      </description>
      <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="remote-v" pwd="remote-v-password">
        <candidate component="1" foundation="2" generation="1" ip="198.51.100.8" port="443" priority="1677734911" protocol="tcp" rel-addr="10.0.0.2" rel-port="50000" tcptype="passive" type="srflx"/>
        <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" setup="actpass">11:22:33:44</fingerprint>
      </transport>
    </content>
    <group xmlns="urn:xmpp:jingle:apps:grouping:0" semantics="BUNDLE">
      <content name="audio"/>
      <content name="video"/>
    </group>
  </jingle>
  """

private let nativeAnswer = """
  v=0
  o=- 2 2 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE audio video
  m=audio 9 UDP/TLS/RTP/SAVPF 111
  c=IN IP4 0.0.0.0
  a=mid:audio
  a=sendrecv
  a=rtcp-mux
  a=rtpmap:111 opus/48000/2
  a=fmtp:111 minptime=10;useinbandfec=1
  a=rtcp-fb:111 transport-cc
  a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
  a=ice-ufrag:local-a
  a=ice-pwd:local-a-password
  a=fingerprint:sha-256 EE:FF:00:11
  a=setup:active
  a=candidate:3 1 udp 2130706431 192.0.2.20 50000 typ host generation 0
  a=ssrc:1111 cname:local-audio
  a=ssrc:1111 msid:local-stream local-audio-track
  m=video 9 UDP/TLS/RTP/SAVPF 96
  c=IN IP4 0.0.0.0
  a=mid:video
  a=sendrecv
  a=rtcp-mux
  a=extmap-allow-mixed
  a=rtpmap:96 VP8/90000
  a=fmtp:96 x-google-start-bitrate=800
  a=rtcp-fb:96 nack
  a=rtcp-fb:96 nack pli
  a=extmap:5 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
  a=ice-ufrag:local-v
  a=ice-pwd:local-v-password
  a=fingerprint:sha-256 EE:FF:00:11
  a=setup:active
  a=candidate:4 1 tcp 1677734911 198.51.100.20 443 typ srflx raddr 10.0.0.3 rport 51000 tcptype passive generation 1
  a=ssrc-group:FID 2222 3333
  a=ssrc:2222 cname:local-video
  a=ssrc:2222 msid:local-stream local-video-track
  a=ssrc:3333 cname:local-video
  m=video 9 UDP/TLS/RTP/SAVPF 96
  c=IN IP4 0.0.0.0
  a=mid:2
  a=recvonly
  a=rtcp-mux
  a=rtpmap:96 VP8/90000
  a=ice-ufrag:local-v
  a=ice-pwd:local-v-password
  a=fingerprint:sha-256 EE:FF:00:11
  a=setup:active
  a=ssrc:5555 cname:receiver-report-only
  """

@Test
func translatesJingleOfferIntoWebRTCSDP() throws {
  let jingle = try JingleParser().parse(XMPPParser().parse(nativeOffer))
  let sdp = try JingleSDPTranslator(sessionOriginID: 42).offerSDP(from: jingle)

  #expect(sdp.contains("o=- 42 2 IN IP4 0.0.0.0\r\n"))
  // Media identifiers are renumbered sequentially and all bundled, as the
  // reference client regenerates them after splitting sources per m-line.
  #expect(sdp.contains("a=group:BUNDLE 0 1\r\n"))
  #expect(sdp.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"))
  #expect(sdp.contains("a=mid:0\r\n"))
  #expect(sdp.contains("a=rtpmap:111 opus/48000/2\r\n"))
  #expect(sdp.contains("a=rtcp-fb:111 transport-cc\r\n"))
  #expect(sdp.contains("m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"))
  #expect(sdp.contains("a=mid:1\r\n"))
  #expect(sdp.contains("a=rtcp-fb:96 nack pli\r\n"))
  #expect(sdp.contains("a=extmap-allow-mixed\r\n"))
  // The RTX partner and its FID group ride on the same media line as the
  // primary source, not on a line of their own.
  #expect(sdp.contains("a=ssrc-group:FID 2222 3333\r\n"))
  #expect(sdp.contains("a=ssrc:2222 videoType:desktop\r\n"))
  #expect(sdp.contains("a=ssrc:3333 cname:remote-video\r\n"))
  #expect(!sdp.contains("a=mid:2"))
  // Candidates are deliberately NOT inlined in the offer. WebRTC does not
  // reliably feed inline `a=candidate` lines to the ICE agent, so the
  // coordinator trickles them through `addIceCandidate` instead.
  #expect(!sdp.contains("a=candidate:"))
}

/// Mirrors lib-jitsi-meet's `SDP.fromJingle` for a bridge session: every
/// remote source gets its own media line, the videobridge's mixed
/// ("mixedmslabel") source is ordered onto the first — send/receive — line,
/// and every further source becomes send-only from the offerer.
@Test
func splitsEachRemoteSourceOntoItsOwnMediaLine() throws {
  let offer = """
    <jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" \
    initiator="focus@example.test/focus" sid="split-1">
      <content creator="initiator" name="video" senders="both">
        <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
          <payload-type id="96" name="VP8" clockrate="90000"/>
          <rtcp-mux/>
          <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="1000" name="peer-v0">
            <parameter name="msid" value="stream-a track-a"/>
          </source>
          <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="1001" name="peer-v0">
            <parameter name="msid" value="stream-a track-a"/>
          </source>
          <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="2000" name="other-v0">
            <parameter name="msid" value="stream-b track-b"/>
          </source>
          <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="3000">
            <parameter name="msid" value="mixedmslabel mixedlabelvideo0"/>
          </source>
          <ssrc-group xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" semantics="FID">
            <source ssrc="1000"/>
            <source ssrc="1001"/>
          </ssrc-group>
        </description>
        <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="u" pwd="p">
          <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" \
    setup="actpass">AA:BB</fingerprint>
        </transport>
      </content>
    </jingle>
    """
  let jingle = try JingleParser().parse(XMPPParser().parse(offer))
  let sdp = try JingleSDPTranslator().offerSDP(from: jingle)
  let sections = sdp.components(separatedBy: "\r\nm=").map { "m=" + $0 }.dropFirst()

  #expect(sdp.contains("a=group:BUNDLE 0 1 2\r\n"))
  #expect(sections.count == 3)
  // The bridge's mixed source claims the first, send/receive, media line even
  // though it was listed last.
  let first = try #require(sections.first)
  #expect(first.contains("a=mid:0"))
  #expect(first.contains("a=sendrecv"))
  #expect(first.contains("a=ssrc:3000 msid:mixedmslabel mixedlabelvideo0"))
  // The FID pair shares one send-only line; the second participant gets its
  // own send-only line.
  let second = sections[sections.startIndex + 1]
  #expect(second.contains("a=mid:1"))
  #expect(second.contains("a=sendonly"))
  #expect(second.contains("a=ssrc:1000 msid:stream-a track-a"))
  #expect(second.contains("a=ssrc:1001 msid:stream-a track-a"))
  #expect(second.contains("a=ssrc-group:FID 1000 1001"))
  let third = sections[sections.startIndex + 2]
  #expect(third.contains("a=mid:2"))
  #expect(third.contains("a=sendonly"))
  #expect(third.contains("a=ssrc:2000 msid:stream-b track-b"))
  #expect(!third.contains("a=ssrc:1000"))
}

@Test
func buildsRoundTrippableSessionAcceptFromWebRTCAnswer() throws {
  let element = try JingleAnswerBuilder().element(
    from: nativeAnswer,
    sessionID: "native-1",
    responder: "room@example.test/native-user",
    sourceMetadataByMediaType: [
      "audio": LocalSourceMetadata(name: "native-a0"),
      "video": LocalSourceMetadata(name: "native-v0", videoType: "camera"),
    ]
  )
  let serialized = XMPPWriter.serialize(element)
  let answer = try JingleParser().parse(XMPPParser().parse(serialized))

  #expect(answer.action == .sessionAccept)
  #expect(answer.sessionID == "native-1")
  // One content per media type, named by it — the extra receive-only video
  // line folds into the "video" content, exactly like SDP.toJingle upstream.
  #expect(answer.bundle == ["audio", "video"])
  #expect(answer.contents.count == 2)
  #expect(answer.contents[0].name == "audio")
  #expect(answer.contents[1].name == "video")
  #expect(answer.contents[0].description?.payloadTypes[0].name == "opus")
  #expect(answer.contents[0].description?.payloadTypes[0].feedback[0].type == "transport-cc")
  #expect(answer.contents[0].description?.sources[0].sourceName == "native-a0")
  #expect(answer.contents[1].description?.sourceGroups[0].semantics == "FID")
  #expect(answer.contents[1].description?.sourceGroups[0].sources == [2222, 3333])
  #expect(answer.contents[1].description?.sources[0].sourceName == "native-v0")
  #expect(answer.contents[1].description?.sources[0].videoType == "camera")
  // Only the msid is signalled as a parameter; name and videoType travel as
  // XML attributes and the cname not at all.
  #expect(
    answer.contents[1].description?.sources[0].parameters
      == ["msid": "local-stream local-video-track"]
  )
  // The receive-only line's cname-only SSRC is a receiver-report SSRC, not a
  // local source. Jicofo rejects any advertised source without an msid
  // ("Required source parameter 'msid' is not present"), so it must not be
  // folded into the accept.
  #expect(answer.contents[1].description?.sources.map(\.ssrc) == [2222, 3333])
  for content in answer.contents {
    for source in content.description?.sources ?? [] {
      #expect(source.parameters["msid"] != nil, "source \(source.ssrc) advertised without msid")
    }
  }
  #expect(answer.contents[1].transport?.candidates[0].relatedAddress == "10.0.0.3")
  #expect(answer.contents[1].transport?.candidates[0].tcpType == "passive")
}

@Test
func rejectsOversizedWebRTCAnswer() {
  let oversized = "v=0\n" + String(repeating: "x", count: 1_048_576)
  #expect(throws: JingleSDPError.sdpTooLarge(limit: 1_048_576)) {
    try JingleAnswerBuilder().element(
      from: oversized,
      sessionID: "native-1",
      responder: "room@example.test/native-user"
    )
  }
}
