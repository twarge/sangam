import JitsiJingle
import JitsiMedia
import Testing

@testable import JitsiConference

/// A remote offer whose media lines carry media-level `a=msid:` attributes —
/// what the translator now emits so remote tracks keep their signaled ids.
/// Local tracks must still bind to the first audio/video lines; if WebRTC's
/// transceiver reuse refuses an msid-bearing line, the answer degrades to
/// recvonly with no local sources and Jicofo rejects the session-accept.
@Test
func attachesLocalTracksToAnOfferWithMediaLevelMsid() async throws {
  let fingerprint: String =
    (0..<32).map { String(format: "%02X", ($0 * 7 + 11) % 256) }.joined(separator: ":")
  let transportLines: String = [
    "c=IN IP4 0.0.0.0",
    "a=rtcp:9 IN IP4 0.0.0.0",
    "a=ice-ufrag:remotea",
    "a=ice-pwd:remote-a-password-value",
    "a=ice-options:trickle",
    "a=fingerprint:sha-256 \(fingerprint)",
    "a=setup:actpass",
  ].joined(separator: "\r\n")
  let sessionLines: String = [
    "v=0",
    "o=- 42 2 IN IP4 0.0.0.0",
    "s=-",
    "t=0 0",
    "a=msid-semantic: WMS *",
    "a=group:BUNDLE 0 1 2",
  ].joined(separator: "\r\n")
  let audioSection: String = [
    "m=audio 9 UDP/TLS/RTP/SAVPF 111",
    transportLines,
    "a=mid:0",
    "a=sendrecv",
    "a=rtpmap:111 opus/48000/2",
    "a=rtcp-mux",
    "a=msid:mixedmslabel mixedlabelaudio0",
    "a=ssrc:333333 msid:mixedmslabel mixedlabelaudio0",
  ].joined(separator: "\r\n")
  let videoSection: String = [
    "m=video 9 UDP/TLS/RTP/SAVPF 96",
    transportLines,
    "a=mid:1",
    "a=sendrecv",
    "a=rtpmap:96 VP8/90000",
    "a=rtcp-mux",
    "a=msid:mixedmslabel mixedlabelvideo0",
    "a=ssrc:444444 msid:mixedmslabel mixedlabelvideo0",
  ].joined(separator: "\r\n")
  let peerSection: String = [
    "m=video 9 UDP/TLS/RTP/SAVPF 96",
    transportLines,
    "a=mid:2",
    "a=sendonly",
    "a=rtpmap:96 VP8/90000",
    "a=rtcp-mux",
    "a=msid:peer-stream peer-track",
    "a=ssrc:111111 msid:peer-stream peer-track",
  ].joined(separator: "\r\n")
  let offer =
    [sessionLines, audioSection, videoSection, peerSection].joined(separator: "\r\n") + "\r\n"

  let factory = WebRTCMediaFactory()
  let bridge = PeerConnectionEventBridge()
  let connection = try factory.makePeerConnection(policy: .init(), delegate: bridge)
  let negotiator = PeerConnectionNegotiator(connection: connection)
  let audio = factory.makeLocalAudioTrack(id: "test-audio-0")
  let video = factory.makeVideoTrack(id: "test-video-0", screenCast: false)

  let answer = try await negotiator.answer(
    remoteOfferSDP: offer,
    localAudioTrack: audio,
    localVideoTracks: [video],
    streamID: "test-stream"
  )
  let sections = answer.components(separatedBy: "\r\nm=").map { "m=" + $0 }.dropFirst()

  print("=== ANSWER DIRECTIONS ===")
  for section in sections {
    let kind = section.split(separator: " ").first ?? ""
    let direction =
      ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"]
      .first { section.contains($0) } ?? "?"
    let hasSSRC = section.contains("a=ssrc:")
    print("\(kind) \(direction) localSources=\(hasSSRC)")
  }
  print("=== END ===")

  let audioAnswer = try #require(sections.first { $0.hasPrefix("m=audio") })
  #expect(audioAnswer.contains("a=sendrecv"), "microphone did not bind to the audio line")
  #expect(audioAnswer.contains("a=ssrc:"), "answer carries no local audio source")
  let videoAnswer = try #require(sections.first { $0.hasPrefix("m=video") })
  #expect(videoAnswer.contains("a=sendrecv"), "camera did not bind to the first video line")
  #expect(videoAnswer.contains("a=ssrc:"), "answer carries no local video source")
  // The installed answer is simulcast-munged: three layers in a SIM group,
  // each with an msid — and WebRTC accepted the munged description, since
  // this SDP is returned only after setLocalDescription succeeds.
  let simLine = try #require(
    videoAnswer.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ssrc-group:SIM ") },
    "the sending video line was not munged for simulcast"
  )
  let layers = simLine.dropFirst("a=ssrc-group:SIM ".count).split(separator: " ")
  #expect(layers.count == 3)
  for layer in layers {
    #expect(
      videoAnswer.contains("a=ssrc:\(layer) msid:"),
      "simulcast layer \(layer) has no msid; Jicofo would reject the accept"
    )
  }
  await negotiator.close()
}
