import Foundation
import SwiftUI

/// The rendezvous point between the meeting UI and every system surface —
/// links and Handoff, Siri intents, the menu bar extra, CallKit. It knows
/// which meeting is on screen, remembers recent rooms for suggestions, and
/// carries join requests that arrive from outside the join form.
@MainActor
final class MeetingHub: ObservableObject {
  static let shared = MeetingHub()

  /// The Handoff activity type advertised while in a meeting; also listed
  /// in both Info.plists.
  static let meetingActivityType = "com.twarge.sangam.meeting"

  /// A join asked for from outside the join form (a link, Handoff, Siri).
  /// RootView consumes it — replacing any meeting already on screen.
  @Published var pendingJoin: MeetingConfiguration?

  /// The meeting currently on screen, for system surfaces to act on.
  @Published private(set) var activeConfiguration: MeetingConfiguration?
  @Published private(set) var activeController: MeetingController?
  /// The live meeting model, for feed windows to resolve streams from.
  @Published private(set) var activeModel: NativeMeetingModel?

  func registerModel(_ model: NativeMeetingModel) {
    Task { @MainActor in self.activeModel = model }
  }

  func unregisterModel(_ model: NativeMeetingModel) {
    Task { @MainActor in
      guard self.activeModel === model else { return }
      self.activeModel = nil
    }
  }

  /// Rooms joined lately, newest first, for Siri and Spotlight suggestions.
  @Published private(set) var recentRooms: [String]

  private init() {
    recentRooms = UserDefaults.standard.stringArray(forKey: "recentRooms") ?? []
  }

  func noteMeetingStarted(_ configuration: MeetingConfiguration, controller: MeetingController) {
    // Deferred: the callers are view-lifecycle hooks, and publishing from
    // inside a view update feeds SwiftUI's graph re-entrantly.
    Task { @MainActor in
      self.activeConfiguration = configuration
      self.activeController = controller
      MeetingNotifications.prepare()
      var recents = self.recentRooms.filter {
        $0.caseInsensitiveCompare(configuration.normalizedRoom) != .orderedSame
      }
      recents.insert(configuration.normalizedRoom, at: 0)
      self.recentRooms = Array(recents.prefix(8))
      UserDefaults.standard.set(self.recentRooms, forKey: "recentRooms")
    }
  }

  /// Clears the active meeting — but only if `controller` still is it:
  /// when a room switch replaces the meeting view, the old view's
  /// disappearance can arrive after the new one's appearance.
  func noteMeetingEnded(controller: MeetingController) {
    Task { @MainActor in
      guard self.activeController === controller else { return }
      self.activeConfiguration = nil
      self.activeController = nil
    }
  }

  /// Joins a room by name on the user's configured server.
  func requestJoin(room: String) {
    let normalized = room.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    let stored = UserDefaults.standard.string(forKey: "serverURL")
    let server =
      stored.flatMap(URL.init(string:)) ?? MeetingConfiguration.defaultServerURL
    pendingJoin = MeetingConfiguration(
      serverURL: server,
      room: normalized,
      displayName: UserDefaults.standard.string(forKey: "displayName") ?? ""
    )
  }

  /// Turns a meeting link into a join: `https://server/room` (a universal
  /// link or Handoff URL) or `sangam://server/room`. Returns whether the
  /// URL was one.
  @discardableResult
  func requestJoin(url: URL) -> Bool {
    guard let configuration = Self.configuration(from: url) else { return false }
    pendingJoin = configuration
    return true
  }

  static func configuration(from url: URL) -> MeetingConfiguration? {
    guard let host = url.host, !host.isEmpty else { return nil }
    let scheme = url.scheme?.lowercased()
    guard scheme == "https" || scheme == "http" || scheme == "sangam" else { return nil }

    // The room is the single path component; anything deeper is not a
    // meeting link.
    let components = url.path.split(separator: "/").map(String.init)
    guard components.count == 1, let room = components.first, !room.isEmpty,
      !room.contains("@")
    else { return nil }

    var server = URLComponents()
    server.scheme = scheme == "http" ? "http" : "https"
    server.host = host
    server.port = url.port
    guard let serverURL = server.url else { return nil }
    // Token-auth deployments hand out links with the JWT in the query —
    // the same ?jwt= the web client honors.
    let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "jwt" }?.value
    return MeetingConfiguration(
      serverURL: serverURL,
      room: room,
      displayName: UserDefaults.standard.string(forKey: "displayName") ?? "",
      token: token.flatMap { $0.isEmpty ? nil : $0 }
    )
  }
}
