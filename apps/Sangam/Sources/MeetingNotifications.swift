import Foundation
import UserNotifications

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Local notifications for meeting events the user would otherwise miss —
/// posted only while the app is not frontmost, since in-app UI covers the
/// rest.
@MainActor
enum MeetingNotifications {
  private static var authorizationRequested = false

  /// Asks once, lazily — the first meeting join is the natural moment.
  static func prepare() {
    guard !authorizationRequested else { return }
    authorizationRequested = true
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound]
    ) { _, _ in }
  }

  static func post(title: String, body: String, id: String) {
    guard !isAppActive else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: id, content: content, trigger: nil)
    )
  }

  private static var isAppActive: Bool {
    #if os(macOS)
      NSApplication.shared.isActive
    #else
      UIApplication.shared.applicationState == .active
    #endif
  }
}
