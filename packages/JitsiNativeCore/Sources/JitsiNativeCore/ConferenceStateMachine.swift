import Foundation

public enum ConferenceStateEvent: Equatable, Sendable {
  case beginDiscovery
  case beginConnecting
  case beginJoining
  case joined
  case reconnecting(attempt: Int)
  case participantUpserted(Participant)
  case participantRemoved(ParticipantID)
  case dominantSpeakerChanged(ParticipantID?)
  case selectedVideoChanged(MediaSourceID?)
  case connectionQualityChanged(Int?)
  case microphoneMuted(Bool)
  case cameraPublicationChanged(PublicationState)
  case screenPublicationChanged(PublicationState)
  case beginLeaving
  case ended
  case failed(message: String, recoverable: Bool)
}

public enum ConferenceStateError: Error, Equatable, Sendable {
  case invalidTransition(from: ConferencePhase, event: ConferenceStateEvent)
}

public actor ConferenceSession {
  public nonisolated let updates: AsyncStream<ConferenceSnapshot>

  private var snapshot: ConferenceSnapshot
  private let continuation: AsyncStream<ConferenceSnapshot>.Continuation

  public init(initialSnapshot: ConferenceSnapshot = .init()) {
    let stream = AsyncStream<ConferenceSnapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    updates = stream.stream
    continuation = stream.continuation
    snapshot = initialSnapshot
    continuation.yield(initialSnapshot)
  }

  deinit {
    continuation.finish()
  }

  public func currentSnapshot() -> ConferenceSnapshot {
    snapshot
  }

  @discardableResult
  public func apply(_ event: ConferenceStateEvent) throws -> ConferenceSnapshot {
    try Self.reduce(snapshot: &snapshot, event: event)
    continuation.yield(snapshot)
    return snapshot
  }

  static func reduce(snapshot: inout ConferenceSnapshot, event: ConferenceStateEvent) throws {
    switch event {
    case .beginDiscovery where snapshot.phase == .idle:
      snapshot.phase = .discovering
    case .beginConnecting where snapshot.phase == .discovering:
      snapshot.phase = .connecting
    case .beginJoining where snapshot.phase == .connecting:
      snapshot.phase = .joining
    case .joined where snapshot.phase == .joining || snapshot.phase.isReconnecting:
      snapshot.phase = .joined
    case .reconnecting(let attempt)
    where snapshot.phase == .joined || snapshot.phase.isReconnecting:
      snapshot.phase = .reconnecting(attempt: max(1, attempt))
    case .participantUpserted(let participant) where snapshot.phase.acceptsConferenceData:
      if let index = snapshot.participants.firstIndex(where: { $0.id == participant.id }) {
        snapshot.participants[index] = participant
      } else {
        snapshot.participants.append(participant)
      }
    case .participantRemoved(let id) where snapshot.phase.acceptsConferenceData:
      snapshot.participants.removeAll { $0.id == id }
      if snapshot.dominantSpeakerID == id {
        snapshot.dominantSpeakerID = nil
      }
      if let selected = snapshot.selectedVideoSourceID,
        !snapshot.participants.flatMap(\.sources).contains(where: { $0.id == selected })
      {
        snapshot.selectedVideoSourceID = nil
      }
    case .dominantSpeakerChanged(let id) where snapshot.phase.acceptsConferenceData:
      snapshot.dominantSpeakerID = id
    case .selectedVideoChanged(let id) where snapshot.phase.acceptsConferenceData:
      snapshot.selectedVideoSourceID = id
    case .connectionQualityChanged(let quality) where snapshot.phase.acceptsConferenceData:
      snapshot.connectionQuality = quality.map { min(100, max(0, $0)) }
    case .microphoneMuted(let muted) where snapshot.phase.acceptsLocalMediaChanges:
      snapshot.localMedia.isMicrophoneMuted = muted
    case .cameraPublicationChanged(let state) where snapshot.phase.acceptsLocalMediaChanges:
      snapshot.localMedia.camera = state
    case .screenPublicationChanged(let state) where snapshot.phase.acceptsLocalMediaChanges:
      snapshot.localMedia.screenShare = state
    case .beginLeaving where snapshot.phase.canLeave:
      snapshot.phase = .leaving
    case .ended where snapshot.phase == .leaving || snapshot.phase.isFailure:
      snapshot = ConferenceSnapshot(phase: .ended)
    case .failed(let message, let recoverable) where snapshot.phase != .ended:
      snapshot.phase = .failed(message: message, recoverable: recoverable)
    default:
      throw ConferenceStateError.invalidTransition(from: snapshot.phase, event: event)
    }
  }
}

extension ConferencePhase {
  fileprivate var isReconnecting: Bool {
    if case .reconnecting = self { return true }
    return false
  }

  fileprivate var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }

  fileprivate var acceptsConferenceData: Bool {
    self == .joining || self == .joined || isReconnecting
  }

  fileprivate var acceptsLocalMediaChanges: Bool {
    self == .joining || self == .joined || isReconnecting
  }

  fileprivate var canLeave: Bool {
    switch self {
    case .discovering, .connecting, .joining, .joined, .reconnecting, .failed:
      true
    case .idle, .leaving, .ended:
      false
    }
  }
}
