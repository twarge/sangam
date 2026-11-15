import Foundation
import Testing

@testable import JitsiConference

/// What a clustered deployment's front end demands of a join before the
/// meeting itself is ever asked. meet.jit.si answers a conference request
/// that names no room with a bare HTTP 400, and refuses a guest whose
/// nickname is not cut from its own address with "Invalid anonymous user ID".
@Suite
struct BootstrapRoutingTests {
  @Test
  func conferenceRequestNamesTheRoomItIsFor() {
    let url = NativeConferenceBootstrap.conferenceRequestURL(
      URL(string: "https://meet.example.test/conference-request/v1")!, room: "standup")
    #expect(url.absoluteString == "https://meet.example.test/conference-request/v1?room=standup")
  }

  @Test
  func routingRoomIsLowercasedLikeTheWebClients() {
    // The front end routes on this name; a room typed in another case has to
    // land on the shard its other participants are on.
    #expect(NativeConferenceBootstrap.routingRoom("SangamTestRoom") == "sangamtestroom")
    // Compatibility-normalized first, as the web client's NFKC pass does.
    #expect(NativeConferenceBootstrap.routingRoom("Ｃａｆé") == "café")
  }

  @Test
  func conferenceRequestKeepsARoomTheDeploymentAlreadyNamed() {
    let url = NativeConferenceBootstrap.conferenceRequestURL(
      URL(string: "https://meet.example.test/conference-request/v1?room=pinned&x=1")!,
      room: "standup")
    #expect(
      url.absoluteString == "https://meet.example.test/conference-request/v1?room=pinned&x=1")
  }

  @Test
  func guestEndpointIDIsCutFromTheBoundAddress() {
    let id = NativeConferenceBootstrap.endpointID(
      boundJID: "9982E490-8acd-4f08-bd2f-b345d6abcf19@guest.meet.example.test/6fe0e3cc",
      hasCredentials: false)
    #expect(id == "9982e490")
  }

  @Test
  func guestWithoutAUUIDAddressGetsARandomEndpointID() {
    for jid in ["anonymous@guest.example.test/abc", "guest.example.test", "abc@example.test"] {
      let id = NativeConferenceBootstrap.endpointID(boundJID: jid, hasCredentials: false)
      #expect(Self.isBareHex(id), "\(jid) produced \(id)")
    }
  }

  @Test
  func accountEndpointIDIgnoresTheUsername() {
    // A username that happens to look like hex says nothing about the
    // endpoint, and two devices signed in to one account must not collide.
    let jid = "deadbeef01@meet.example.test/a1b2c3d4"
    let first = NativeConferenceBootstrap.endpointID(boundJID: jid, hasCredentials: true)
    let second = NativeConferenceBootstrap.endpointID(boundJID: jid, hasCredentials: true)
    #expect(Self.isBareHex(first))
    #expect(first != second)
  }

  /// Eight lowercase hex characters and no dash: web clients split a source
  /// name on its first dash to find the endpoint that owns it.
  private static func isBareHex(_ id: String) -> Bool {
    id.count == 8 && id.allSatisfy { "0123456789abcdef".contains($0) }
  }
}
