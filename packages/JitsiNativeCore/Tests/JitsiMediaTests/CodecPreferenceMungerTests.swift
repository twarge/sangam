import Testing

@testable import JitsiMedia

/// The send codec follows the first payload of the video m= line, and VP8 is
/// the only codec this WebRTC build fans out into simulcast layers — the
/// munger must therefore lead with VP8 on both local and remote
/// descriptions, exactly like lib-jitsi-meet's `mungeCodecOrder`.
private let h264FirstOffer = [
  "v=0",
  "o=- 1 2 IN IP4 127.0.0.1",
  "s=-",
  "t=0 0",
  "m=audio 9 UDP/TLS/RTP/SAVPF 111",
  "a=mid:0",
  "a=rtpmap:111 opus/48000/2",
  "m=video 9 UDP/TLS/RTP/SAVPF 96 97 100 101 98 99",
  "a=mid:1",
  "a=rtpmap:96 H264/90000",
  "a=rtpmap:97 rtx/90000",
  "a=fmtp:97 apt=96",
  "a=rtpmap:100 VP8/90000",
  "a=rtpmap:101 rtx/90000",
  "a=fmtp:101 apt=100",
  "a=rtpmap:98 VP9/90000",
  "a=rtpmap:99 rtx/90000",
  "a=fmtp:99 apt=98",
].joined(separator: "\r\n")

@Test
func movesVP8AndItsRTXToTheFront() {
  let munged = CodecPreferenceMunger.preferVP8(h264FirstOffer)
  #expect(munged.contains("m=video 9 UDP/TLS/RTP/SAVPF 100 101 96 97 98 99"))
  // The audio line and every attribute line are untouched.
  #expect(munged.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111"))
  #expect(munged.contains("a=rtpmap:96 H264/90000"))
}

@Test
func leavesAVP8FirstDescriptionAlone() {
  let munged = CodecPreferenceMunger.preferVP8(h264FirstOffer)
  #expect(CodecPreferenceMunger.preferVP8(munged) == munged)
}

@Test
func leavesADescriptionWithoutVP8Alone() {
  let noVP8 = h264FirstOffer
    .replacingOccurrences(of: "a=rtpmap:100 VP8/90000", with: "a=rtpmap:100 AV1/90000")
  #expect(CodecPreferenceMunger.preferVP8(noVP8) == noVP8)
}
