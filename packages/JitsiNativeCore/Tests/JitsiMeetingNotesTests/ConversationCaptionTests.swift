import Foundation
import JitsiMeetingNotes
import Testing

/// Captions follow the last thing said: a line or two, kept while the words
/// are current and cleared once the room goes quiet.
private func conversation() -> ConversationDocument {
  var document = ConversationDocument(title: "Conversation")
  document.updateParticipants([
    .init(id: "alex", name: "Alex"), .init(id: "sam", name: "Sam"),
  ])
  return document
}

@Test func showsTheLastTwoLinesOfSpeech() {
  var document = conversation()
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 2, text: "First thing", isFinal: true)
  document.recognize(
    streamID: "b", participantID: "sam", start: 3, end: 5, text: "Second thing", isFinal: true)
  document.recognize(
    streamID: "a", participantID: "alex", start: 6, end: 8, text: "Third thing", isFinal: true)

  let lines = document.captions(at: 8)
  #expect(lines.map(\.text) == ["Second thing", "Third thing"])
  #expect(lines.map(\.speaker) == ["Sam", "Alex"])
  #expect(lines.allSatisfy { $0.opacity == 1 })
}

@Test func aLineFadesOutAndThenLeaves() {
  var document = conversation()
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 2, text: "Fading", isFinal: true)

  #expect(document.captions(at: 6).first?.opacity == 1)
  // Held for five seconds after the words were spoken, then a second of fade.
  let half = document.captions(at: 7.5).first
  #expect(half?.opacity == 0.5)
  #expect(document.captions(at: 8.1).isEmpty)
}

@Test func speechInProgressKeepsItsLineAlive() {
  var document = conversation()
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 2, text: "Still", isFinal: false)
  #expect(document.captions(at: 10).isEmpty)
  // The same turn, extended: recognition moved its end, so the line is new
  // again rather than stale.
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 10, text: "Still talking", isFinal: false)
  let line = document.captions(at: 10).first
  #expect(line?.text == "Still talking")
  #expect(line?.isFinal == false)
  #expect(line?.opacity == 1)
}

@Test func overlappingSpeakersKeepTheMostRecentLines() {
  var document = conversation()
  // Alex talks across Sam's shorter remark, and finishes last.
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 9, text: "A long thought", isFinal: true)
  document.recognize(
    streamID: "b", participantID: "sam", start: 1, end: 2, text: "Quick reply", isFinal: true)
  document.recognize(
    streamID: "b", participantID: "sam", start: 3, end: 4, text: "And another", isFinal: true)

  // Sam's first remark has aged out; the two that are still current stay in
  // the order they were spoken, not in the order they ended.
  let lines = document.captions(at: 9)
  #expect(lines.map(\.text) == ["A long thought", "And another"])
}

@Test func deletedAndMultilineTurnsAreHandled() throws {
  var document = conversation()
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 1, text: "Deleted", isFinal: true)
  let deleted = try #require(document.turns.first?.id)
  document.edit(.turn(deleted), text: "")
  document.recognize(
    streamID: "b", participantID: "sam", start: 2, end: 3, text: "Kept", isFinal: true)
  let kept = try #require(document.turns.last?.id)
  document.edit(.turn(kept), text: "A correction\ntyped over  two lines")

  let lines = document.captions(at: 3)
  #expect(lines.map(\.text) == ["A correction typed over two lines"])
}

@Test func yourOwnSpeechIsNotCaptioned() {
  var document = conversation()
  document.updateParticipants([
    .init(id: "local", name: "You"), .init(id: "alex", name: "Alex"),
  ])
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 2, text: "Their remark", isFinal: true)
  // Two of your own remarks after theirs. Filtering after the last two lines
  // were chosen would leave the screen blank instead of showing Alex.
  document.recognize(
    streamID: "local-1", participantID: "local", start: 3, end: 4, text: "Mine", isFinal: true)
  document.recognize(
    streamID: "local-2", participantID: "local", start: 4, end: 5, text: "Also mine", isFinal: true)

  #expect(document.captions(at: 5, excludingSpeaker: "local").map(\.text) == ["Their remark"])
  // The transcript still has every word; only the overlay leaves yours out.
  #expect(document.turns.count == 3)
  #expect(document.captions(at: 5).map(\.text) == ["Mine", "Also mine"])
}

@Test func aQuietRoomShowsNothing() {
  #expect(conversation().captions(at: 0).isEmpty)
  var document = conversation()
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 1, text: "Old news", isFinal: true)
  #expect(document.captions(at: 300).isEmpty)
  #expect(document.captions(at: 1, lines: 0).isEmpty)
}
