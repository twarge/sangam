import Foundation
import JitsiMeetingNotes
import Testing

@Test func correctionsSurviveRecognitionAndSaveRaces() throws {
  var document = ConversationDocument(title: "Conversation")
  document.recognize(
    streamID: "a", participantID: "alex", start: 1, end: 2, text: "wrong", isFinal: false)
  let id = try #require(document.turns.first?.id)
  document.edit(.turn(id), text: "corrected")
  document.recognize(
    streamID: "a", participantID: "alex", start: 1, end: 3, text: "wrong again", isFinal: true)
  #expect(document.turns.count == 1)
  #expect(document.turns[0].text == "corrected")
  let revision = document.revision
  document.edit(.notes, text: "Remember this")
  document.markSaved(revision: revision)
  #expect(document.isDirty)
  document.markSaved(revision: document.revision)
  #expect(!document.isDirty)
}

@Test func timelinesAndDeletedProvisionalText() throws {
  var document = ConversationDocument(title: "Conversation")
  document.recognize(
    streamID: "b", participantID: "b", start: 3, end: 5, text: "later", isFinal: true)
  document.recognize(
    streamID: "a", participantID: "a", start: 1, end: 2, text: "earlier", isFinal: false)
  let id = try #require(document.turns.first?.id)
  document.edit(.turn(id), text: "")
  document.recognize(
    streamID: "a", participantID: "a", start: 1, end: 2.5, text: "resurrected", isFinal: true)
  #expect(document.turns[0].text == "")
  #expect(!document.markdown.contains("resurrected"))
  #expect(document.turns[1].start == 3)
}

@Test func staleSummaryAndUserSectionsAreProtected() {
  var document = ConversationDocument(title: "Room")
  let oldRevision = document.contentRevision
  document.edit(.notes, text: "My notes")
  document.applySummary(title: "Old title", summary: "Stale", basedOn: oldRevision)
  #expect(document.title == "Room")
  document.edit(.summary, text: "My summary")
  document.applySummary(title: "Topic", summary: "Generated", basedOn: document.contentRevision)
  #expect(document.title == "Topic")
  #expect(document.summary == "My summary")
  #expect(document.notes == "My notes")
}

@Test func rosterRetainsDepartedParticipantsAndProtectsStructure() throws {
  var document = ConversationDocument(title: "Room")
  document.updateParticipants([.init(id: "one", name: "Alex"), .init(id: "two", name: "Alex")])
  document.updateParticipants([.init(id: "one", name: "Alex")])
  #expect(document.name(for: "one") != document.name(for: "two"))
  #expect(document.participants[1].hasLeft)
  let rendered = document.render()
  let notes = try #require(rendered.regions.first { $0.field == .notes })
  #expect(rendered.region(containing: notes.range)?.field == .notes)
  #expect(rendered.region(containing: NSRange(location: 0, length: 1)) == nil)
}

@Test func ongoingSpeechDoesNotStarveSummaryButCorrectionsInvalidateIt() throws {
  var document = ConversationDocument(title: "Room")
  document.recognize(
    streamID: "a", participantID: "a", start: 0, end: 1, text: "No agreement", isFinal: true)
  let snapshot = document
  document.recognize(
    streamID: "b", participantID: "b", start: 1, end: 2, text: "I will investigate", isFinal: true)
  let appended = document.applySummary(
    title: "Discussion", summary: "No agreement yet", basedOn: snapshot)
  #expect(appended)
  let id = try #require(document.turns.first?.id)
  document.edit(.turn(id), text: "We agreed")
  let corrected = document.applySummary(
    title: "Outdated", summary: "No agreement yet", basedOn: snapshot)
  #expect(!corrected)
  #expect(document.title == "Discussion")
}

@Test func finalTurnsStayEditableWhileSpeechSplitsTheProvisionalTail() throws {
  var document = ConversationDocument(title: "Room")
  document.recognize(
    streamID: "a", participantID: "a", start: 0, end: 4, text: "First sentence. Second sentence",
    isFinal: false)
  let provisionalID = try #require(document.turns.first?.id)
  #expect(!document.render().regions.contains { $0.field == .turn(provisionalID) })
  document.recognize(
    streamID: "a", participantID: "a", start: 0, end: 2, text: "First sentence.", isFinal: true)
  document.edit(.turn(provisionalID), text: "Corrected first sentence.")
  document.recognize(
    streamID: "a", participantID: "a", start: 2, end: 4, text: "Second sentence.", isFinal: true)
  #expect(document.turns.count == 2)
  #expect(document.turns.first?.text == "Corrected first sentence.")
  #expect(document.render().regions.contains { $0.field == .turn(provisionalID) })
}

@Test func aCaretBesideAnEmptyFieldFindsIt() throws {
  var document = ConversationDocument(title: "Room")
  document.updateParticipants([.init(id: "alex", name: "Alex")])
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 1, text: "Something said", isFinal: true)
  let rendering = document.render()
  let notes = try #require(rendering.regions.first { $0.field == .notes })
  // An empty Notes field is one position wide, and the blank line under its
  // heading is not it: a click there must still land in Notes.
  #expect(notes.range.length == 0)
  let besideNotes = NSRange(location: notes.range.location + 1, length: 0)
  #expect(rendering.region(containing: besideNotes) == nil)
  #expect(rendering.nearestPosition(to: notes.range.location + 1) == notes.range.location)
  #expect(rendering.nearestPosition(to: notes.range.location) == notes.range.location)

  // A caret already inside a field is left where it is, and one past the end
  // of the document lands in the last thing written.
  let title = try #require(rendering.regions.first { $0.field == .title })
  #expect(rendering.nearestPosition(to: title.range.location + 1) == title.range.location + 1)
  let end = rendering.text.utf16.count
  let turn = try #require(
    rendering.regions.last { if case .turn = $0.field { true } else { false } })
  #expect(rendering.nearestPosition(to: end) == NSMaxRange(turn.range))
}

@Test func everyHeadingIsFollowedByABlankLine() {
  var document = ConversationDocument(title: "Room")
  document.updateParticipants([.init(id: "alex", name: "Alex")])
  document.recognize(
    streamID: "a", participantID: "alex", start: 0, end: 1, text: "Hello", isFinal: true)
  document.edit(.notes, text: "A note")

  let lines = document.render().text.components(separatedBy: "\n")
  for (index, line) in lines.enumerated() where line.hasPrefix("#") && index + 1 < lines.count {
    #expect(lines[index + 1].isEmpty, "nothing between \"\(line)\" and its content")
  }
  #expect(lines.contains("## Summary"))
  #expect(!document.markdown.contains("Summary and actions"))
}
