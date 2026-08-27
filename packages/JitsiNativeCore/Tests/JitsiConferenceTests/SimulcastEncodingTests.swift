import JitsiMedia
import Testing

@testable import JitsiConference

/// Replays the live negotiation shape — an RTX-bearing Jicofo offer followed
/// by renegotiations — and asserts the sender keeps three simulcast
/// encodings throughout. The live symptom this guards: the bridge receiving
/// a single 720p stream it can never downshift, while the SDP looks munged.
private func jicofoStyleOffer(extraRemoteVideoLines: Int = 0) -> String {
  let fingerprint =
    (0..<32).map { String(format: "%02X", ($0 * 7 + 11) % 256) }.joined(separator: ":")
  let transportLines = [
    "c=IN IP4 0.0.0.0",
    "a=rtcp:9 IN IP4 0.0.0.0",
    "a=ice-ufrag:remotea",
    "a=ice-pwd:remote-a-password-value",
    "a=ice-options:trickle",
    "a=fingerprint:sha-256 \(fingerprint)",
    "a=setup:actpass",
  ].joined(separator: "\r\n")
  let videoPayloads = [
    "a=rtpmap:96 VP8/90000",
    "a=rtpmap:97 rtx/90000",
    "a=fmtp:97 apt=96",
    "a=rtcp-mux",
  ].joined(separator: "\r\n")

  var mids = ["0", "1"]
  var sections = [
    [
      "m=audio 9 UDP/TLS/RTP/SAVPF 111",
      transportLines,
      "a=mid:0",
      "a=sendrecv",
      "a=rtpmap:111 opus/48000/2",
      "a=rtcp-mux",
      "a=msid:mixedmslabel mixedlabelaudio0",
      "a=ssrc:333333 msid:mixedmslabel mixedlabelaudio0",
    ].joined(separator: "\r\n"),
    [
      "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
      transportLines,
      "a=mid:1",
      "a=sendrecv",
      videoPayloads,
      "a=msid:mixedmslabel mixedlabelvideo0",
      "a=ssrc:444444 msid:mixedmslabel mixedlabelvideo0",
    ].joined(separator: "\r\n"),
  ]
  for index in 0..<extraRemoteVideoLines {
    let mid = "\(2 + index)"
    mids.append(mid)
    sections.append(
      [
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        transportLines,
        "a=mid:\(mid)",
        "a=sendonly",
        videoPayloads,
        "a=msid:peer-stream-\(index) peer-track-\(index)",
        "a=ssrc:\(111_111 + index) msid:peer-stream-\(index) peer-track-\(index)",
      ].joined(separator: "\r\n"))
  }
  let sessionLines = [
    "v=0",
    "o=- 42 2 IN IP4 0.0.0.0",
    "s=-",
    "t=0 0",
    "a=msid-semantic: WMS *",
    "a=group:BUNDLE \(mids.joined(separator: " "))",
  ].joined(separator: "\r\n")
  return ([sessionLines] + sections).joined(separator: "\r\n") + "\r\n"
}

@Test(.enabled(if: mediaHardwareAvailable, "needs an audio device; hangs on headless runners"))
func keepsThreeEncodingsAcrossRTXAndRenegotiations() async throws {
  let factory = WebRTCMediaFactory()
  let bridge = PeerConnectionEventBridge()
  let connection = try factory.makePeerConnection(policy: .init(), delegate: bridge)
  let negotiator = PeerConnectionNegotiator(connection: connection)
  let audio = factory.makeLocalAudioTrack(id: "test-audio-0")
  let video = factory.makeVideoTrack(id: "test-video-0", screenCast: false)

  let answer = try await negotiator.answer(
    remoteOfferSDP: jicofoStyleOffer(),
    localAudioTrack: audio,
    localVideoTracks: [video],
    streamID: "test-stream"
  )
  #expect(answer.contains("a=ssrc-group:SIM "))
  var ssrcs = await negotiator.videoSenderEncodingSSRCs(trackID: "test-video-0")
  print("=== ENCODINGS after initial RTX answer: \(ssrcs) ===")
  #expect(ssrcs.count == 3, "RTX-bearing offer: munge did not fan out to three encodings")

  // A remote participant's source-add expands the offer; the renegotiated
  // answer must re-emit the cached layers and the encoder must keep them.
  for round in 1...2 {
    let renegotiated = try await negotiator.answerRenegotiation(
      remoteOfferSDP: jicofoStyleOffer(extraRemoteVideoLines: round)
    )
    #expect(renegotiated.contains("a=ssrc-group:SIM "))
    ssrcs = await negotiator.videoSenderEncodingSSRCs(trackID: "test-video-0")
    print("=== ENCODINGS after renegotiation \(round): \(ssrcs) ===")
    #expect(ssrcs.count == 3, "renegotiation \(round) collapsed the simulcast encodings")
  }

  // The bridge pauses and resumes senders via constraints; the fan-out must
  // survive that round trip too.
  await negotiator.setVideoSenderActive(trackID: "test-video-0", active: false)
  await negotiator.setVideoSenderActive(trackID: "test-video-0", active: true)
  ssrcs = await negotiator.videoSenderEncodingSSRCs(trackID: "test-video-0")
  print("=== ENCODINGS after pause/resume: \(ssrcs) ===")
  #expect(ssrcs.count == 3, "pause/resume collapsed the simulcast encodings")

  await negotiator.close()
}
