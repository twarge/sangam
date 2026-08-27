import Foundation

struct MeetingConfiguration: Equatable, Hashable, Sendable {
  var serverURL: URL
  var room: String
  var displayName: String
  /// A JWT for token-auth deployments (meet.jit.si's SSO, JaaS); rides in
  /// from a `?jwt=` meeting link.
  var token: String? = nil

  static let defaultServerURL = URL(string: "https://meet.jit.si")!

  var normalizedRoom: String {
    room.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The address other people join with — the same URL the web client uses.
  var meetingLink: URL {
    serverURL.appending(path: normalizedRoom)
  }
}
