import CoreVideo
import Foundation
import Testing

@testable import JitsiConference
@testable import JitsiMedia

/// End-to-end proof that the munged SIM answer makes the encoder fan out:
/// two real peer connections over loopback, synthetic 720p frames pushed in,
/// and the outbound-rtp statistics counted. Three sender encodings in
/// `parameters` are necessary but not sufficient — this asserts actual
/// multi-stream RTP leaves the encoder, which is what the bridge needs
/// before it can ever downshift a viewer.
///
/// Gated behind `SANGAM_LOOPBACK_TESTS=1`: the bandwidth-estimation ramp
/// that activates the upper layers is wall-clock dependent and starves when
/// the suite runs tests concurrently in-process, so this is a bring-up
/// harness, not a CI gate. Run it alone:
/// `SANGAM_LOOPBACK_TESTS=1 swift test --filter Loopback`.
@Test(
  .enabled(if: ProcessInfo.processInfo.environment["SANGAM_LOOPBACK_TESTS"] == "1"),
  .timeLimit(.minutes(2)))
func encodesMultipleSimulcastStreamsOverLoopback() async throws {
  let factory = WebRTCMediaFactory()

  let remoteBridge = PeerConnectionEventBridge()
  let remoteConnection = try factory.makePeerConnection(policy: .init(), delegate: remoteBridge)
  let remoteAudio = factory.makeLocalAudioTrack(id: "remote-audio-0")
  let remoteVideo = factory.makeVideoTrack(id: "remote-video-0", screenCast: false)
  remoteConnection.add(remoteAudio.track, streamIds: ["remote-stream"])
  remoteConnection.add(remoteVideo.track, streamIds: ["remote-stream"])
  let remote = PeerConnectionNegotiator(connection: remoteConnection)

  let localBridge = PeerConnectionEventBridge()
  let localConnection = try factory.makePeerConnection(policy: .init(), delegate: localBridge)
  let local = PeerConnectionNegotiator(connection: localConnection)
  let audio = factory.makeLocalAudioTrack(id: "local-audio-0")
  let video = factory.makeVideoTrack(id: "local-video-0", screenCast: false)

  let offer = try await remote.offer()
  let answer = try await local.answer(
    remoteOfferSDP: offer,
    localAudioTrack: audio,
    localVideoTracks: [video],
    streamID: "local-stream"
  )
  #expect(answer.contains("a=ssrc-group:SIM "), "the loopback answer was not munged")
  let videoSection = answer.components(separatedBy: "\r\nm=video").dropFirst().first ?? ""
  let payloadOrder = videoSection.split(separator: "\r\n").first ?? ""
  let rtpmaps = videoSection.split(separator: "\r\n")
    .filter { $0.hasPrefix("a=rtpmap:") }.prefix(4).joined(separator: ", ")
  print("=== VIDEO m-line:\(payloadOrder) | \(rtpmaps) ===")
  for line in await local.videoSenderEncodingSummary(trackID: "local-video-0") {
    print("=== ENCODING \(line) ===")
  }
  try await remote.apply(remoteAnswerSDP: answer)

  // Trickle each side's candidates into the other.
  let localToRemote = Task {
    for await event in localBridge.events {
      if case .localCandidate(let candidate) = event {
        try? await remote.addRemoteCandidate(
          sdp: candidate.sdp, mid: candidate.mid, mediaLineIndex: candidate.mediaLineIndex)
      }
    }
  }
  let remoteToLocal = Task {
    for await event in remoteBridge.events {
      if case .localCandidate(let candidate) = event {
        try? await local.addRemoteCandidate(
          sdp: candidate.sdp, mid: candidate.mid, mediaLineIndex: candidate.mediaLineIndex)
      }
    }
  }
  defer {
    localToRemote.cancel()
    remoteToLocal.cancel()
  }

  // Push synthetic 720p frames so the encoder has real work, long enough for
  // bandwidth estimation to ramp into the upper layers.
  var pixelBuffer: CVPixelBuffer?
  CVPixelBufferCreate(
    kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
  let frame = try #require(pixelBuffer)
  CVPixelBufferLockBaseAddress(frame, [])
  if let base = CVPixelBufferGetBaseAddress(frame) {
    memset(base, 0x7F, CVPixelBufferGetDataSize(frame))
  }
  CVPixelBufferUnlockBaseAddress(frame, [])

  var sendingSSRCs: Set<String> = []
  let started = Date()
  var elapsedNanoseconds: Int64 = 0
  while Date().timeIntervalSince(started) < 90 {
    video.push(pixelBuffer: frame, timestampNanoseconds: elapsedNanoseconds)
    elapsedNanoseconds += 33_333_333
    try await Task.sleep(nanoseconds: 33_333_333)

    if elapsedNanoseconds % 1_000_000_000 < 40_000_000 {
      let summary = await local.videoStatsSummary()
      sendingSSRCs = Set(
        summary.components(separatedBy: " | ")
          .filter { $0.hasPrefix("vsend ssrc=") && !$0.hasSuffix(" sent=0") }
          .compactMap { $0.split(separator: " ").first?.split(separator: "=").last }
          .map(String.init))
      print("=== \(Int(Date().timeIntervalSince(started)))s \(summary) ===")
      if sendingSSRCs.count >= 2 { break }
    }
  }

  // Two concurrent streams already separate simulcast from the
  // single-stream failure mode; the third layer's arrival depends on how
  // fast loopback bandwidth estimation ramps, which varies with test-host
  // load.
  #expect(
    sendingSSRCs.count >= 2,
    "only \(sendingSSRCs.sorted()) carried bytes; the encoder never fanned out"
  )
  await local.close()
  await remote.close()
}
