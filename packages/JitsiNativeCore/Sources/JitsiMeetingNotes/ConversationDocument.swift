import Foundation

/// The editable document is independent of a meeting connection and of Speech.
/// Recognition owns originalText; a user correction (including deletion) wins.
public struct ConversationDocument: Equatable, Sendable {
  public struct Participant: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var hasLeft: Bool
    public init(id: String, name: String, hasLeft: Bool = false) {
      self.id = id
      self.name = name
      self.hasLeft = hasLeft
    }
  }

  public struct Turn: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let streamID: String
    public let participantID: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var originalText: String
    public var correction: String?
    public var isFinal: Bool
    public var text: String { correction ?? originalText }
  }

  public enum Field: Hashable, Sendable {
    case title, summary, notes
    case turn(UUID)
  }

  public struct Region: Equatable, Sendable {
    public let field: Field
    public let range: NSRange
  }

  public struct Rendering: Equatable, Sendable {
    public let text: String
    public let regions: [Region]
    public let provisionalRanges: [NSRange]
    /// Structural headings and speaker labels remain protected. A text edit
    /// must belong to one field, including insertion into an empty field.
    public func region(containing range: NSRange) -> Region? {
      regions.first {
        range.location >= $0.range.location && NSMaxRange(range) <= NSMaxRange($0.range)
      }
    }

    /// The closest position inside a field to `location`, for a caret that
    /// landed on structure instead of content.
    ///
    /// An empty field is a single position, so the blank line under an empty
    /// Notes heading looks like somewhere to write and is not. Ties go to the
    /// earlier field, which is the section the blank space below it belongs
    /// to.
    public func nearestPosition(to location: Int) -> Int? {
      regions
        .map { min(max(location, $0.range.location), NSMaxRange($0.range)) }
        .min { abs($0 - location) < abs($1 - location) }
    }
  }

  public private(set) var title: String
  public private(set) var participants: [Participant] = []
  public private(set) var summary = "Summary will appear as the conversation develops."
  public private(set) var notes = ""
  public private(set) var turns: [Turn] = []
  public private(set) var revision: UInt64 = 0
  public private(set) var savedRevision: UInt64 = 0
  public private(set) var contentRevision: UInt64 = 0
  public private(set) var titleEdited = false
  public private(set) var summaryEdited = false
  public var isDirty: Bool { revision != savedRevision }

  public init(title: String) { self.title = title.isEmpty ? "Conversation" : title }

  public mutating func markSaved(revision saved: UInt64) {
    // A save is a snapshot. New speech arriving while a save panel is open
    // must still count as unsaved after the older snapshot reaches disk.
    savedRevision = min(saved, revision)
  }

  public mutating func updateParticipants(_ current: [Participant]) {
    var updated = participants
    let ids = Set(current.map(\.id))
    for index in updated.indices { updated[index].hasLeft = !ids.contains(updated[index].id) }
    for participant in current {
      if let index = updated.firstIndex(where: { $0.id == participant.id }) {
        updated[index] = participant
      } else {
        updated.append(participant)
      }
    }
    guard updated != participants else { return }
    participants = updated
    changed(content: true)
  }

  public func name(for participantID: String) -> String {
    guard let participant = participants.first(where: { $0.id == participantID }) else {
      return "Unknown participant"
    }
    let name = Self.inline(participant.name.isEmpty ? "Participant" : participant.name)
    let duplicates = participants.filter { Self.inline($0.name) == name }.count
    return duplicates > 1 ? "\(name) (\(participant.id.prefix(6)))" : name
  }

  public mutating func recognize(
    streamID: String, participantID: String, start: TimeInterval, end: TimeInterval,
    text: String, isFinal: Bool
  ) {
    guard start.isFinite, end.isFinite, end >= start else { return }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    // Speech replaces time ranges, rather than appending every provisional
    // result. A finalized range cannot be replayed after a reconnect.
    if turns.contains(where: {
      $0.streamID == streamID && $0.isFinal && abs($0.start - start) < 0.001
    }) {
      return
    }
    let overlaps = turns.indices.filter {
      turns[$0].streamID == streamID && !turns[$0].isFinal
        && (abs(turns[$0].start - start) < 0.001
          || (turns[$0].start < end && turns[$0].end > start))
    }
    if let first = overlaps.first {
      turns[first].originalText = text
      turns[first].start = min(turns[first].start, start)
      turns[first].end = end
      turns[first].isFinal = isFinal
      // If recognition combines several provisional segments, retain any
      // human corrections, including empty corrections, as protected turns.
      for index in overlaps.dropFirst().reversed() {
        if turns[index].correction == nil {
          turns.remove(at: index)
        } else {
          turns[index].isFinal = isFinal
        }
      }
    } else {
      turns.append(
        Turn(
          id: UUID(), streamID: streamID, participantID: participantID,
          start: start, end: end, originalText: text, isFinal: isFinal
        ))
    }
    turns.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    changed(content: isFinal)
  }

  public func value(for field: Field) -> String? {
    switch field {
    case .title: title
    case .summary: summary
    case .notes: notes
    case .turn(let id): turns.first { $0.id == id }?.text
    }
  }

  public mutating func edit(_ field: Field, text: String) {
    guard value(for: field) != text else { return }
    switch field {
    case .title:
      title = Self.inline(text)
      titleEdited = true
    case .summary:
      summary = text
      summaryEdited = true
    case .notes: notes = text
    case .turn(let id):
      guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
      turns[index].correction = text
    }
    changed(content: true)
  }

  public mutating func applySummary(title: String, summary: String, basedOn content: UInt64) {
    guard content == contentRevision else { return }
    let oldTitle = self.title
    let oldSummary = self.summary
    if !titleEdited, !title.isEmpty { self.title = Self.inline(title) }
    if !summaryEdited, !summary.isEmpty { self.summary = summary }
    if oldTitle != self.title || oldSummary != self.summary { changed(content: false) }
  }

  /// New utterances may arrive while the model works. A summary of the
  /// earlier snapshot is still useful, provided none of its source turns
  /// or speaker identities has been corrected in the meantime.
  @discardableResult
  public mutating func applySummary(title: String, summary: String, basedOn snapshot: Self) -> Bool
  {
    guard participants == snapshot.participants else { return false }
    let current = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
    for source in snapshot.turns where source.isFinal && !source.text.isEmpty {
      guard let turn = current[source.id], turn.isFinal, turn.text == source.text,
        turn.participantID == source.participantID
      else { return false }
    }
    applySummary(title: title, summary: summary, basedOn: contentRevision)
    return true
  }

  public func render(allowUnfinishedEdits: Bool = false) -> Rendering {
    var text = "# "
    var regions: [Region] = []
    var provisional: [NSRange] = []
    func appendField(_ field: Field, _ value: String) {
      regions.append(
        Region(field: field, range: NSRange(location: text.utf16.count, length: value.utf16.count)))
      text += value
    }
    appendField(.title, title)
    text += "\n\n## Participants\n\n"
    for participant in participants {
      text += "- \(name(for: participant.id))\(participant.hasLeft ? " (left)" : "")\n"
    }
    text += "\n## Summary\n\n"
    appendField(.summary, summary)
    text += "\n\n## Notes\n\n"
    appendField(.notes, notes)
    text += "\n\n## Transcript\n"
    for turn in turns {
      // Keep an editable empty field for a deleted turn, but never restore
      // the deleted words from a later recognition update.
      text += "\n\(name(for: turn.participantID)): "
      let location = text.utf16.count
      // Speech may split or combine provisional results. Wait for a stable
      // turn before accepting edits; earlier turns stay editable while
      // new provisional words continue to arrive.
      if turn.isFinal || allowUnfinishedEdits {
        appendField(.turn(turn.id), turn.text)
      } else {
        text += turn.text
      }
      if !turn.isFinal {
        provisional.append(NSRange(location: location, length: turn.text.utf16.count))
      }
      text += "\n"
    }
    return Rendering(text: text, regions: regions, provisionalRanges: provisional)
  }

  /// Export omits user-deleted turns and identifies unfinished speech.
  public var markdown: String {
    var export = self
    export.turns.removeAll { $0.text.isEmpty }
    for index in export.turns.indices where !export.turns[index].isFinal {
      export.turns[index].correction = export.turns[index].text + " [unfinished]"
    }
    return export.render().text
  }

  private mutating func changed(content: Bool) {
    revision &+= 1
    if content { contentRevision &+= 1 }
  }

  private static func inline(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ")
      .replacingOccurrences(of: ":", with: "∶")
  }
}
