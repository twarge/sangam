import Testing

@testable import JitsiXMPP

/// Wire format of Jitsi's lobby, checked against Prosody's
/// `mod_muc_lobby_rooms` and lib-jitsi-meet's `Lobby`/`ChatRoom`.
@Suite
struct MUCLobbyTests {
  @Test
  func parsesMembersOnlyRefusalWithNestedLobbyAddress() throws {
    // Current module: the address sits inside <error/>, with a legacy copy at
    // the top level that is slated for removal.
    let element = try XMPPParser().parse(
      """
      <presence xmlns="jabber:client" from="room@conference.example.test/me" \
      to="guest@guest.example.test/me" type="error">
        <error type="auth" code="407">
          <registration-required xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>
          <lobbyroom xmlns="http://jitsi.org/jitmeet">room@lobby.example.test</lobbyroom>
        </error>
        <lobbyroom>room@lobby.example.test</lobbyroom>
        <x xmlns="http://jabber.org/protocol/muc"/>
      </presence>
      """
    )
    #expect(
      MUCJoinError(element: element)
        == .membersOnly(lobbyRoomJID: "room@lobby.example.test", waitingForHost: false)
    )
  }

  @Test
  func parsesMembersOnlyRefusalWithLegacyTopLevelAddressAndHostWait() throws {
    let element = try XMPPParser().parse(
      """
      <presence from="room@conference.example.test/me" type="error">
        <error type="auth">
          <registration-required xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>
          <waiting-for-host xmlns="http://jitsi.org/jitmeet"/>
        </error>
        <lobbyroom>room@lobby.example.test</lobbyroom>
      </presence>
      """
    )
    #expect(
      MUCJoinError(element: element)
        == .membersOnly(lobbyRoomJID: "room@lobby.example.test", waitingForHost: true)
    )
  }

  @Test
  func parsesOtherJoinRefusals() throws {
    func refusal(_ body: String) throws -> MUCJoinError? {
      MUCJoinError(
        element: try XMPPParser().parse(
          "<presence from=\"room@conference.example.test/me\" type=\"error\">\(body)</presence>"
        )
      )
    }
    #expect(
      try refusal(
        "<error type=\"auth\"><not-authorized xmlns=\"urn:ietf:params:xml:ns:xmpp-stanzas\"/></error>"
      ) == .passwordRequired
    )
    #expect(
      try refusal(
        "<error type=\"cancel\"><service-unavailable xmlns=\"urn:ietf:params:xml:ns:xmpp-stanzas\"/></error>"
      ) == .roomFull
    )
    #expect(
      try refusal(
        "<error type=\"cancel\"><conflict xmlns=\"urn:ietf:params:xml:ns:xmpp-stanzas\"/></error>"
      ) == .nicknameConflict
    )
    #expect(
      try refusal(
        """
        <error type="modify" code="406">
          <not-acceptable xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>
          <displayname-required xmlns="http://jitsi.org/jitmeet" lobby="true"/>
        </error>
        """
      ) == .displayNameRequired
    )
    #expect(
      try refusal(
        """
        <error type="cancel">
          <not-allowed xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>
          <text xmlns="urn:ietf:params:xml:ns:xmpp-stanzas">Room creation is restricted</text>
        </error>
        """
      ) == .notAllowed(text: "Room creation is restricted")
    )
    #expect(
      try refusal("<error type=\"wait\"><resource-constraint/></error>")
        == .other(condition: "resource-constraint", text: nil)
    )
  }

  @Test
  func ignoresPresenceThatIsNotAnError() throws {
    let element = try XMPPParser().parse(
      """
      <presence from="room@conference.example.test/me">\
      <x xmlns="http://jabber.org/protocol/muc#user"/></presence>
      """
    )
    #expect(MUCJoinError(element: element) == nil)
  }

  @Test
  func parsesWaitingParticipantPresenceAsSeenByModerators() throws {
    let element = try XMPPParser().parse(
      """
      <presence from="room@lobby.example.test/abcd1234" to="host@example.test/host">
        <nick xmlns="http://jabber.org/protocol/nick">Guest One</nick>
        <x xmlns="http://jabber.org/protocol/muc#user">
          <item affiliation="none" role="participant" jid="guest-uuid@guest.example.test/abcd1234"/>
        </x>
      </presence>
      """
    )
    let presence = try MUCParticipantPresence(element: element)
    #expect(presence.roomJID == "room@lobby.example.test")
    #expect(presence.endpointID == "abcd1234")
    #expect(presence.displayName == "Guest One")
    #expect(presence.realJID == "guest-uuid@guest.example.test/abcd1234")
    #expect(!presence.isSelf)
    #expect(!presence.isModerator)
    #expect(presence.isAvailable)
  }

  @Test
  func parsesKickAndDestroyNotices() throws {
    let kicked = try MUCParticipantPresence(
      element: try XMPPParser().parse(
        """
        <presence from="room@lobby.example.test/me" type="unavailable">
          <x xmlns="http://jabber.org/protocol/muc#user">
            <item affiliation="none" role="none"><reason>The host did not admit you.</reason></item>
            <status code="110"/>
            <status code="307"/>
          </x>
        </presence>
        """
      )
    )
    #expect(kicked.isSelf)
    #expect(kicked.wasKicked)
    #expect(!kicked.isAvailable)
    #expect(kicked.destroyed == nil)

    let destroyed = try MUCParticipantPresence(
      element: try XMPPParser().parse(
        """
        <presence from="room@lobby.example.test/me" type="unavailable">
          <x xmlns="http://jabber.org/protocol/muc#user">
            <item affiliation="none" role="none"/>
            <destroy jid="room@conference.example.test"><reason>Lobby room closed.</reason></destroy>
            <status code="110"/>
          </x>
        </presence>
        """
      )
    )
    #expect(
      destroyed.destroyed
        == MUCRoomDestroyed(
          alternateRoomJID: "room@conference.example.test",
          reason: "Lobby room closed."
        )
    )
  }

  @Test
  func buildsLobbyJoinPresence() throws {
    let presence = LobbyJoinPresence(
      lobbyRoomJID: "room@lobby.example.test",
      nickname: "abcd1234",
      displayName: "Guest One"
    )
    let reparsed = try XMPPParser().parse(XMPPWriter.serialize(presence.element()))
    #expect(reparsed[attribute: "to"] == "room@lobby.example.test/abcd1234")
    #expect(reparsed.child(named: "x", namespace: MUCNamespace.muc) != nil)
    #expect(reparsed.child(named: "nick", namespace: MUCNamespace.nick)?.text == "Guest One")
    #expect(reparsed.child(named: "SourceInfo") == nil)
  }

  @Test
  func buildsAdmissionInviteAndParsesItBack() throws {
    let message = MUCInviteMessage(
      roomJID: "room@conference.example.test",
      inviteeJIDs: ["guest-uuid@guest.example.test/abcd1234"]
    )
    let reparsed = try XMPPParser().parse(XMPPWriter.serialize(message.element()))
    #expect(reparsed.name == "message")
    #expect(reparsed[attribute: "to"] == "room@conference.example.test")
    let invite = reparsed.child(named: "x", namespace: MUCNamespace.user)?.child(named: "invite")
    #expect(invite?[attribute: "to"] == "guest-uuid@guest.example.test/abcd1234")

    // What the invitee receives once the room has forwarded it.
    let forwarded = try XMPPParser().parse(
      """
      <message xmlns="jabber:client" from="room@conference.example.test" \
      to="guest-uuid@guest.example.test/abcd1234">
        <x xmlns="http://jabber.org/protocol/muc#user">
          <invite from="host@example.test/host"><reason/></invite>
          <password>secret</password>
        </x>
      </message>
      """
    )
    let invitation = try #require(MUCInvitation(element: forwarded))
    #expect(invitation.roomJID == "room@conference.example.test")
    #expect(invitation.inviterJID == "host@example.test/host")
    #expect(invitation.reason == nil)
    #expect(invitation.password == "secret")
    // Our own outgoing invitation has no sender and is not one we received.
    #expect(MUCInvitation(element: reparsed) == nil)
  }

  @Test
  func buildsKickRequest() throws {
    let kick = MUCKickRequest(
      id: "deny-1",
      roomJID: "room@lobby.example.test",
      nickname: "abcd1234",
      reason: "Not admitted."
    )
    let reparsed = try XMPPParser().parse(XMPPWriter.serialize(kick.element()))
    #expect(reparsed[attribute: "type"] == "set")
    #expect(reparsed[attribute: "to"] == "room@lobby.example.test")
    let item = reparsed.child(named: "query", namespace: MUCNamespace.admin)?.child(named: "item")
    #expect(item?[attribute: "nick"] == "abcd1234")
    #expect(item?[attribute: "role"] == "none")
    #expect(item?.child(named: "reason")?.text == "Not admitted.")
  }

  @Test
  func parsesRoomInfoWithLobby() throws {
    let request = MUCRoomInfoRequest(id: "info-1", roomJID: "room@conference.example.test")
    let reparsedRequest = try XMPPParser().parse(XMPPWriter.serialize(request.element()))
    #expect(reparsedRequest[attribute: "type"] == "get")
    #expect(
      reparsedRequest.child(named: "query", namespace: XMPPClientCapabilities.discoInfoNamespace)
        != nil
    )

    let response = try XMPPParser().parse(
      """
      <iq xmlns="jabber:client" id="info-1" type="result" from="room@conference.example.test">
        <query xmlns="http://jabber.org/protocol/disco#info">
          <identity category="conference" type="text" name="room"/>
          <feature var="http://jabber.org/protocol/muc"/>
          <feature var="muc_membersonly"/>
          <feature var="muc_unsecured"/>
          <x xmlns="jabber:x:data" type="result">
            <field var="FORM_TYPE" type="hidden"><value>http://jabber.org/protocol/muc#roominfo</value></field>
            <field var="muc#roominfo_meetingId" label="The meeting unique id."><value>meeting-42</value></field>
            <field var="muc#roominfo_lobbyroom" label="Lobby room jid"><value>room@lobby.example.test</value></field>
          </x>
        </query>
      </iq>
      """
    )
    let info = try MUCRoomInfo(element: response)
    #expect(info.isMembersOnly)
    #expect(!info.isPasswordProtected)
    #expect(info.lobbyRoomJID == "room@lobby.example.test")
    #expect(info.activeLobbyRoomJID == "room@lobby.example.test")
    #expect(info.meetingID == "meeting-42")

    let plain = try MUCRoomInfo(
      element: try XMPPParser().parse(
        """
        <iq id="info-2" type="result"><query xmlns="http://jabber.org/protocol/disco#info">
          <feature var="muc_passwordprotected"/></query></iq>
        """
      )
    )
    #expect(!plain.isMembersOnly)
    #expect(plain.isPasswordProtected)
    #expect(plain.activeLobbyRoomJID == nil)
  }

  @Test
  func recognisesConfigurationChangeNotice() throws {
    let notice = try XMPPParser().parse(
      """
      <message from="room@conference.example.test" type="groupchat">
        <x xmlns="http://jabber.org/protocol/muc#user"><status code="104"/></x>
      </message>
      """
    )
    #expect(MUCRoomNotice.isConfigurationChange(notice))
    let chat = try XMPPParser().parse(
      """
      <message from="room@conference.example.test/someone" type="groupchat">\
      <body>hi</body></message>
      """
    )
    #expect(!MUCRoomNotice.isConfigurationChange(chat))
  }
}
