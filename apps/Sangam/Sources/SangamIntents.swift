import AppIntents

/// A meeting room, suggested from recently joined ones — what Siri,
/// Spotlight, and Shortcuts offer when asking which meeting to join.
struct MeetingRoomEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Meeting Room")
  static let defaultQuery = MeetingRoomQuery()

  let id: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(id)")
  }
}

struct MeetingRoomQuery: EntityQuery {
  @MainActor
  func entities(for identifiers: [String]) async throws -> [MeetingRoomEntity] {
    identifiers.map(MeetingRoomEntity.init(id:))
  }

  @MainActor
  func suggestedEntities() async throws -> [MeetingRoomEntity] {
    MeetingHub.shared.recentRooms.map(MeetingRoomEntity.init(id:))
  }
}

struct NoActiveMeetingError: Error, CustomLocalizedStringResourceConvertible {
  var localizedStringResource: LocalizedStringResource {
    "There is no meeting going on right now."
  }
}

struct JoinMeetingIntent: AppIntent {
  static let title: LocalizedStringResource = "Join Meeting"
  static let description = IntentDescription(
    "Joins a meeting room on your conference server.")
  static let openAppWhenRun = true

  @Parameter(title: "Room") var room: MeetingRoomEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    MeetingHub.shared.requestJoin(room: room.id)
    return .result()
  }
}

struct ToggleMuteIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle Mute"
  static let description = IntentDescription(
    "Mutes or unmutes your microphone in the current meeting.")

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let controller = MeetingHub.shared.activeController else {
      throw NoActiveMeetingError()
    }
    controller.toggleAudio()
    return .result()
  }
}

struct LeaveMeetingIntent: AppIntent {
  static let title: LocalizedStringResource = "Leave Meeting"
  static let description = IntentDescription("Leaves the current meeting.")

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let controller = MeetingHub.shared.activeController else {
      throw NoActiveMeetingError()
    }
    controller.hangUp()
    return .result()
  }
}

struct SangamAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: JoinMeetingIntent(),
      phrases: [
        "Join a meeting in \(.applicationName)",
        "Join \(\.$room) in \(.applicationName)",
      ],
      shortTitle: "Join Meeting",
      systemImageName: "video.fill"
    )
    AppShortcut(
      intent: ToggleMuteIntent(),
      phrases: ["Toggle mute in \(.applicationName)"],
      shortTitle: "Toggle Mute",
      systemImageName: "mic.slash.fill"
    )
    AppShortcut(
      intent: LeaveMeetingIntent(),
      phrases: ["Leave the \(.applicationName) meeting"],
      shortTitle: "Leave Meeting",
      systemImageName: "phone.down.fill"
    )
  }
}
