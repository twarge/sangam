import Testing

@testable import JitsiXMPP

@Test
func buildsAndParsesFocusAllocation() throws {
  let request = FocusConferenceRequest(
    id: "focus-1",
    focusJID: "focus.meet.example.test",
    roomJID: "room@conference.meet.example.test",
    machineUID: "device-123",
    token: "jwt-value",
    properties: ["visitors-version": "1", "startBitrate": "800"]
  )
  let xml = XMPPWriter.serialize(request.element())
  let parsedRequest = try XMPPParser().parse(xml)
  let conference = try #require(
    parsedRequest.child(named: "conference", namespace: FocusConferenceResponse.namespace)
  )
  #expect(parsedRequest[attribute: "to"] == "focus.meet.example.test")
  #expect(conference[attribute: "room"] == "room@conference.meet.example.test")
  #expect(conference[attribute: "token"] == "jwt-value")
  #expect(
    conference.children(named: "property", namespace: FocusConferenceResponse.namespace).count == 2)

  let responseElement = try XMPPParser().parse(
    """
    <iq id="focus-1" type="result">
      <conference xmlns="http://jitsi.org/protocol/focus" ready="true" focusjid="focus@auth.meet.example.test/focus" session-id="session-9">
        <property name="authentication" value="false"/>
      </conference>
    </iq>
    """
  )
  let response = try FocusConferenceResponse(element: responseElement)
  #expect(response.ready)
  #expect(response.sessionID == "session-9")
  #expect(response.properties["authentication"] == "false")
}

@Test
func buildsInitialPresenceWithNativeSources() throws {
  let presence = InitialMUCPresence(
    roomJID: "room@conference.meet.example.test",
    nickname: "native-1",
    displayName: "Native User",
    audioMuted: false,
    videoMuted: false,
    sources: [
      "native-1-a0": LocalSourcePresence(muted: false),
      "native-1-v0": LocalSourcePresence(muted: false, videoType: "camera"),
      "native-1-v1": LocalSourcePresence(muted: false, videoType: "desktop"),
    ]
  )
  let element = try presence.element()
  let reparsed = try XMPPParser().parse(XMPPWriter.serialize(element))

  #expect(reparsed[attribute: "to"] == "room@conference.meet.example.test/native-1")
  #expect(reparsed.child(named: "x", namespace: "http://jabber.org/protocol/muc") != nil)
  #expect(
    reparsed.child(named: "nick", namespace: "http://jabber.org/protocol/nick")?.text
      == "Native User")
  #expect(reparsed.child(named: "SourceInfo")?.text.contains("native-1-v1") == true)
  #expect(reparsed.child(named: "SourceInfo")?.text.contains("desktop") == true)
}

@Test
func buildsSourceInfoPresenceUpdateForRetainedDesktopSender() throws {
  let update = SourceInfoPresenceUpdate(
    occupantJID: "room@conference.meet.example.test/native-1",
    audioMuted: true,
    videoMuted: false,
    sources: [
      "native-1-a0": LocalSourcePresence(muted: true),
      "native-1-v0": LocalSourcePresence(muted: false),
      "native-1-v1": LocalSourcePresence(muted: true, videoType: "desktop"),
    ]
  )
  let reparsed = try XMPPParser().parse(XMPPWriter.serialize(update.element()))

  #expect(reparsed[attribute: "to"] == "room@conference.meet.example.test/native-1")
  #expect(reparsed.child(named: "audiomuted")?.text == "true")
  #expect(reparsed.child(named: "videomuted")?.text == "false")
  #expect(reparsed.child(named: "SourceInfo")?.text.contains("native-1-v1") == true)
  #expect(reparsed.child(named: "SourceInfo")?.text.contains("desktop") == true)
}

@Test
func parsesParticipantRoleAndOwnedSources() throws {
  let element = try XMPPParser().parse(
    """
    <presence from="room@conference.meet.example.test/remote-8">
      <nick xmlns="http://jabber.org/protocol/nick">Remote User</nick>
      <audiomuted>false</audiomuted>
      <videomuted>true</videomuted>
      <SourceInfo>{"remote-8-a0":{"muted":false},"remote-8-v0":{"muted":true},"remote-8-v1":{"muted":false,"videoType":"desktop"},"someone-else-v0":{"muted":false}}</SourceInfo>
      <x xmlns="http://jabber.org/protocol/muc#user">
        <item affiliation="owner" role="moderator"/>
      </x>
    </presence>
    """
  )
  let participant = try MUCParticipantPresence(element: element)

  #expect(participant.endpointID == "remote-8")
  #expect(participant.displayName == "Remote User")
  #expect(participant.role == "moderator")
  #expect(participant.affiliation == "owner")
  #expect(participant.audioMuted == false)
  #expect(participant.videoMuted == true)
  #expect(participant.sources.count == 3)
  #expect(participant.sources.first(where: { $0.name == "remote-8-v1" })?.videoType == "desktop")
  #expect(!participant.sources.contains(where: { $0.name == "someone-else-v0" }))
}

@Test
func rejectsOversizedSourceInfo() throws {
  let element = try XMPPParser().parse(
    """
    <presence from="room@conference.meet.example.test/remote">
      <SourceInfo>{"remote-v0":{"muted":false}}</SourceInfo>
    </presence>
    """
  )
  #expect(throws: MUCPresenceError.sourceInfoTooLarge(limit: 8)) {
    try MUCParticipantPresence(element: element, maximumSourceInfoBytes: 8)
  }
}
