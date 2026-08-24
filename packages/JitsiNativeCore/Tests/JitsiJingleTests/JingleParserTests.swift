import Testing

@testable import JitsiJingle
@testable import JitsiXMPP

private let sessionInitiate = """
  <iq from="focus@example.test" id="jingle-1" type="set">
    <jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" initiator="focus@example.test" sid="sid-123">
      <content creator="initiator" name="video" senders="both">
        <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
          <payload-type id="96" name="VP8" clockrate="90000">
            <parameter name="x-google-start-bitrate" value="800"/>
          </payload-type>
          <rtp-hdrext xmlns="urn:xmpp:jingle:apps:rtp:rtp-hdrext:0" id="5" uri="http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"/>
          <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="3758540092">
            <parameter name="cname" value="remote-cname"/>
            <parameter name="name" value="remote-v0"/>
            <parameter name="videoType" value="desktop"/>
          </source>
        </description>
        <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1" ufrag="ufrag" pwd="secret">
          <candidate component="1" foundation="1" generation="0" ip="192.0.2.10" port="10000" priority="2130706431" protocol="udp" type="host"/>
          <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0" hash="sha-256" setup="actpass">AA:BB:CC:DD</fingerprint>
        </transport>
      </content>
    </jingle>
  </iq>
  """

@Test
func parsesSessionInitiateAndDesktopSource() throws {
  let stanza = try XMPPParser().parse(sessionInitiate)
  let session = try JingleParser().parse(stanza)

  #expect(session.action == .sessionInitiate)
  #expect(session.sessionID == "sid-123")
  #expect(session.contents.count == 1)
  #expect(session.contents[0].description?.payloadTypes[0].name == "VP8")
  #expect(session.contents[0].description?.sources[0].sourceName == "remote-v0")
  #expect(session.contents[0].description?.sources[0].videoType == "desktop")
  #expect(session.contents[0].transport?.candidates[0].port == 10_000)
  #expect(session.contents[0].transport?.fingerprint?.hash == "sha-256")
}

/// Mirrors lib-jitsi-meet's `expandSourcesFromJson`: the per-owner value is a
/// positional 4-tuple — video sources, video ssrc-groups, audio sources, audio
/// ssrc-groups — and every source of every owner is added, with the name as an
/// attribute, the msid as the only parameter, the owner from the JSON key, and
/// the video type defaulting to camera unless the `v` flag marks a desktop.
@Test
func expandsJSONEncodedSourcesPositionallyForEveryOwner() throws {
  let stanza = """
    <jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" sid="json-1">
      <content creator="initiator" name="audio" senders="both">
        <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
          <payload-type id="111" name="opus" clockrate="48000"/>
        </description>
      </content>
      <content creator="initiator" name="video" senders="both">
        <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
          <payload-type id="96" name="VP8" clockrate="90000"/>
        </description>
      </content>
      <json-message xmlns="http://jitsi.org/jitmeet">{"sources":{\
    "abcd1234":[[{"s":1000,"n":"abcd1234-v0","m":"stream-a video-a"},\
    {"s":1001,"n":"abcd1234-v0","m":"stream-a video-a"}],[["f",1000,1001]],\
    [{"s":5000,"n":"abcd1234-a0","m":"stream-a audio-a"}],[]],\
    "jvb":[[{"s":9999,"n":"jvb-v0","m":"mixedmslabel mixedlabelvideo0","v":true}],[],\
    [{"s":8888,"n":"jvb-a0","m":"mixedmslabel mixedlabelaudio0"}],[]]}}</json-message>
    </jingle>
    """
  let session = try JingleParser().parse(XMPPParser().parse(stanza))
  let audio = try #require(session.contents.first { $0.description?.media == "audio" })
  let video = try #require(session.contents.first { $0.description?.media == "video" })

  // Every source of every owner is added — no picking one per media line.
  #expect(video.description?.sources.map(\.ssrc) == [1000, 1001, 9999])
  #expect(audio.description?.sources.map(\.ssrc) == [5000, 8888])

  let camera = try #require(video.description?.sources.first)
  #expect(camera.name == "abcd1234-v0")
  #expect(camera.videoType == "camera")
  #expect(camera.owner == "abcd1234")
  #expect(camera.parameters == ["msid": "stream-a video-a"])
  // The `v` flag marks a desktop source; audio sources carry no video type.
  #expect(video.description?.sources.last?.videoType == "desktop")
  #expect(audio.description?.sources.first?.videoType == nil)
  #expect(audio.description?.sources.last?.owner == "jvb")

  // Group semantics are the compact "f"/"s" forms.
  #expect(video.description?.sourceGroups == [RTPSourceGroup(semantics: "FID", sources: [1000, 1001])])
  #expect(audio.description?.sourceGroups.isEmpty == true)
}

/// A source-add signalled purely as JSON has no `<content>` elements at all;
/// the expansion has to create the audio and video contents, as
/// `_getOrCreateRtpDescription` does upstream.
@Test
func createsContentsWhenAJSONSourceAddCarriesNone() throws {
  let stanza = """
    <jingle xmlns="urn:xmpp:jingle:1" action="source-add" sid="json-2">
      <json-message xmlns="http://jitsi.org/jitmeet">{"sources":{\
    "peer":[[{"s":7000,"n":"peer-v0","m":"s t"},{"s":7001,"n":"peer-v0","m":"s t"}],\
    [["f",7000,7001],["s",7000,7002,7003],["x",1,2]],[],[]]}}</json-message>
    </jingle>
    """
  let session = try JingleParser().parse(XMPPParser().parse(stanza))

  #expect(session.contents.count == 2)
  let video = try #require(session.contents.first { $0.description?.media == "video" })
  #expect(video.description?.sources.map(\.ssrc) == [7000, 7001])
  // "f" and "s" map to FID and SIM; unknown semantics are dropped.
  #expect(
    video.description?.sourceGroups == [
      RTPSourceGroup(semantics: "FID", sources: [7000, 7001]),
      RTPSourceGroup(semantics: "SIM", sources: [7000, 7002, 7003]),
    ]
  )
}

@Test
func rejectsUnknownAction() throws {
  let root = try XMPPParser().parse(
    "<jingle xmlns=\"urn:xmpp:jingle:1\" action=\"made-up\" sid=\"s\"/>"
  )
  #expect(throws: JingleParsingError.unsupportedAction("made-up")) {
    try JingleParser().parse(root)
  }
}

@Test
func rejectsInvalidSSRC() throws {
  let root = try XMPPParser().parse(
    """
    <jingle xmlns="urn:xmpp:jingle:1" action="source-add" sid="s">
      <content name="video">
        <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
          <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="not-a-number"/>
        </description>
      </content>
    </jingle>
    """
  )
  #expect(throws: JingleParsingError.invalidNumber(field: "ssrc", value: "not-a-number")) {
    try JingleParser().parse(root)
  }
}
