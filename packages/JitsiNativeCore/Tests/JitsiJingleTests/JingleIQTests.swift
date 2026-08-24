import Testing

@testable import JitsiJingle
@testable import JitsiXMPP

@Test
func buildsDesktopSourceAddIQ() throws {
  let content = JingleContent(
    name: "video",
    creator: "initiator",
    description: RTPDescription(
      media: "video",
      sources: [
        RTPSource(
          ssrc: 200,
          name: "endpoint-v1",
          videoType: "desktop",
          parameters: ["msid": "native-stream native-desktop"]
        )
      ],
      sourceGroups: [RTPSourceGroup(semantics: "FID", sources: [200, 201])]
    )
  )
  let iq = JingleIQBuilder().sourceUpdate(
    action: .sourceAdd,
    sessionID: "sid",
    content: content,
    initiator: "focus@test",
    to: "focus@test",
    from: "room@test/native",
    id: "add-1"
  )
  let serialized = XMPPWriter.serialize(iq)
  let parsed = try JingleParser().parse(XMPPParser().parse(serialized))

  #expect(parsed.action == .sourceAdd)
  #expect(parsed.contents[0].name == "video")
  // Name and video type are XML attributes on <source>, as the reference
  // client sends them; the msid is the only parameter.
  #expect(serialized.contains("name=\"endpoint-v1\""))
  #expect(serialized.contains("videoType=\"desktop\""))
  #expect(parsed.contents[0].description?.sources[0].name == "endpoint-v1")
  #expect(parsed.contents[0].description?.sources[0].videoType == "desktop")
  #expect(
    parsed.contents[0].description?.sources[0].parameters
      == ["msid": "native-stream native-desktop"]
  )
  #expect(parsed.contents[0].description?.sourceGroups[0].sources == [200, 201])
}

@Test
func acknowledgesIncomingJingleIQWithAddressing() throws {
  let incoming = try IncomingJingleIQ(
    element: XMPPParser().parse(
      """
      <iq from="focus@example.test/focus" id="offer-1" to="user@example.test/native" type="set">
        <jingle xmlns="urn:xmpp:jingle:1" action="session-terminate" sid="sid-1"/>
      </iq>
      """
    )
  )

  let acknowledgment = incoming.acknowledgment()
  #expect(acknowledgment[attribute: "id"] == "offer-1")
  #expect(acknowledgment[attribute: "type"] == "result")
  #expect(acknowledgment[attribute: "to"] == "focus@example.test/focus")
  #expect(acknowledgment[attribute: "from"] == "user@example.test/native")
}

@Test
func buildsTrickledCandidateTransportInfo() throws {
  let iq = try JingleIQBuilder().transportInfo(
    sessionID: "sid-1",
    candidateSDP:
      "candidate:4 1 tcp 1677734911 198.51.100.20 443 typ srflx raddr 10.0.0.3 rport 51000 tcptype passive generation 1",
    mid: "video",
    credentials: ICECredentials(usernameFragment: "OfHT", password: "TVbVJ9ZYsFtYFHhWqH4zhski"),
    initiator: "focus@example.test/focus",
    to: "focus@example.test/focus",
    from: "user@example.test/native",
    id: "candidate-1"
  )
  let serialized = XMPPWriter.serialize(iq)
  let parsed = try JingleParser().parse(XMPPParser().parse(serialized))

  #expect(parsed.action == .transportInfo)
  #expect(parsed.contents[0].name == "video")
  // Jitsi Videobridge takes the remote ICE credentials from every transport
  // element it receives, so a candidate without them nulls the bridge's copy.
  #expect(parsed.contents[0].transport?.usernameFragment == "OfHT")
  #expect(parsed.contents[0].transport?.password == "TVbVJ9ZYsFtYFHhWqH4zhski")
  #expect(parsed.contents[0].transport?.candidates[0].protocolName == "tcp")
  #expect(parsed.contents[0].transport?.candidates[0].relatedAddress == "10.0.0.3")
  #expect(parsed.contents[0].transport?.candidates[0].relatedPort == 51_000)
  #expect(parsed.contents[0].transport?.candidates[0].tcpType == "passive")
}

@Test
func rejectsUnaddressedJingleIQ() throws {
  let stanza = try XMPPParser().parse(
    """
    <iq id="offer-1" type="set">
      <jingle xmlns="urn:xmpp:jingle:1" action="session-terminate" sid="sid-1"/>
    </iq>
    """
  )
  #expect(throws: JingleIQError.missingSender) {
    try IncomingJingleIQ(element: stanza)
  }
}

@Test
func readsLocalICECredentialsFromAnAnswer() {
  let sdp = """
    v=0
    o=- 1 2 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE audio video
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ice-ufrag:OfHT
    a=ice-pwd:TVbVJ9ZYsFtYFHhWqH4zhski
    a=mid:audio
    m=video 9 UDP/TLS/RTP/SAVPF 100
    a=ice-ufrag:OfHT
    a=ice-pwd:TVbVJ9ZYsFtYFHhWqH4zhski
    a=mid:video
    """
  let credentials = ICECredentials(sdp: sdp)
  #expect(credentials?.usernameFragment == "OfHT")
  #expect(credentials?.password == "TVbVJ9ZYsFtYFHhWqH4zhski")
  #expect(ICECredentials(sdp: "v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n") == nil)
}
