import Foundation
import Security

/// Sign-ins and meeting passwords that worked before, kept in the Keychain
/// so the next join tries them before asking. An admin sign-in belongs to a
/// server — any room on it — and a meeting password to one room on one
/// server. Nothing here leaves the device: the items are not synchronized.
enum SavedCredentials {
  struct AdminSignIn: Codable, Equatable {
    var username: String
    var password: String
  }

  // MARK: Admin sign-in, per server

  static func adminSignIn(for server: URL) -> AdminSignIn? {
    read(service: adminService, account: serverKey(server))
      .flatMap { try? JSONDecoder().decode(AdminSignIn.self, from: $0) }
  }

  static func hasAdminSignIn(for server: URL) -> Bool {
    exists(service: adminService, account: serverKey(server))
  }

  static func saveAdminSignIn(_ signIn: AdminSignIn, for server: URL) {
    guard let data = try? JSONEncoder().encode(signIn) else { return }
    write(
      data, service: adminService, account: serverKey(server),
      label: "Sangam sign-in for \(displayHost(server))")
  }

  static func forgetAdminSignIn(for server: URL) {
    delete(service: adminService, account: serverKey(server))
  }

  // MARK: Meeting password, per room

  static func meetingPassword(server: URL, room: String) -> String? {
    read(service: meetingPasswordService, account: roomKey(server: server, room: room))
      .flatMap { String(data: $0, encoding: .utf8) }
  }

  static func hasMeetingPassword(server: URL, room: String) -> Bool {
    exists(service: meetingPasswordService, account: roomKey(server: server, room: room))
  }

  static func saveMeetingPassword(_ password: String, server: URL, room: String) {
    write(
      Data(password.utf8), service: meetingPasswordService,
      account: roomKey(server: server, room: room),
      label: "Sangam meeting password for \(room) on \(displayHost(server))")
  }

  static func forgetMeetingPassword(server: URL, room: String) {
    delete(service: meetingPasswordService, account: roomKey(server: server, room: room))
  }

  // MARK: Keys

  private static let adminService = "com.twarge.sangam.admin-sign-in"
  private static let meetingPasswordService = "com.twarge.sangam.meeting-password"

  /// One deployment, however its address was typed: scheme, host and port,
  /// lowercased, without the path or a trailing slash.
  static func serverKey(_ server: URL) -> String {
    let scheme = server.scheme?.lowercased() ?? "https"
    let host = server.host()?.lowercased() ?? server.absoluteString.lowercased()
    let port = server.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }

  /// XMPP folds a room name's case, so `Standup` and `standup` are the same
  /// meeting — and the same password.
  static func roomKey(server: URL, room: String) -> String {
    let room = room.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(serverKey(server))/\(room)"
  }

  /// The server as a person would name it: its host, and a port only when it
  /// isn't the default.
  static func displayHost(_ server: URL) -> String {
    let host = server.host() ?? server.absoluteString
    return server.port.map { "\(host):\($0)" } ?? host
  }

  // MARK: Keychain

  #if os(macOS)
    /// The iOS-style keychain — scoped to the app, never a prompt — needs an
    /// application identifier, which only a provisioning profile grants. A
    /// build signed without one keeps its items in the login keychain. This
    /// is decided from the entitlements rather than from a failed call: the
    /// app-scoped keychain answers a read it cannot serve with "not found".
    private static let usesDataProtectionKeychain: Bool = {
      guard let task = SecTaskCreateFromSelf(nil) else { return false }
      return ["com.apple.application-identifier", "keychain-access-groups"].contains {
        SecTaskCopyValueForEntitlement(task, $0 as CFString, nil) != nil
      }
    }()
  #endif

  private static func baseQuery(service: String, account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    #if os(macOS)
      if usesDataProtectionKeychain {
        query[kSecUseDataProtectionKeychain as String] = true
      }
    #endif
    return query
  }

  private static func read(service: String, account: String) -> Data? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      if status != errSecItemNotFound {
        SangamLog.event("keychain: read \(service) failed \(status)")
      }
      return nil
    }
    return result as? Data
  }

  private static func exists(service: String, account: String) -> Bool {
    var query = baseQuery(service: service, account: account)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  private static func write(_ data: Data, service: String, account: String, label: String) {
    let query = baseQuery(service: service, account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrLabel as String: label,
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query.merging(attributes) { $1 }
      if dataProtected {
        // Readable once the device has been unlocked since boot, so a join
        // started from a locked screen (Siri, a widget) still finds it.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      }
      status = SecItemAdd(item as CFDictionary, nil)
    }
    if status != errSecSuccess {
      SangamLog.event("keychain: write \(service) failed \(status)")
    }
  }

  private static func delete(service: String, account: String) {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    if status != errSecSuccess, status != errSecItemNotFound {
      SangamLog.event("keychain: delete \(service) failed \(status)")
    }
  }

  /// Whether items land in a keychain that honors accessibility classes —
  /// always on iOS; on the Mac, only the app-scoped one.
  private static var dataProtected: Bool {
    #if os(macOS)
      usesDataProtectionKeychain
    #else
      true
    #endif
  }
}
