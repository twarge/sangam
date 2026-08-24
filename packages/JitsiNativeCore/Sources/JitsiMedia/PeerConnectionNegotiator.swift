import Foundation
import JitsiConcurrency
@preconcurrency import WebRTC

public enum PeerConnectionNegotiationError: Error, Equatable, Sendable {
  case operationFailed(operation: String, message: String)
  case missingSessionDescription(operation: String)
  case addLocalTrackFailed(id: String)
  case missingTransceiver(mid: String)
}

extension PeerConnectionNegotiationError: LocalizedError {
  // Without this, the failing operation and WebRTC's own message are lost to
  // the generic "PeerConnectionNegotiationError error 0", which is useless when
  // a negotiation fails against a live deployment.
  public var errorDescription: String? {
    switch self {
    case .operationFailed(let operation, let message):
      return "WebRTC could not \(operation): \(message)"
    case .missingSessionDescription(let operation):
      return "WebRTC produced no session description while trying to \(operation)."
    case .addLocalTrackFailed(let id):
      return "WebRTC refused to publish the local track \(id)."
    case .missingTransceiver(let mid):
      return "There is no media line \"\(mid)\" to publish the local source on."
    }
  }
}

public struct LocalSourceNegotiation: Equatable, Sendable {
  public var previousLocalSDP: String?
  public var localSDP: String

  public init(previousLocalSDP: String?, localSDP: String) {
    self.previousLocalSDP = previousLocalSDP
    self.localSDP = localSDP
  }
}

/// Serializes SDP and ICE mutations for one native WebRTC peer connection.
///
/// Every entry point runs on `queue`, so a full offer/answer sequence completes
/// before the next one starts. Being an actor is not sufficient on its own:
/// each `await` inside a sequence releases the actor and would otherwise let a
/// concurrent caller interleave its own `setRemoteDescription` mid-negotiation.
/// The `perform` methods below are the unserialized implementations and may
/// only be called from inside a queued operation.
public actor PeerConnectionNegotiator {
  private let connection: RTCPeerConnection
  private let queue = SerialTaskQueue()

  public init(connection: RTCPeerConnection) {
    self.connection = connection
  }

  /// Applies Jicofo's translated offer, creates the native WebRTC answer, and
  /// installs that answer before returning its SDP for Jingle serialization.
  public func answer(remoteOfferSDP: String) async throws -> String {
    try await queue.run {
      try await self.performAnswer(remoteOfferSDP: remoteOfferSDP)
    }
  }

  public func answer(
    remoteOfferSDP: String,
    localAudioTrack: LocalAudioTrack?,
    localVideoTracks: [LocalVideoTrack],
    streamID: String
  ) async throws -> String {
    try await queue.run {
      try await self.setRemoteDescription(
        RTCSessionDescription(type: .offer, sdp: remoteOfferSDP),
        operation: "set remote offer"
      )
      if let localAudioTrack {
        try await self.addLocalTrackIfNeeded(localAudioTrack.track, streamID: streamID)
      }
      for videoTrack in localVideoTracks {
        try await self.addLocalTrackIfNeeded(videoTrack.track, streamID: streamID)
      }
      let answer = try await self.createDescription(type: .answer)
      try await self.setLocalDescription(answer, operation: "set local answer")
      return answer.sdp
    }
  }

  /// Creates and installs a local offer for renegotiation initiated by Apple
  /// capture or device state changes.
  public func offer() async throws -> String {
    try await queue.run {
      let offer = try await self.createDescription(type: .offer)
      try await self.setLocalDescription(offer, operation: "set local offer")
      return offer.sdp
    }
  }

  public func apply(remoteAnswerSDP: String) async throws {
    try await queue.run {
      try await self.setRemoteDescription(
        RTCSessionDescription(type: .answer, sdp: remoteAnswerSDP),
        operation: "set remote answer"
      )
    }
  }

  /// Reads the installed remote description. Callers that go on to derive a new
  /// offer from this SDP must hold their own serialization across both steps;
  /// this read is deliberately not queued so it cannot deadlock behind the
  /// operation that is about to use it.
  public func currentRemoteSDP() -> String? {
    connection.remoteDescription?.sdp
  }

  /// Allocates a new responder sender on the media line named by `mid`, using
  /// the same two-answer sequence as lib-jitsi-meet's Unified Plan multi-stream
  /// implementation.
  ///
  /// The track is bound to that media line explicitly. `RTCPeerConnection.add`
  /// would instead let WebRTC reuse any compatible transceiver that has never
  /// sent, which silently steals a receive-only line — the camera line of a
  /// camera-off participant, for instance — and leaves `mid` with no source to
  /// describe.
  public func addLocalVideoSource(
    _ track: LocalVideoTrack,
    streamID: String,
    mid: String,
    expandedRemoteOfferSDP: String
  ) async throws -> LocalSourceNegotiation {
    try await queue.run {
      let previousLocalSDP = await self.currentLocalSDP()
      _ = try await self.performAnswer(remoteOfferSDP: expandedRemoteOfferSDP)
      try await self.attachLocalTrack(track.track, toMID: mid, streamID: streamID)
      let finalSDP = try await self.performAnswer(remoteOfferSDP: expandedRemoteOfferSDP)
      return LocalSourceNegotiation(previousLocalSDP: previousLocalSDP, localSDP: finalSDP)
    }
  }

  public func answerRenegotiation(remoteOfferSDP: String) async throws -> String {
    try await queue.run {
      try await self.performAnswer(remoteOfferSDP: remoteOfferSDP)
    }
  }

  public func addRemoteCandidate(
    sdp: String,
    mid: String?,
    mediaLineIndex: Int32
  ) async throws {
    try await queue.run {
      try await self.performAddRemoteCandidate(
        sdp: sdp,
        mid: mid,
        mediaLineIndex: mediaLineIndex
      )
    }
  }

  public func restartICE() async {
    try? await queue.run { self.connection.restartIce() }
  }

  /// Activates or deactivates the encodings of the sender carrying `trackID`.
  /// Capture continues (a self-preview keeps rendering); only the outgoing
  /// RTP stops — what the bridge asks for when no receiver wants the source
  /// (SenderSourceConstraints with maxHeight 0).
  public func setVideoSenderActive(trackID: String, active: Bool) async {
    try? await queue.run {
      guard
        let sender = self.connection.senders.first(where: { $0.track?.trackId == trackID })
      else { return }
      let parameters = sender.parameters
      guard parameters.encodings.contains(where: { $0.isActive != active }) else { return }
      for encoding in parameters.encodings { encoding.isActive = active }
      sender.parameters = parameters
    }
  }

  /// A concise one-line summary of media flow, for the opt-in `GAFSAF_LOG`
  /// bring-up log: ICE state and the video/audio send and receive rates. Reads
  /// the live `RTCStatisticsReport`, extracting only Sendable primitives so no
  /// non-Sendable object crosses back out.
  public func videoStatsSummary() async -> String {
    let iceState = Self.iceStateName(connection.iceConnectionState)
    return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
      connection.statistics { report in
        func field(_ values: [String: NSObject], _ key: String) -> String {
          values[key].map { "\($0)" } ?? "?"
        }
        var parts = ["ice=\(iceState)"]
        for statistics in report.statistics.values {
          let values = statistics.values
          switch statistics.type {
          case "outbound-rtp" where values["kind"] as? String == "video":
            parts.append(
              "vsend \(field(values, "frameWidth"))x\(field(values, "frameHeight"))"
                + " enc=\(field(values, "framesEncoded"))")
          case "outbound-rtp" where values["kind"] as? String == "audio":
            parts.append("asend bytes=\(field(values, "bytesSent"))")
          case "inbound-rtp" where values["kind"] as? String == "video":
            parts.append(
              "vrecv \(field(values, "frameWidth"))x\(field(values, "frameHeight"))"
                + " dec=\(field(values, "framesDecoded"))")
          case "inbound-rtp" where values["kind"] as? String == "audio":
            parts.append("arecv bytes=\(field(values, "bytesReceived"))")
          default:
            break
          }
        }
        continuation.resume(returning: parts.joined(separator: " | "))
      }
    }
  }

  /// The number of remote ICE candidates WebRTC currently holds, read from the
  /// live statistics report. Unlike a running counter this reflects what WebRTC
  /// actually accepted, which is exactly the regression worth guarding: the
  /// bridge's candidates ride inline in the session-initiate and WebRTC does not
  /// parse them from the offer SDP, so the coordinator must add each explicitly.
  public func remoteCandidateCount() async -> Int {
    await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
      connection.statistics { report in
        let count = report.statistics.values.filter { $0.type == "remote-candidate" }.count
        continuation.resume(returning: count)
      }
    }
  }

  private nonisolated static func iceStateName(_ state: RTCIceConnectionState) -> String {
    switch state {
    case .new: "new"
    case .checking: "checking"
    case .connected: "connected"
    case .completed: "completed"
    case .failed: "failed"
    case .disconnected: "disconnected"
    case .closed: "closed"
    case .count: "count"
    @unknown default: "unknown"
    }
  }

  /// Tears the connection down after any negotiation already in flight has
  /// finished, so WebRTC never sees a close land between two halves of an
  /// offer/answer exchange.
  public func close() async {
    try? await queue.run { self.connection.close() }
  }

  private func currentLocalSDP() -> String? {
    connection.localDescription?.sdp
  }

  private func performAnswer(remoteOfferSDP: String) async throws -> String {
    try await setRemoteDescription(
      RTCSessionDescription(type: .offer, sdp: remoteOfferSDP),
      operation: "set remote offer"
    )
    let answer = try await createDescription(type: .answer)
    try await setLocalDescription(answer, operation: "set local answer")
    return answer.sdp
  }

  private func performAddRemoteCandidate(
    sdp: String,
    mid: String?,
    mediaLineIndex: Int32
  ) async throws {
    let candidate = RTCIceCandidate(
      sdp: sdp,
      sdpMLineIndex: mediaLineIndex,
      sdpMid: mid
    )
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.add(candidate) { error in
        if let error {
          continuation.resume(
            throwing: PeerConnectionNegotiationError.operationFailed(
              operation: "add remote ICE candidate",
              message: error.localizedDescription
            )
          )
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func addLocalTrackIfNeeded(_ track: RTCMediaStreamTrack, streamID: String) throws {
    if connection.senders.contains(where: { $0.track?.trackId == track.trackId }) { return }
    guard connection.add(track, streamIds: [streamID]) != nil else {
      throw PeerConnectionNegotiationError.addLocalTrackFailed(id: track.trackId)
    }
  }

  /// Binds `track` to the transceiver carrying `mid` and marks that media line
  /// send-only, which is the direction Jicofo offered it as.
  private func attachLocalTrack(
    _ track: RTCMediaStreamTrack,
    toMID mid: String,
    streamID: String
  ) throws {
    guard let transceiver = connection.transceivers.first(where: { $0.mid == mid }) else {
      throw PeerConnectionNegotiationError.missingTransceiver(mid: mid)
    }
    if transceiver.sender.track?.trackId == track.trackId { return }
    transceiver.sender.track = track
    transceiver.sender.streamIds = [streamID]

    var directionError: NSError?
    transceiver.setDirection(.sendOnly, error: &directionError)
    if let directionError {
      throw PeerConnectionNegotiationError.operationFailed(
        operation: "publish local source on \(mid)",
        message: directionError.localizedDescription
      )
    }
  }

  private func createDescription(type: RTCSdpType) async throws -> RTCSessionDescription {
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let operation = type == .offer ? "create offer" : "create answer"
    return try await withCheckedThrowingContinuation { continuation in
      let completion: @Sendable (RTCSessionDescription?, Error?) -> Void = {
        description, error in
        if let error {
          continuation.resume(
            throwing: PeerConnectionNegotiationError.operationFailed(
              operation: operation,
              message: error.localizedDescription
            )
          )
        } else if let description {
          continuation.resume(returning: description)
        } else {
          continuation.resume(
            throwing: PeerConnectionNegotiationError.missingSessionDescription(
              operation: operation
            )
          )
        }
      }
      if type == .offer {
        connection.offer(for: constraints, completionHandler: completion)
      } else {
        connection.answer(for: constraints, completionHandler: completion)
      }
    }
  }

  private func setLocalDescription(
    _ description: RTCSessionDescription,
    operation: String
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.setLocalDescription(description) { error in
        Self.resume(continuation, operation: operation, error: error)
      }
    }
  }

  private func setRemoteDescription(
    _ description: RTCSessionDescription,
    operation: String
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.setRemoteDescription(description) { error in
        Self.resume(continuation, operation: operation, error: error)
      }
    }
  }

  private nonisolated static func resume(
    _ continuation: CheckedContinuation<Void, any Error>,
    operation: String,
    error: Error?
  ) {
    if let error {
      continuation.resume(
        throwing: PeerConnectionNegotiationError.operationFailed(
          operation: operation,
          message: error.localizedDescription
        )
      )
    } else {
      continuation.resume()
    }
  }
}
