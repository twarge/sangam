import Foundation

enum BroadcastNotification: String {
  case started = "iOS_BroadcastStarted"
  case stopped = "iOS_BroadcastStopped"
}

final class DarwinNotificationCenter: @unchecked Sendable {
  static let shared = DarwinNotificationCenter()

  private let center = CFNotificationCenterGetDarwinNotifyCenter()

  func post(_ notification: BroadcastNotification) {
    CFNotificationCenterPostNotification(
      center,
      CFNotificationName(notification.rawValue as CFString),
      nil,
      nil,
      true
    )
  }
}
