import Foundation

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Carries the user's preferences between their devices through iCloud's
/// key-value store.
///
/// Settings stay in `UserDefaults`, where `@AppStorage`, `AppSettings` and
/// `MeetingHub` read them; this only copies a fixed list of keys in both
/// directions. What describes one device or one sitting rather than the
/// person stays put: the layout (`sidebarWidth`, `panelsPushStage`), the
/// incoming video quality (a matter of that device's screen and network),
/// the server and room last typed into the join form (a pair: one device's
/// server beside another's room names a meeting nobody meant, and the recent
/// meetings carry both across anyway), and background blur (a change made
/// elsewhere must never uncover the room behind a call in progress).
/// Passwords and sign-ins are in the Keychain and never pass through here.
@MainActor
final class SettingsSync {
  static let shared = SettingsSync()

  private static let recentsKey = "recentMeetings"

  static let syncedKeys: [String] = [
    "displayName",
    // At most eight server-and-room pairs, as JSON: a few hundred bytes.
    recentsKey,
    "transcribeOnJoin",
    "showsCaptions",
  ]

  /// Set once this device's recent meetings have met the cloud's. Stays on
  /// the device.
  private static let mergedRecentsKey = "settingsSyncMergedRecents"

  /// What this device held, when the iCloud account changed, for keys the new
  /// account had nothing for. It was set under the account before, so it is
  /// not uploaded into this one until it is changed here. Stays on the device.
  private static let withheldKey = "settingsSyncWithheld"

  private let defaults = UserDefaults.standard
  private let store = NSUbiquitousKeyValueStore.default
  private var observers: [NSObjectProtocol] = []
  private var pendingPush: Task<Void, Never>?

  private init() {}

  /// Begins syncing. Without the iCloud entitlement, or signed out of
  /// iCloud, the store simply never reports or accepts anything.
  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
        object: store,
        queue: .main
      ) { [weak self] notification in
        let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        MainActor.assumeIsolated {
          if reason == NSUbiquitousKeyValueStoreAccountChange {
            self?.accountChanged()
          } else {
            self?.pull(keys: keys ?? Self.syncedKeys)
          }
        }
      })
    observers.append(
      center.addObserver(
        forName: UserDefaults.didChangeNotification,
        object: defaults,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedulePush() }
      })
    // Leaving the front, or quitting, is the last moment to send a change
    // still waiting out its delay: unsent, the next launch's pull would
    // undo it.
    #if os(macOS)
      let leaving = [
        NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification,
      ]
    #else
      let leaving = [UIApplication.willResignActiveNotification]
    #endif
    for name in leaving {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.pushIfPending() }
        })
    }
    store.synchronize()
    pull(keys: Self.syncedKeys)
    // What was set here before there was a store to send it to. After the
    // pull, that is only the keys the cloud has nothing for.
    push()
  }

  /// Cloud to device, for keys the cloud has a value this build can read.
  private func pull(keys: [String]) {
    var changed = false
    for key in keys where Self.syncedKeys.contains(key) {
      guard var value = store.object(forKey: key) as? NSObject, Self.understands(value, for: key)
      else { continue }
      if key == Self.recentsKey, !defaults.bool(forKey: Self.mergedRecentsKey) {
        // The first time this device's list meets the cloud's, neither
        // replaces the other. From then on the cloud's is the list, so that
        // a meeting forgotten on one device goes from them all.
        defaults.set(true, forKey: Self.mergedRecentsKey)
        if let local = defaults.data(forKey: key), let remote = value as? Data {
          value = MeetingHub.mergedRecentMeetings(local, remote) as NSData
        }
      }
      guard (defaults.object(forKey: key) as? NSObject) != value else { continue }
      defaults.set(value, forKey: key)
      changed = true
    }
    // `@AppStorage` follows UserDefaults by itself; these two read it once
    // and keep their own copy.
    guard changed else { return }
    AppSettings.shared.reloadSyncedPreferences()
    MeetingHub.shared.reloadRecentMeetings()
  }

  /// The store now belongs to a different iCloud account. What it holds is
  /// taken up; what it has nothing for was set under the account before, and
  /// stays on this device rather than being uploaded into the new one.
  private func accountChanged() {
    let chosen = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    let withheld = chosen.filter { key, _ in
      Self.syncedKeys.contains(key) && store.object(forKey: key) == nil
    }
    defaults.set(withheld, forKey: Self.withheldKey)
    pull(keys: Self.syncedKeys)
  }

  /// Whether a value in the store is one this build can use. A later build
  /// may sync something this one can't read; that is neither taken, since it
  /// would read as nothing, nor overwritten.
  private static func understands(_ value: NSObject, for key: String) -> Bool {
    switch key {
    case recentsKey: (value as? Data).flatMap(MeetingHub.decodedRecentMeetings) != nil
    case "displayName": value is String
    case "transcribeOnJoin", "showsCaptions": value is Bool
    default: true
    }
  }

  /// Pushes a moment after the last change rather than at once. A text
  /// field writes on every keystroke and a sidebar drag on every frame, and
  /// other devices should get the name, not its first three letters. Nor may
  /// a push run inside `pull`, whose own writes arrive here too: halfway
  /// through, it would send back this device's old values for the keys the
  /// pull had not reached yet.
  private func schedulePush() {
    pendingPush?.cancel()
    pendingPush = Task {
      try? await Task.sleep(for: .seconds(1))
      if !Task.isCancelled { push() }
    }
  }

  private func pushIfPending() {
    if pendingPush != nil { push() }
  }

  /// Device to cloud, for keys the user has actually set. A registered
  /// default is not a choice and must not overwrite one made elsewhere.
  private func push() {
    pendingPush?.cancel()
    pendingPush = nil
    let chosen = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    let withheld = defaults.dictionary(forKey: Self.withheldKey) ?? [:]
    var stillWithheld = withheld
    for key in Self.syncedKeys {
      guard let value = chosen[key] as? NSObject else { continue }
      if (withheld[key] as? NSObject) == value { continue }
      // Changed since the account did: this account's own choice now.
      stillWithheld[key] = nil
      if let stored = store.object(forKey: key) as? NSObject,
        stored == value || !Self.understands(stored, for: key)
      {
        continue
      }
      store.set(value, forKey: key)
    }
    if stillWithheld.count != withheld.count {
      defaults.set(stillWithheld, forKey: Self.withheldKey)
    }
  }
}
