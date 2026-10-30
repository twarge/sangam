import Foundation
import Testing

@testable import JitsiMedia

/// Proof that decoded remote audio actually reaches the native tap. WebRTC
/// delivers PCM through one `AudioTrackSinkInterface::OnData` overload, by
/// vtable slot; a tap compiled against another release's headers still
/// attaches and drains cleanly but never hears a frame. Attaching is not
/// enough, so this sends audio between two real peer connections over
/// loopback and requires the receiving side's tap to fill.
///
/// Gated like the other real-media tests: a headless runner has no audio
/// device to play out through, and playout is what pulls the frames.
@Test(.enabled(if: mediaHardwareAvailable), .timeLimit(.minutes(1)))
func remoteAudioReachesTheTapOverLoopback() async throws {
  let factory = WebRTCMediaFactory()

  let senderBridge = PeerConnectionEventBridge()
  let senderConnection = try factory.makePeerConnection(policy: .init(), delegate: senderBridge)
  let senderAudio = factory.makeLocalAudioTrack(id: "sender-audio-0")
  senderConnection.add(senderAudio.track, streamIds: ["sender-stream"])
  let sender = PeerConnectionNegotiator(connection: senderConnection)

  let receiverBridge = PeerConnectionEventBridge()
  let receiverConnection = try factory.makePeerConnection(
    policy: .init(), delegate: receiverBridge)
  let receiver = PeerConnectionNegotiator(connection: receiverConnection)

  // Each bridge's events have one consumer, so the receiver's loop both
  // trickles candidates and hands over the remote track.
  let (remoteTracks, remoteTrack) = AsyncStream<RemoteAudioTrack>.makeStream()
  let senderToReceiver = Task {
    for await event in senderBridge.events {
      if case .localCandidate(let candidate) = event {
        try? await receiver.addRemoteCandidate(
          sdp: candidate.sdp, mid: candidate.mid, mediaLineIndex: candidate.mediaLineIndex)
      }
    }
  }
  let receiverToSender = Task {
    for await event in receiverBridge.events {
      switch event {
      case .localCandidate(let candidate):
        try? await sender.addRemoteCandidate(
          sdp: candidate.sdp, mid: candidate.mid, mediaLineIndex: candidate.mediaLineIndex)
      case .remoteAudioTrackAdded(let track, _):
        remoteTrack.yield(track)
      default:
        break
      }
    }
  }
  defer {
    senderToReceiver.cancel()
    receiverToSender.cancel()
  }

  let offer = try await sender.offer()
  let answer = try await receiver.answer(remoteOfferSDP: offer)
  try await sender.apply(remoteAnswerSDP: answer)

  var tracks = remoteTracks.makeAsyncIterator()
  let track = try #require(await tracks.next(), "the receiver never surfaced the remote audio")
  let tap = try #require(track.makeTap(), "the pinned binary must accept its native audio sink")

  var frames: [AudioPCMFrame] = []
  let deadline = Date().addingTimeInterval(15)
  while frames.isEmpty, Date() < deadline {
    try await Task.sleep(for: .milliseconds(50))
    frames += tap.drain()
  }
  tap.stop()

  let frame = try #require(
    frames.first, "the tap attached but WebRTC never delivered decoded audio into it")
  #expect(frame.sampleRate > 0)
  #expect((1...2).contains(frame.channels))
  #expect(frame.samples.count == frame.channels * frame.frameCount * MemoryLayout<Int16>.size)

  await receiver.close()
  await sender.close()
}
