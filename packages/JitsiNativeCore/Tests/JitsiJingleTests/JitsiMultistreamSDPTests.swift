import Testing

@testable import JitsiJingle

private let baseOffer = """
  v=0
  o=- 10 20 IN IP4 0.0.0.0
  s=-
  t=0 0
  a=group:BUNDLE 0 1
  m=audio 9 UDP/TLS/RTP/SAVPF 111
  a=mid:0
  a=sendrecv
  a=ice-ufrag:u
  a=ice-pwd:p
  m=video 9 UDP/TLS/RTP/SAVPF 96
  a=mid:1
  a=sendrecv
  a=ice-ufrag:u
  a=ice-pwd:p
  a=rtpmap:96 VP8/90000
  a=ssrc:100 cname:remote
  """

@Test
func addsBundledRecvOnlyMLineForFirstLocalDesktopSource() throws {
  let addition = try JitsiMultistreamSDP().addingLocalSourceMedia(to: baseOffer)

  #expect(addition.mid == "2")
  #expect(addition.sdp.contains("a=group:BUNDLE 0 1 2\n"))
  #expect(addition.sdp.contains("o=- 10 21 IN IP4 0.0.0.0\n"))
  #expect(addition.sdp.contains("m=video 9 UDP/TLS/RTP/SAVPF 96\na=ice-ufrag:u"))
  #expect(addition.sdp.hasSuffix("a=mid:2\na=recvonly\n"))
  #expect(addition.sdp.components(separatedBy: "a=ssrc:100").count == 2)
}

@Test
func extractsDesktopSourceAndGroupsFromFinalLocalAnswer() throws {
  let answer =
    baseOffer + "\n" + """
      m=video 9 UDP/TLS/RTP/SAVPF 96
      a=mid:2
      a=sendonly
      a=ssrc-group:FID 200 201
      a=ssrc:200 cname:local
      a=ssrc:200 msid:stream desktop
      a=ssrc:201 cname:local
      """
  let content = try JitsiMultistreamSDP().sourceContent(
    from: answer,
    mid: "2",
    metadata: LocalSourceMetadata(name: "endpoint-v1", videoType: "desktop")
  )

  // Named by media type with attribute-form source metadata and msid-only
  // parameters, the way the reference client signals a local source-add.
  #expect(content.name == "video")
  #expect(content.description?.sources.count == 2)
  #expect(content.description?.sources[0].name == "endpoint-v1")
  #expect(content.description?.sources[0].videoType == "desktop")
  #expect(content.description?.sources[0].parameters == ["msid": "stream desktop"])
  // The RTX stream has no msid line of its own; it inherits its FID partner's,
  // because Jicofo rejects any advertised source without an msid.
  #expect(content.description?.sources[1].parameters == ["msid": "stream desktop"])
  #expect(content.description?.sourceGroups[0].sources == [200, 201])
}

/// Jicofo names a source-add's content by media type; which media line a
/// source lands on is decided here, not by the content name — every new
/// source gets a fresh send-only line, as `SDP.updateRemoteSources` does.
@Test
func appliesRemoteSourceAddAndRemoveAsAnswerableOffer() throws {
  let source = RTPSource(
    ssrc: 300,
    name: "peer-v1",
    videoType: "camera",
    owner: "room@conference.test/peer",
    parameters: ["msid": "stream track"]
  )
  let content = JingleContent(
    name: "video",
    creator: "initiator",
    description: RTPDescription(media: "video", sources: [source])
  )
  let add = JingleSessionDescription(
    action: .sourceAdd,
    sessionID: "sid",
    initiator: "focus@test",
    contents: [content]
  )
  let added = try JitsiMultistreamSDP().applyingRemoteSourceUpdate(add, to: baseOffer)

  #expect(added.contains("a=group:BUNDLE 0 1 2\n"))
  // The msid appears at media level — so WebRTC surfaces the remote track
  // under the signaled id — and on the ssrc line.
  #expect(added.contains("a=mid:2\na=sendonly\na=msid:stream track\na=ssrc:300 msid:stream track"))

  let remove = JingleSessionDescription(
    action: .sourceRemove,
    sessionID: "sid",
    initiator: "focus@test",
    contents: [content]
  )
  let removed = try JitsiMultistreamSDP().applyingRemoteSourceUpdate(remove, to: added)
  #expect(!removed.contains("a=ssrc:300"))
  #expect(removed.contains("m=video 0 UDP/TLS/RTP/SAVPF 96"))
  #expect(removed.hasSuffix("a=inactive\n"))
}

/// The bridge's SSRC-rewriting mode stamps the mid a source is demuxed on into
/// a "mid" parameter; when present it must name the new media line.
@Test
func honorsTheBridgeProvidedMidOnSourceAdd() throws {
  let source = RTPSource(
    ssrc: 400,
    name: "rewritten-v0",
    parameters: ["mid": "7", "msid": "stream-r track-r"]
  )
  let add = JingleSessionDescription(
    action: .sourceAdd,
    sessionID: "sid",
    initiator: "focus@test",
    contents: [
      JingleContent(
        name: "video",
        description: RTPDescription(media: "video", sources: [source])
      )
    ]
  )
  let added = try JitsiMultistreamSDP().applyingRemoteSourceUpdate(add, to: baseOffer)
  #expect(added.contains("a=group:BUNDLE 0 1 7\n"))
  #expect(
    added.contains("a=mid:7\na=sendonly\na=msid:stream-r track-r\na=ssrc:400 msid:stream-r track-r")
  )
}
