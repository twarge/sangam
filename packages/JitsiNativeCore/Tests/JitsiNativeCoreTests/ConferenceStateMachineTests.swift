import Testing

@testable import JitsiNativeCore

@Test
func conferenceLifecycleAndSourceRemoval() async throws {
  let session = ConferenceSession()
  try await session.apply(.beginDiscovery)
  try await session.apply(.beginConnecting)
  try await session.apply(.beginJoining)
  try await session.apply(.joined)

  let participantID = ParticipantID(rawValue: "remote-1")
  let sourceID = MediaSourceID(rawValue: "remote-1-v0")
  let participant = Participant(
    id: participantID,
    displayName: "Remote",
    sources: [
      MediaSource(
        id: sourceID,
        ownerID: participantID,
        kind: .video,
        videoType: .camera
      )
    ]
  )

  try await session.apply(.participantUpserted(participant))
  try await session.apply(.selectedVideoChanged(sourceID))
  try await session.apply(.dominantSpeakerChanged(participantID))
  try await session.apply(.participantRemoved(participantID))

  let snapshot = await session.currentSnapshot()
  #expect(snapshot.participants.isEmpty)
  #expect(snapshot.selectedVideoSourceID == nil)
  #expect(snapshot.dominantSpeakerID == nil)
}

@Test
func rejectsSkippingConnectionPhases() async {
  let session = ConferenceSession()

  do {
    try await session.apply(.joined)
    Issue.record("Expected an invalid transition")
  } catch let error as ConferenceStateError {
    #expect(error == .invalidTransition(from: .idle, event: .joined))
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}

@Test
func clampsConnectionQuality() async throws {
  let session = ConferenceSession()
  try await session.apply(.beginDiscovery)
  try await session.apply(.beginConnecting)
  try await session.apply(.beginJoining)
  try await session.apply(.connectionQualityChanged(900))

  #expect(await session.currentSnapshot().connectionQuality == 100)
}
