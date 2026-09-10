import Foundation

extension ConversationDocument {
  /// One line of the closed captions drawn over the video.
  public struct CaptionLine: Identifiable, Equatable, Sendable {
    /// The turn behind the line. A line whose speaker is still talking keeps
    /// its identity as words are added, so it grows in place instead of
    /// being replaced.
    public let id: UUID
    public let speaker: String
    public let text: String
    /// Whether recognition has settled on these words.
    public let isFinal: Bool
    /// Full while the line is current, easing to zero as it ages out.
    public let opacity: Double

    public init(id: UUID, speaker: String, text: String, isFinal: Bool, opacity: Double) {
      self.id = id
      self.speaker = speaker
      self.text = text
      self.isFinal = isFinal
      self.opacity = opacity
    }
  }

  /// How far back the captions look for speech that is still on screen. The
  /// transcriber runs at most eight remote recognizers plus the local one,
  /// so a dozen turns covers everything that can be in flight at once.
  private static let captionWindow = 12

  /// The last line or two of speech `elapsed` seconds into the conversation,
  /// oldest first, leaving out `excludingSpeaker` — the caller's own
  /// participant, whose words they do not need read back to them.
  ///
  /// A line stays lit for `hold` seconds after the words on it were spoken
  /// and then fades over `fade`, so captions follow the conversation and
  /// clear themselves once it goes quiet. Speech that keeps going keeps its
  /// line alive; when more people overlap than there are lines, the ones who
  /// spoke most recently are the ones shown.
  public func captions(
    at elapsed: TimeInterval,
    excludingSpeaker excluded: String? = nil,
    lines maximum: Int = 2,
    hold: TimeInterval = 5,
    fade: TimeInterval = 1
  ) -> [CaptionLine] {
    guard maximum > 0, fade > 0 else { return [] }
    var live: [(turn: Turn, text: String, opacity: Double)] = []
    // Excluded before the window rather than after it: someone talking over
    // themselves would otherwise push everyone else's line off the screen.
    for turn in turns.filter({ $0.participantID != excluded }).suffix(Self.captionWindow) {
      let text = Self.caption(turn.text)
      guard !text.isEmpty else { continue }
      // Recognition can hand back a range ending a shade ahead of the
      // clock; a line is never brighter than fully lit.
      let age = elapsed - turn.end
      let opacity = age <= hold ? 1 : 1 - (age - hold) / fade
      guard opacity > 0 else { continue }
      live.append((turn, text, min(1, opacity)))
    }
    // Recency decides which lines survive, but they read in the order they
    // were spoken — overlapping speakers keep their turn on screen.
    let newest = Set(live.sorted { $0.turn.end < $1.turn.end }.suffix(maximum).map(\.turn.id))
    return live.filter { newest.contains($0.turn.id) }.map { entry in
      CaptionLine(
        id: entry.turn.id,
        speaker: name(for: entry.turn.participantID),
        text: entry.text,
        isFinal: entry.turn.isFinal,
        opacity: entry.opacity
      )
    }
  }

  /// Captions are one line of running text: a correction typed across
  /// several lines still reads as a single utterance.
  private static func caption(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
