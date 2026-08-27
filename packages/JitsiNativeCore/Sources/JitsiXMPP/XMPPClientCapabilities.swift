import Foundation

public struct XMPPClientCapabilities: Equatable, Sendable {
  public static let discoInfoNamespace = "http://jabber.org/protocol/disco#info"
  public static let pingNamespace = "urn:xmpp:ping"

  /// Features implemented by the native Jingle/WebRTC stack. Keep this list honest:
  /// Jicofo uses it to decide whether and how to offer a bridge session.
  public static let jitsiNative: XMPPClientCapabilities = {
    var features = [
      "http://jabber.org/protocol/caps",
      "http://jitsi.org/json-encoded-sources",
      "http://jitsi.org/receive-multiple-video-streams",
      "http://jitsi.org/remb",
      "http://jitsi.org/source-name",
      "http://jitsi.org/tcc",
      "urn:ietf:rfc:4588",
      "urn:xmpp:jingle:1",
      "urn:xmpp:jingle:apps:dtls:0",
      "urn:xmpp:jingle:apps:rtp:1",
      "urn:xmpp:jingle:apps:rtp:audio",
      "urn:xmpp:jingle:apps:rtp:video",
      "urn:xmpp:jingle:transports:ice-udp:1",
      // XEP-0343 — makes Jicofo include a "data" content in its offer, the
      // bridge channel as a WebRTC data channel on deployments without
      // colibri websockets (meet.jit.si).
      "urn:xmpp:jingle:transports:dtls-sctp:1",
    ]
    // SSRC rewriting (the bridge forwards a fixed small SSRC set and remaps
    // which conference source each carries) is implemented but not yet proven
    // against a live deployment — receive regressions appeared the moment it
    // was first advertised. Opt in explicitly while it is being verified;
    // without the flag the bridge uses classic per-source forwarding.
    if ProcessInfo.processInfo.environment["SANGAM_SSRC_REWRITING"] == "1" {
      features.append("http://jitsi.org/ssrc-rewriting-1")
    }
    return XMPPClientCapabilities(features: features)
  }()

  public var features: [String]

  public init(features: [String]) {
    self.features = Array(Set(features)).sorted()
  }

  public func response(to request: XMPPElement) -> XMPPElement? {
    guard
      request.name == "iq",
      request[attribute: "type"] == "get",
      let id = request[attribute: "id"]
    else { return nil }

    if let query = request.child(named: "query", namespace: Self.discoInfoNamespace) {
      var queryAttributes: [String: String] = [:]
      if let node = query[attribute: "node"] { queryAttributes["node"] = node }
      return result(
        id: id,
        to: request[attribute: "from"],
        children: [
          XMPPElement(
            name: "query",
            namespace: Self.discoInfoNamespace,
            attributes: queryAttributes,
            children: features.map {
              XMPPElement(name: "feature", attributes: ["var": $0])
            }
          )
        ]
      )
    }

    if request.child(named: "ping", namespace: Self.pingNamespace) != nil {
      return result(id: id, to: request[attribute: "from"], children: [])
    }
    return nil
  }

  private func result(id: String, to: String?, children: [XMPPElement]) -> XMPPElement {
    var attributes = ["id": id, "type": "result"]
    if let to { attributes["to"] = to }
    return XMPPElement(name: "iq", attributes: attributes, children: children)
  }
}
