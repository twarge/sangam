import Foundation
import Testing

@testable import JitsiConference

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
  print("PROBE joining \(base) room=\(room)")
  do {
    let handle = try await NativeConferenceBootstrap().connect(
      NativeConferenceJoinOptions(
        serverURL: base,
        room: room,
        displayName: "Sangam Probe",
        startCamera: false
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
