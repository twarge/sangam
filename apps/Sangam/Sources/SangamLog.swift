import Foundation

enum SangamLog {
  nonisolated static let isEnabled =
    ProcessInfo.processInfo.environment["SANGAM_LOG"].map { !$0.isEmpty && $0 != "0" } ?? false

  nonisolated static func event(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    FileHandle.standardError.write(Data("[sangam \(timestamp())] \(message())\n".utf8))
  }

  nonisolated private static func timestamp() -> String {
    let now = Calendar.current.dateComponents(
      [.hour, .minute, .second, .nanosecond], from: Date())
    return String(
      format: "%02d:%02d:%02d.%03d",
      now.hour ?? 0, now.minute ?? 0, now.second ?? 0, (now.nanosecond ?? 0) / 1_000_000)
  }
}
