import Foundation
import Testing

@testable import JitsiConference

/// Reproduces the app's password retry against a live lobby+password room:
/// join without a password, get parked in the lobby, cancel (the app does
/// this when the user types the meeting password), then join again with
/// the password — the sequence the pre-join form drives.
///
///     SANGAM_LIVE_PROBE=... SANGAM_LIVE_PROBE_ROOM=... \
///     SANGAM_LIVE_PROBE_MEETING_PASSWORD=... \
///     swift test --filter livePasswordRetryProbe
@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["SANGAM_LIVE_PROBE"] != nil
      && ProcessInfo.processInfo.environment["SANGAM_LIVE_PROBE_MEETING_PASSWORD"] != nil),
  .timeLimit(.minutes(2))
)
func livePasswordRetryProbe() async throws {
  let environment = ProcessInfo.processInfo.environment
  let base = try #require(environment["SANGAM_LIVE_PROBE"].flatMap(URL.init(string:)))
  let room = try #require(environment["SANGAM_LIVE_PROBE_ROOM"])
  let password = try #require(environment["SANGAM_LIVE_PROBE_MEETING_PASSWORD"])

  let reachedLobby = AsyncStream<Void>.makeStream()
  let first = Task {
    _ = try await NativeConferenceBootstrap().connect(
      NativeConferenceJoinOptions(
        serverURL: base, room: room, displayName: "Retry Probe", startCamera: false),
      progress: { progress in
        print("RETRY first join progress: \(progress)")
        if case .waitingInLobby = progress { reachedLobby.continuation.yield() }
      }
    )
  }
  var lobbyEvents = reachedLobby.stream.makeAsyncIterator()
  _ = await lobbyEvents.next()
  print("RETRY in lobby — cancelling first join, retrying with password")
  first.cancel()
  do {
    let handle = try await NativeConferenceBootstrap().connect(
      NativeConferenceJoinOptions(
        serverURL: base, room: room, displayName: "Retry Probe", startCamera: false,
        meetingPassword: password),
      progress: { progress in print("RETRY second join progress: \(progress)") }
    )
    print("RETRY joined as \(handle.occupantJID)")
    await handle.coordinator.stop()
  } catch {
    print("RETRY second join FAILED: \(String(reflecting: error))")
    throw error
  }
}

/// A live join against a real deployment, for diagnosing by hand — never
/// runs in CI:
///
///     SANGAM_LIVE_PROBE=https://meet.jit.si swift test --filter liveJoinProbe
@Test(
  .enabled(if: ProcessInfo.processInfo.environment["SANGAM_LIVE_PROBE"] != nil),
  .timeLimit(.minutes(2))
)
func liveJoinProbe() async throws {
  let base = try #require(
    ProcessInfo.processInfo.environment["SANGAM_LIVE_PROBE"].flatMap(URL.init(string:)))
  let room =
    ProcessInfo.processInfo.environment["SANGAM_LIVE_PROBE_ROOM"]
    ?? "sangam-probe-\(UUID().uuidString.prefix(8).lowercased())"
  let meetingPassword = ProcessInfo.processInfo.environment["SANGAM_LIVE_PROBE_MEETING_PASSWORD"]
  print("PROBE joining \(base) room=\(room) password=\(meetingPassword != nil)")
  do {
    let handle = try await NativeConferenceBootstrap().connect(
      NativeConferenceJoinOptions(
        serverURL: base,
        room: room,
        displayName: "Sangam Probe",
        startCamera: false,
        meetingPassword: meetingPassword
      ),
      progress: { progress in print("PROBE progress: \(progress)") }
    )
    print("PROBE joined as \(handle.occupantJID)")
    let watcher = Task {
      for await event in handle.coordinator.events {
        switch event {
        case .diagnostic(let message): print("PROBE diag: \(message)")
        case .warning(let message): print("PROBE warn: \(message)")
        case .failed(let reason): print("PROBE failed event: \(reason)")
        case .remoteVideoTrackAdded(let stream):
          print("PROBE track added: \(stream.id) source=\(stream.sourceName ?? "?")")
        case .participantsChanged(let participants):
          print("PROBE participants: \(participants.map(\.displayName))")
        default: break
        }
      }
    }
    for _ in 0..<8 {
      try? await Task.sleep(for: .seconds(4))
      print("PROBE stats: \(await handle.coordinator.mediaStatsSummary())")
    }
    watcher.cancel()
    await handle.coordinator.stop()
  } catch {
    print("PROBE failed: \(String(reflecting: error))")
    throw error
  }
}
