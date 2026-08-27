import Foundation

struct MeetingConfiguration: Equatable, Sendable {
  var serverURL: URL
  var room: String
  var displayName: String

  static let defaultServerURL = URL(string: "https://meet.jit.si")!

  var normalizedRoom: String {
    room.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The address other people join with — the same URL the web client uses.
  var meetingLink: URL {
    serverURL.appending(path: normalizedRoom)
  }
}
