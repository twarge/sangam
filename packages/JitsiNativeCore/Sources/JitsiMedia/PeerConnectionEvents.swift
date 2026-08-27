import Foundation
@preconcurrency import WebRTC

public enum NativePeerConnectionState: String, Sendable {
  case new
  case connecting
  case connected
  case disconnected
  case failed
  case closed
}

public struct NativeICECandidate: Equatable, Sendable {
  public var sdp: String
  public var mid: String?
  public var mediaLineIndex: Int32

  public init(sdp: String, mid: String?, mediaLineIndex: Int32) {
    self.sdp = sdp
    self.mid = mid
    self.mediaLineIndex = mediaLineIndex
  }
}

public final class RemoteVideoTrack: @unchecked Sendable, Identifiable {
  public let id: String
  let track: RTCVideoTrack

  fileprivate init(track: RTCVideoTrack) {
    id = track.trackId
    self.track = track
  }

  public var isEnabled: Bool {
    get { track.isEnabled }
    set { track.isEnabled = newValue }
  }
}

public enum NativePeerConnectionEvent: Sendable {
  case connectionStateChanged(NativePeerConnectionState)
  case localCandidate(NativeICECandidate)
  /// `ssrc` is the receiver's first SSRC, the reliable handle for matching a
  /// track back to its signaled source: WebRTC keeps signaled msid track ids
  /// only for tracks from the initial offer and synthesizes ids for media
  /// lines added by renegotiation (every screen share arrives that way).
  case remoteVideoTrackAdded(RemoteVideoTrack, ssrc: UInt32?)
  case remoteVideoTrackRemoved(id: String)
  case negotiationNeeded
}

/// Retained by the conference engine because RTCPeerConnection keeps only a
/// weak delegate reference.
public final class PeerConnectionEventBridge: NSObject, @unchecked Sendable {
  public let events: AsyncStream<NativePeerConnectionEvent>

  private let continuation: AsyncStream<NativePeerConnectionEvent>.Continuation

  public override init() {
    let stream = AsyncStream<NativePeerConnectionEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    events = stream.stream
    continuation = stream.continuation
    super.init()
  }

  deinit {
    continuation.finish()
  }

  private func emit(_ event: NativePeerConnectionEvent) {
    continuation.yield(event)
  }
}

extension PeerConnectionEventBridge: RTCPeerConnectionDelegate {
  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange stateChanged: RTCSignalingState
  ) {}

  public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove stream: RTCMediaStream
  ) {}

  public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
    emit(.negotiationNeeded)
  }

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceConnectionState
  ) {
    // The aggregate RTCPeerConnectionState is not driven on every WebRTC build,
    // so the ICE transport state is the reliable signal that media connectivity
    // did or did not establish. Map it onto the same event; `disconnected` is
    // transient and deliberately not surfaced as a hard failure.
    let state: NativePeerConnectionState
    switch newState {
    case .new: state = .new
    case .checking: state = .connecting
    case .connected, .completed: state = .connected
    case .disconnected: state = .disconnected
    case .failed: state = .failed
    case .closed: state = .closed
    case .count: return
    @unknown default: return
    }
    emit(.connectionStateChanged(state))
  }

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceGatheringState
  ) {}

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {
    emit(
      .localCandidate(
        NativeICECandidate(
          sdp: candidate.sdp,
          mid: candidate.sdpMid,
          mediaLineIndex: candidate.sdpMLineIndex
        )
      )
    )
  }

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove candidates: [RTCIceCandidate]
  ) {}

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didOpen dataChannel: RTCDataChannel
  ) {}

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCPeerConnectionState
  ) {
    let state: NativePeerConnectionState
    switch newState {
    case .new: state = .new
    case .connecting: state = .connecting
    case .connected: state = .connected
    case .disconnected: state = .disconnected
    case .failed: state = .failed
    case .closed: state = .closed
    @unknown default: state = .failed
    }
    emit(.connectionStateChanged(state))
  }

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didAdd rtpReceiver: RTCRtpReceiver,
    streams mediaStreams: [RTCMediaStream]
  ) {
    guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
    let ssrc = rtpReceiver.parameters.encodings.first?.ssrc?.uint32Value
    emit(.remoteVideoTrackAdded(RemoteVideoTrack(track: track), ssrc: ssrc))
  }

  public func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove rtpReceiver: RTCRtpReceiver
  ) {
    guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
    emit(.remoteVideoTrackRemoved(id: track.trackId))
  }
}
