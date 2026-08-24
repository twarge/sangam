import Foundation
import Testing

@testable import JitsiXMPP

@Test
func parsesNamespacedJingleIQ() throws {
  let xml = """
    <iq from="focus@example.test" id="j1" type="set">
      <jingle xmlns="urn:xmpp:jingle:1" action="session-initiate" sid="abc">
        <content name="audio" creator="initiator"/>
      </jingle>
    </iq>
    """

  let root = try XMPPParser().parse(xml)
  #expect(root.name == "iq")
  #expect(root[attribute: "id"] == "j1")
  #expect(root.child(named: "jingle", namespace: "urn:xmpp:jingle:1")?[attribute: "sid"] == "abc")

  guard case .iq(let iq) = XMPPStanza(element: root) else {
    Issue.record("Expected IQ stanza")
    return
  }
  #expect(iq.from == "focus@example.test")
  #expect(iq.type == "set")
}

@Test
func rejectsEntityDocuments() {
  let xml = """
    <!DOCTYPE iq [<!ENTITY payload "unsafe">]>
    <iq>&payload;</iq>
    """

  #expect(throws: XMPPParsingError.documentTypeNotAllowed) {
    try XMPPParser().parse(xml)
  }
}

@Test
func enforcesDepthAndSizeBounds() {
  let parser = XMPPParser(
    bounds: XMLBounds(
      maximumBytes: 32,
      maximumDepth: 2,
      maximumElements: 10,
      maximumAttributesPerElement: 4,
      maximumTextBytes: 8
    )
  )

  #expect(throws: XMPPParsingError.documentTooLarge(limit: 32)) {
    try parser.parse("<message><body>this document is deliberately too long</body></message>")
  }

  let depthParser = XMPPParser(
    bounds: XMLBounds(maximumBytes: 128, maximumDepth: 2)
  )
  #expect(throws: XMPPParsingError.nestingTooDeep(limit: 2)) {
    try depthParser.parse("<iq><a><b/></a></iq>")
  }
}

@Test
func writerEscapesUntrustedValues() throws {
  let element = XMPPElement(
    name: "message",
    attributes: ["to": "room&friends\"@example.test"],
    children: [XMPPElement(name: "body", text: "<hello> & goodbye")]
  )
  let serialized = XMPPWriter.serialize(element)

  #expect(serialized.contains("room&amp;friends&quot;@example.test"))
  #expect(serialized.contains("&lt;hello&gt; &amp; goodbye"))
  #expect(try XMPPParser().parse(serialized).name == "message")
}
