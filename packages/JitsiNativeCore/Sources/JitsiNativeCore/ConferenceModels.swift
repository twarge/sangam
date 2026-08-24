import Foundation

public struct ParticipantID: Hashable, Codable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct MediaSourceID: Hashable, Codable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum MediaKind: String, Codable, Sendable {
  case audio
  case video
}

public enum VideoSourceType: String, Codable, Sendable {
  case camera
  case desktop
}

public struct MediaSource: Identifiable, Equatable, Codable, Sendable {
  public var id: MediaSourceID
  public var ownerID: ParticipantID
  public var kind: MediaKind
  public var videoType: VideoSourceType?
  public var isMuted: Bool

  public init(
    id: MediaSourceID,
    ownerID: ParticipantID,
    kind: MediaKind,
    videoType: VideoSourceType? = nil,
    isMuted: Bool = false
  ) {
    self.id = id
    self.ownerID = ownerID
    self.kind = kind
    self.videoType = videoType
    self.isMuted = isMuted
  }
}

public struct Participant: Identifiable, Equatable, Codable, Sendable {
  public var id: ParticipantID
  public var displayName: String
  public var isModerator: Bool
  public var sources: [MediaSource]

  public init(
    id: ParticipantID,
    displayName: String,
    isModerator: Bool = false,
    sources: [MediaSource] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.isModerator = isModerator
    self.sources = sources
  }
}

public enum ConferencePhase: Equatable, Codable, Sendable {
  case idle
  case discovering
  case connecting
  case joining
  case joined
  case reconnecting(attempt: Int)
  case leaving
  case ended
  case failed(message: String, recoverable: Bool)
}

public enum PublicationState: String, Codable, Sendable {
  case absent
  case starting
  case published
  case stopping
  case failed
}

public struct LocalMediaState: Equatable, Codable, Sendable {
  public var isMicrophoneMuted: Bool
  public var camera: PublicationState
  public var screenShare: PublicationState

  public init(
    isMicrophoneMuted: Bool = false,
    camera: PublicationState = .absent,
    screenShare: PublicationState = .absent
  ) {
    self.isMicrophoneMuted = isMicrophoneMuted
    self.camera = camera
    self.screenShare = screenShare
  }
}

public struct ConferenceSnapshot: Equatable, Codable, Sendable {
  public var phase: ConferencePhase
  public var localMedia: LocalMediaState
  public var participants: [Participant]
  public var selectedVideoSourceID: MediaSourceID?
  public var dominantSpeakerID: ParticipantID?
  public var connectionQuality: Int?

  public init(
    phase: ConferencePhase = .idle,
    localMedia: LocalMediaState = .init(),
    participants: [Participant] = [],
    selectedVideoSourceID: MediaSourceID? = nil,
    dominantSpeakerID: ParticipantID? = nil,
    connectionQuality: Int? = nil
  ) {
    self.phase = phase
    self.localMedia = localMedia
    self.participants = participants
    self.selectedVideoSourceID = selectedVideoSourceID
    self.dominantSpeakerID = dominantSpeakerID
    self.connectionQuality = connectionQuality
  }
}

public struct JoinRequest: Equatable, Sendable {
  public var serverURL: URL
  public var room: String
  public var displayName: String
  public var token: String?

  public init(serverURL: URL, room: String, displayName: String, token: String? = nil) {
    self.serverURL = serverURL
    self.room = room
    self.displayName = displayName
    self.token = token
  }
}
