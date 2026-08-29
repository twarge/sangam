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

/// Receive-side health of one remote video stream, for per-tile connection
/// indicators.
public struct InboundVideoStatistic: Equatable, Sendable {
  public var trackID: String
  public var frameHeight: Int
  public var framesPerSecond: Double
  public var packetsLost: Int
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
  /// Munges local answers so outgoing video is sent as three simulcast
  /// layers, exactly as the web client does. `SANGAM_NO_SIMULCAST=1` turns
  /// the munging off for bring-up comparisons.
  private var simulcast = LocalSimulcastMunger()
  private let simulcastEnabled =
    ProcessInfo.processInfo.environment["SANGAM_NO_SIMULCAST"] != "1"
  /// Local video tracks that should encode as three simulcast layers, by
  /// track id; the value records whether the track is a screen share (whose
  /// ladder allows a higher top-layer bitrate).
  private var simulcastProfiles: [String: Bool] = [:]
  /// The bridge's last SenderSourceConstraints height cap per local video
  /// track; -1 (unconstrained) until the bridge says otherwise.
  private var senderMaxHeights: [String: Int] = [:]

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
        await self.registerSimulcastProfile(
          trackID: videoTrack.id, isScreenShare: videoTrack.isScreenCast)
      }
      return try await self.createAndInstallAnswer()
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
      await self.registerSimulcastProfile(trackID: track.id, isScreenShare: track.isScreenCast)
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

  /// Opens the bridge channel as a WebRTC data channel, with the label and
  /// protocol the videobridge expects (BridgeChannel.ts). Only meaningful
  /// once the remote description carries the SCTP "data" m-line; returns nil
  /// if WebRTC refuses to create the channel.
  public func makeBridgeDataChannel() async -> BridgeDataChannel? {
    (try? await queue.run { () -> BridgeDataChannel? in
      let configuration = RTCDataChannelConfiguration()
      configuration.isOrdered = true
      configuration.`protocol` = "http://jitsi.org/protocols/colibri"
      guard
        let channel = self.connection.dataChannel(
          forLabel: "JVB bridge channel", configuration: configuration)
      else { return nil }
      return BridgeDataChannel(channel: channel)
    }) ?? nil
  }

  /// Applies the bridge's height cap (SenderSourceConstraints) to the sender
  /// carrying `trackID`. Capture continues (a self-preview keeps rendering);
  /// only encoders stop: 0 deactivates every encoding, and a positive cap
  /// deactivates the simulcast layers no receiver can be sent, so the
  /// encoder stops paying for resolutions nobody is shown (see
  /// `desiredEncodingActiveStates`).
  public func setVideoSenderMaxHeight(trackID: String, maxHeight: Int) async {
    try? await queue.run {
      await self.applySenderMaxHeight(trackID: trackID, maxHeight: maxHeight)
    }
  }

  private func applySenderMaxHeight(trackID: String, maxHeight: Int) {
    guard senderMaxHeights[trackID] != maxHeight else { return }
    senderMaxHeights[trackID] = maxHeight
    applySenderEncodingParameters(trackID: trackID)
  }

  /// The encoding SSRCs on the sender carrying `trackID` — the ground truth
  /// for whether the simulcast munge actually fanned the encoder out, which
  /// the accepted SDP alone does not prove.
  public func videoSenderEncodingSSRCs(trackID: String) async -> [UInt32] {
    (try? await queue.run {
      guard
        let sender = self.connection.senders.first(where: { $0.track?.trackId == trackID })
      else { return [] }
      return sender.parameters.encodings.compactMap { $0.ssrc?.uint32Value }
    }) ?? []
  }

  /// One line per encoding on the sender carrying `trackID`, for simulcast
  /// bring-up diagnostics.
  public func videoSenderEncodingSummary(trackID: String) async -> [String] {
    (try? await queue.run {
      guard
        let sender = self.connection.senders.first(where: { $0.track?.trackId == trackID })
      else { return [] }
      return sender.parameters.encodings.map { encoding in
        "ssrc=\(encoding.ssrc?.stringValue ?? "?")"
          + " active=\(encoding.isActive)"
          + " scale=\(encoding.scaleResolutionDownBy?.doubleValue.description ?? "-")"
          + " maxBitrate=\(encoding.maxBitrateBps?.intValue.description ?? "-")"
      }
    }) ?? []
  }

  /// Per-stream receive statistics, keyed for tile indicators by the
  /// receiver's track id — the same id remote streams are announced under.
  public func inboundVideoStatistics() async -> [InboundVideoStatistic] {
    await withCheckedContinuation {
      (continuation: CheckedContinuation<[InboundVideoStatistic], Never>) in
      connection.statistics { report in
        var stats: [InboundVideoStatistic] = []
        for statistics in report.statistics.values where statistics.type == "inbound-rtp" {
          let values = statistics.values
          guard
            values["kind"] as? String == "video",
            let trackID = values["trackIdentifier"] as? String
          else { continue }
          stats.append(
            InboundVideoStatistic(
              trackID: trackID,
              frameHeight: (values["frameHeight"] as? NSNumber)?.intValue ?? 0,
              framesPerSecond: (values["framesPerSecond"] as? NSNumber)?.doubleValue ?? 0,
              packetsLost: (values["packetsLost"] as? NSNumber)?.intValue ?? 0
            )
          )
        }
        continuation.resume(returning: stats)
      }
    }
  }

  /// A concise one-line summary of media flow, for the opt-in `SANGAM_LOG`
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
        // Codec entries resolve inbound codecIds to names, which is the
        // first thing to know when a stream arrives but never decodes.
        var codecNames: [String: String] = [:]
        for statistics in report.statistics.values where statistics.type == "codec" {
          if let mimeType = statistics.values["mimeType"] as? String {
            codecNames[statistics.id] = mimeType
          }
        }
        var parts = ["ice=\(iceState)"]
        for statistics in report.statistics.values {
          let values = statistics.values
          switch statistics.type {
          case "outbound-rtp" where values["kind"] as? String == "video":
            parts.append(
              "vsend ssrc=\(field(values, "ssrc"))"
                + " \(field(values, "frameWidth"))x\(field(values, "frameHeight"))"
                + " enc=\(field(values, "framesEncoded"))"
                + " sent=\(field(values, "bytesSent"))")
          case "outbound-rtp" where values["kind"] as? String == "audio":
            parts.append("asend bytes=\(field(values, "bytesSent"))")
          case "inbound-rtp" where values["kind"] as? String == "video":
            let codec = (values["codecId"] as? String).flatMap { codecNames[$0] } ?? "?"
            parts.append(
              "vrecv ssrc=\(field(values, "ssrc"))"
                + " codec=\(codec)"
                + " \(field(values, "frameWidth"))x\(field(values, "frameHeight"))"
                + " dec=\(field(values, "framesDecoded"))"
                + " bytes=\(field(values, "bytesReceived"))")
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
    return try await createAndInstallAnswer()
  }

  /// Creates the local answer, munges simulcast into its sending video
  /// sections, installs it, and returns the installed SDP — the munged form
  /// is also what Jingle serialization must advertise.
  private func createAndInstallAnswer() async throws -> String {
    let answer = try await createDescription(type: .answer)
    let preferred = CodecPreferenceMunger.preferVP8(answer.sdp)
    let sdp = simulcastEnabled ? simulcast.munge(preferred) : preferred
    try await setLocalDescription(
      RTCSessionDescription(type: .answer, sdp: sdp),
      operation: "set local answer"
    )
    if simulcastEnabled { applySimulcastLayerParameters() }
    return sdp
  }

  private func registerSimulcastProfile(trackID: String, isScreenShare: Bool) {
    simulcastProfiles[trackID] = isScreenShare
  }

  /// The camera's configured capture height, which anchors each simulcast
  /// layer's frame height (capture / scaleResolutionDownBy) the way the
  /// reference client's `getCaptureResolution()` does.
  private static let cameraCaptureHeight = 720.0

  /// Which simulcast encodings should run, mirroring lib-jitsi-meet's
  /// `TPCUtils.calculateEncodingsActiveState`. A cap of 0 stops everything.
  /// A camera keeps the layers no taller than the bridge's cap — plus the
  /// lowest layer always, so every viewer keeps a stream. A screen share
  /// encodes only its full-resolution layer: the reference client sends the
  /// downscaled desktop layers only in high-fps screenshare deployments, and
  /// two extra encoders of a large capture are the priciest thing a share
  /// pays for.
  private func desiredEncodingActiveStates(
    isScreenShare: Bool,
    maxHeight: Int,
    layerScales: [Double]
  ) -> [Bool] {
    guard maxHeight != 0 else { return layerScales.map { _ in false } }
    if isScreenShare { return layerScales.map { $0 == 1.0 } }
    guard maxHeight > 0 else { return layerScales.map { _ in true } }
    return layerScales.enumerated().map { index, scale in
      index == 0 || Self.cameraCaptureHeight / scale <= Double(maxHeight)
    }
  }

  /// The reference client's simulcast ladder (TPCUtils `SIM_LAYERS` with the
  /// VP8 bitrates from `STANDARD_CODEC_SETTINGS`). The munged SDP creates
  /// three sender encodings, but the encoder only fans out once each carries
  /// an explicit scale factor and bitrate — without them libwebrtc keeps
  /// sending one full-resolution stream on the primary SSRC and the bridge
  /// can never downshift a viewer. Encoding order matches SIM-group order:
  /// the primary (signaled) SSRC carries the quarter-scale layer, exactly as
  /// the web client sends it.
  private func applySimulcastLayerParameters() {
    for trackID in simulcastProfiles.keys {
      applySenderEncodingParameters(trackID: trackID)
    }
  }

  /// Writes one sender's full encoding configuration — the ladder's scale
  /// factors and bitrates plus each layer's active state under the bridge's
  /// current height cap. Renegotiations rebuild sender parameters, so both
  /// halves are re-applied together from here.
  private func applySenderEncodingParameters(trackID: String) {
    guard
      let sender = connection.senders.first(where: { $0.track?.trackId == trackID })
    else { return }
    let parameters = sender.parameters
    let isScreenShare = simulcastProfiles[trackID] ?? false
    let maxHeight = senderMaxHeights[trackID] ?? -1
    var changed = false
    if simulcastEnabled, parameters.encodings.count == 3 {
      let layers: [(scale: Double, bitrate: Int)] = [
        (4.0, 200_000),
        (2.0, 500_000),
        (1.0, isScreenShare ? 2_500_000 : 1_500_000),
      ]
      let activeStates = desiredEncodingActiveStates(
        isScreenShare: isScreenShare,
        maxHeight: maxHeight,
        layerScales: layers.map(\.scale)
      )
      for (index, (encoding, layer)) in zip(parameters.encodings, layers).enumerated() {
        if encoding.scaleResolutionDownBy?.doubleValue != layer.scale {
          encoding.scaleResolutionDownBy = NSNumber(value: layer.scale)
          changed = true
        }
        if encoding.maxBitrateBps?.intValue != layer.bitrate {
          encoding.maxBitrateBps = NSNumber(value: layer.bitrate)
          changed = true
        }
        if encoding.isActive != activeStates[index] {
          encoding.isActive = activeStates[index]
          changed = true
        }
      }
    } else {
      // A single-encoding sender (SANGAM_NO_SIMULCAST) only pauses/resumes.
      let active = maxHeight != 0
      for encoding in parameters.encodings where encoding.isActive != active {
        encoding.isActive = active
        changed = true
      }
    }
    if changed { sender.parameters = parameters }
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
    // The send codec follows the REMOTE description's preference order, so
    // the codec munge must apply here too (the reference munges both
    // directions); reordering only the local answer changes nothing.
    let munged = RTCSessionDescription(
      type: description.type,
      sdp: CodecPreferenceMunger.preferVP8(description.sdp)
    )
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.setRemoteDescription(munged) { error in
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
