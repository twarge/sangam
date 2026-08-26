import Testing

@testable import JitsiXMPP

@Test func answersJicofoDiscoInfoQueries() throws {
  let request = try XMPPParser().parse(
    """
    <iq from="room@example.test/focus" id="disco-1" type="get">
      <query xmlns="http://jabber.org/protocol/disco#info" node="https://jitsi.org/native#1"/>
    </iq>
    """
  )
  let response = try #require(XMPPClientCapabilities.jitsiNative.response(to: request))
  #expect(response[attribute: "id"] == "disco-1")
  #expect(response[attribute: "type"] == "result")
  #expect(response[attribute: "to"] == "room@example.test/focus")
  let query = try #require(
    response.child(
      named: "query",
      namespace: XMPPClientCapabilities.discoInfoNamespace
    )
  )
  #expect(query[attribute: "node"] == "https://jitsi.org/native#1")
  let features = Set(query.children(named: "feature").compactMap { $0[attribute: "var"] })
  #expect(features.contains("urn:xmpp:jingle:1"))
  #expect(features.contains("urn:xmpp:jingle:apps:rtp:video"))
  #expect(features.contains("http://jitsi.org/source-name"))
  // SSRC rewriting is opt-in via SANGAM_SSRC_REWRITING=1 until verified live;
  // by default the bridge must use classic per-source forwarding.
  #expect(!features.contains("http://jitsi.org/ssrc-rewriting-1"))
}

@Test func answersXMPPPings() throws {
  let request = try XMPPParser().parse(
    """
    <iq from="conference.example.test" id="ping-1" type="get">
      <ping xmlns="urn:xmpp:ping"/>
    </iq>
    """
  )
  let response = try #require(XMPPClientCapabilities.jitsiNative.response(to: request))
  #expect(response[attribute: "id"] == "ping-1")
  #expect(response[attribute: "type"] == "result")
  #expect(response.children.isEmpty)
}
