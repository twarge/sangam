import Foundation

/// Minimal JID slicing for the few places the client needs to compare room
/// and occupant addresses. Jitsi never sends escaped or internationalised
/// JIDs to clients, so no stringprep is attempted.
public enum XMPPJID {
  /// `room@conference.example.test/nick` -> `room@conference.example.test`.
  public static func bare(_ jid: String) -> String {
    guard let slash = jid.firstIndex(of: "/") else { return jid }
    return String(jid[..<slash])
  }

  /// `room@conference.example.test/nick` -> `nick`; `nil` without a resource.
  public static func resource(_ jid: String) -> String? {
    guard let slash = jid.firstIndex(of: "/"), slash < jid.index(before: jid.endIndex) else {
      return nil
    }
    return String(jid[jid.index(after: slash)...])
  }

  /// JIDs are case-insensitive in their domain part, and Prosody lowercases
  /// room names, so address comparisons must not be exact.
  public static func matches(_ lhs: String, _ rhs: String) -> Bool {
    lhs.lowercased() == rhs.lowercased()
  }
}
