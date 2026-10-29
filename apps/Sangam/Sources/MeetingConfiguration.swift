import Foundation

struct MeetingConfiguration: Equatable, Hashable, Sendable {
  var serverURL: URL
  var room: String
  var displayName: String
  /// A JWT for token-auth deployments (meet.jit.si's SSO, JaaS); rides in
  /// from a `?jwt=` meeting link.
  var token: String? = nil

  static let defaultServerURL = URL(string: "https://meet.jit.si")!

  /// The server field's text as a server URL, or nil when it can't be one.
  /// A bare host (`meet.example.com`, `meet.example.com:8443`) means HTTPS
  /// and surrounding whitespace is ignored; plain HTTP is only for localhost.
  static func serverURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard
      let url = URL(string: candidate),
      let scheme = url.scheme?.lowercased(),
      let host = url.host, !host.isEmpty,
      scheme == "https" || (scheme == "http" && host == "localhost")
    else { return nil }
    return url
  }

  var normalizedRoom: String {
    room.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The address other people join with — the same URL the web client uses.
  var meetingLink: URL {
    serverURL.appending(path: normalizedRoom)
  }
}
