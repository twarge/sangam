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
  // No meeting can be on screen on visionOS until WebRTC ships for it.
  #if !os(visionOS)
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
  #endif

  /// Meetings joined lately, newest first: the join form's Recent list, and
  /// the rooms Siri and Spotlight suggest.
  @Published private(set) var recentMeetings: [RecentMeeting]

  /// The recent rooms by name alone, for Siri — one entry per name even when
  /// it was joined on more than one server.
  var recentRooms: [String] {
    var seen = Set<String>()
    return recentMeetings.map(\.room).filter { seen.insert($0.lowercased()).inserted }
  }

  private static let recentMeetingsKey = "recentMeetings"
  private static let recentMeetingsLimit = 8

  private init() {
    // The list before this one ("recentRooms") held room names without
    // their servers, so it starts over rather than guessing them.
    recentMeetings = Self.storedRecentMeetings()
  }

  private static func storedRecentMeetings() -> [RecentMeeting] {
    UserDefaults.standard.data(forKey: recentMeetingsKey).flatMap(decodedRecentMeetings) ?? []
  }

  /// The list a stored value holds, or nil when this build can't read it.
  static func decodedRecentMeetings(_ data: Data) -> [RecentMeeting]? {
    try? JSONDecoder().decode([RecentMeeting].self, from: data)
  }

  /// This device's stored list and another's as one, for the first time they
  /// meet: entries alternate, this device's first, so that each keeps its
  /// most recent.
  static func mergedRecentMeetings(_ local: Data, _ remote: Data) -> Data {
    let lists = [local, remote].map { decodedRecentMeetings($0) ?? [] }
    var seen = Set<String>()
    var merged: [RecentMeeting] = []
    for index in 0..<(lists.map(\.count).max() ?? 0) {
      for list in lists where index < list.count {
        if seen.insert(list[index].id).inserted { merged.append(list[index]) }
      }
    }
    merged = Array(merged.prefix(recentMeetingsLimit))
    guard merged != lists[1], let data = try? JSONEncoder().encode(merged) else { return remote }
    return data
  }

  /// Takes up the list `SettingsSync` has just written to UserDefaults from
  /// another device.
  func reloadRecentMeetings() {
    let stored = Self.storedRecentMeetings()
    guard stored != recentMeetings else { return }
    // A meeting forgotten on another device takes its saved password with it
    // here as well. One only pushed off the end of a full list keeps its
    // password, as it does when that happens on this device.
    let kept = Set(stored.map(\.id))
    let lastKept = recentMeetings.lastIndex { kept.contains($0.id) } ?? -1
    for (index, meeting) in recentMeetings.enumerated() where !kept.contains(meeting.id) {
      guard stored.count < Self.recentMeetingsLimit || index < lastKept,
        let server = meeting.serverURL
      else { continue }
      SavedCredentials.forgetMeetingPassword(server: server, room: meeting.room)
    }
    recentMeetings = stored
  }

  #if !os(visionOS)
    func noteMeetingStarted(_ configuration: MeetingConfiguration, controller: MeetingController) {
      // Deferred: the callers are view-lifecycle hooks, and publishing from
      // inside a view update feeds SwiftUI's graph re-entrantly.
      Task { @MainActor in
        self.activeConfiguration = configuration
        self.activeController = controller
        MeetingNotifications.prepare()
      }
    }
  #endif

  /// Puts a meeting at the top of the recents once it has actually been
  /// joined, so a mistyped room never makes the list.
  func noteMeetingJoined(_ configuration: MeetingConfiguration) {
    let meeting = RecentMeeting(
      server: configuration.serverURL.absoluteString, room: configuration.normalizedRoom)
    var recents = recentMeetings.filter { $0.id != meeting.id }
    recents.insert(meeting, at: 0)
    storeRecentMeetings(Array(recents.prefix(Self.recentMeetingsLimit)))
  }

  /// Drops a meeting from the recents, and the password saved for it.
  func forgetRecentMeeting(_ meeting: RecentMeeting) {
    if let server = meeting.serverURL {
      SavedCredentials.forgetMeetingPassword(server: server, room: meeting.room)
    }
    storeRecentMeetings(recentMeetings.filter { $0.id != meeting.id })
  }

  private func storeRecentMeetings(_ meetings: [RecentMeeting]) {
    recentMeetings = meetings
    if let data = try? JSONEncoder().encode(meetings) {
      UserDefaults.standard.set(data, forKey: Self.recentMeetingsKey)
    }
    UserDefaults.standard.removeObject(forKey: "recentRooms")
  }

  /// Clears the active meeting — but only if `controller` still is it:
  /// when a room switch replaces the meeting view, the old view's
  /// disappearance can arrive after the new one's appearance.
  #if !os(visionOS)
    func noteMeetingEnded(controller: MeetingController) {
      Task { @MainActor in
        guard self.activeController === controller else { return }
        self.activeConfiguration = nil
        self.activeController = nil
      }
    }
  #endif

  /// Joins a room by name: on the server it was last joined on, or else on
  /// the user's configured server.
  func requestJoin(room: String) {
    let normalized = room.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    let recent = recentMeetings.first {
      $0.room.caseInsensitiveCompare(normalized) == .orderedSame
    }
    let stored = UserDefaults.standard.string(forKey: "serverURL")
    let server =
      recent?.serverURL
      ?? stored.flatMap(MeetingConfiguration.serverURL(from:))
      ?? MeetingConfiguration.defaultServerURL
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

/// A meeting joined before: where it was and what it was called, enough to
/// join it again in one click.
struct RecentMeeting: Codable, Hashable, Identifiable, Sendable {
  /// The server address as it was joined.
  var server: String
  var room: String

  /// One entry per meeting, however the server was typed or the room cased.
  var id: String {
    serverURL.map { SavedCredentials.roomKey(server: $0, room: room) }
      ?? "\(server)/\(room.lowercased())"
  }

  var serverURL: URL? { MeetingConfiguration.serverURL(from: server) }

  /// The server as the list shows it.
  var serverName: String { serverURL.map(SavedCredentials.displayHost) ?? server }
}
