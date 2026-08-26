import Testing

@testable import JitsiMedia

/// Mirrors lib-jitsi-meet's `SdpSimulcast` munging of the local answer.
private let freshAnswer = [
  "v=0",
  "o=- 1 2 IN IP4 127.0.0.1",
  "s=-",
  "t=0 0",
  "m=audio 9 UDP/TLS/RTP/SAVPF 111",
  "a=mid:0",
  "a=sendrecv",
  "a=ssrc:900 cname:audio-cname",
  "m=video 9 UDP/TLS/RTP/SAVPF 96",
  "a=mid:1",
  "a=sendrecv",
  "a=msid:stream track",
  "a=ssrc-group:FID 100 101",
  "a=ssrc:100 cname:video-cname",
  "a=ssrc:101 cname:video-cname",
  "m=video 9 UDP/TLS/RTP/SAVPF 96",
  "a=mid:2",
  "a=recvonly",
].joined(separator: "\r\n")

@Test
func addsTwoSimulcastLayersToTheSendingVideoSection() throws {
  var munger = LocalSimulcastMunger()
  let munged = munger.munge(freshAnswer)
  let videoSection = try #require(
    munged.components(separatedBy: "\r\nm=").first { $0.hasPrefix("video 9") && $0.contains("a=mid:1") }
  )

  // The primary keeps its RTX pair and every layer shares the msid — WebRTC
  // put it only at media level, so the munger makes it explicit per ssrc.
  #expect(videoSection.contains("a=ssrc-group:FID 100 101"))
  #expect(videoSection.contains("a=ssrc:100 msid:stream track"))
  let simLine = try #require(
    videoSection.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ssrc-group:SIM ") }
  )
  let layers = simLine.dropFirst("a=ssrc-group:SIM ".count).split(separator: " ")
  #expect(layers.count == 3)
  #expect(layers.first == "100")
  for layer in layers.dropFirst() {
    #expect(videoSection.contains("a=ssrc:\(layer) msid:stream track"))
    #expect(videoSection.contains("a=ssrc:\(layer) cname:video-cname"))
  }

  // Audio and receive-only sections are untouched.
  #expect(!munged.components(separatedBy: "\r\nm=")[1].contains("SIM"))
  #expect(munged.contains("a=mid:2\r\na=recvonly"))
}

@Test
func reusesCachedLayersAcrossRenegotiations() throws {
  var munger = LocalSimulcastMunger()
  let first = munger.munge(freshAnswer)
  let firstSIM = try #require(
    first.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ssrc-group:SIM ") }
  )

  // The renegotiated answer from WebRTC knows nothing of the munged layers;
  // the cached set must be re-signalled verbatim.
  let second = munger.munge(freshAnswer)
  let secondSIM = try #require(
    second.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ssrc-group:SIM ") }
  )
  #expect(firstSIM == secondSIM)
  for layer in secondSIM.dropFirst("a=ssrc-group:SIM ".count).split(separator: " ") {
    #expect(second.contains("a=ssrc:\(layer) msid:stream track"))
  }
}

@Test
func leavesAnAlreadySimulcastSectionAlone() {
  var munger = LocalSimulcastMunger()
  let alreadyMunged = munger.munge(freshAnswer)
  var second = LocalSimulcastMunger()
  let untouched = second.munge(alreadyMunged)
  #expect(untouched == alreadyMunged)
}
