import Foundation

public enum XMPPCredential: Equatable, Sendable {
  case anonymous
  case plain(username: String, password: String)
}

public enum XMPPStreamState: Equatable, Sendable {
  case idle
  case awaitingPreAuthenticationFeatures
  case awaitingAuthenticationResult
  case awaitingPostAuthenticationFeatures
  case awaitingBindResult(id: String)
  case ready(jid: String)
  case failed
}

public enum XMPPNegotiationAction: Equatable, Sendable {
  case send(String)
  case ready(jid: String)
}

public enum XMPPNegotiationError: Error, Equatable, Sendable {
  case invalidState(XMPPStreamState)
  case missingMechanism(String)
  case authenticationFailed
  case resourceBindingUnavailable
  case resourceBindingFailed
  case missingBoundJID
  case streamError
}

public struct XMPPStreamNegotiator: Sendable {
  public private(set) var state: XMPPStreamState = .idle

  private let domain: String
  private let resource: String
  private let credential: XMPPCredential
  private let bindID: String

  public init(
    domain: String,
    resource: String,
    credential: XMPPCredential,
    bindID: String = "sangam-bind-1"
  ) {
    self.domain = domain
    self.resource = resource
    self.credential = credential
    self.bindID = bindID
  }

  public mutating func start() throws -> [XMPPNegotiationAction] {
    guard state == .idle else { throw XMPPNegotiationError.invalidState(state) }
    state = .awaitingPreAuthenticationFeatures
    return [.send(Self.openFrame(domain: domain))]
  }

  public mutating func receive(_ element: XMPPElement) throws -> [XMPPNegotiationAction] {
    if element.name == "error" && element.namespace == "urn:ietf:params:xml:ns:xmpp-streams" {
      state = .failed
      throw XMPPNegotiationError.streamError
    }

    switch state {
    case .awaitingPreAuthenticationFeatures:
      guard element.name == "features" else { return [] }
      let mechanisms = Set(
        element.descendants(
          named: "mechanism",
          namespace: "urn:ietf:params:xml:ns:xmpp-sasl"
        ).map(\.text)
      )
      let frame: String
      switch credential {
      case .anonymous:
        guard mechanisms.contains("ANONYMOUS") else {
          state = .failed
          throw XMPPNegotiationError.missingMechanism("ANONYMOUS")
        }
        frame = XMPPWriter.serialize(
          XMPPElement(
            name: "auth",
            namespace: "urn:ietf:params:xml:ns:xmpp-sasl",
            attributes: ["mechanism": "ANONYMOUS"]
          )
        )
      case .plain(let username, let password):
        guard mechanisms.contains("PLAIN") else {
          state = .failed
          throw XMPPNegotiationError.missingMechanism("PLAIN")
        }
        let payload = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        frame = XMPPWriter.serialize(
          XMPPElement(
            name: "auth",
            namespace: "urn:ietf:params:xml:ns:xmpp-sasl",
            attributes: ["mechanism": "PLAIN"],
            text: payload
          )
        )
      }
      state = .awaitingAuthenticationResult
      return [.send(frame)]

    case .awaitingAuthenticationResult:
      if element.name == "failure"
        && element.namespace == "urn:ietf:params:xml:ns:xmpp-sasl"
      {
        state = .failed
        throw XMPPNegotiationError.authenticationFailed
      }
      guard
        element.name == "success",
        element.namespace == "urn:ietf:params:xml:ns:xmpp-sasl"
      else { return [] }
      state = .awaitingPostAuthenticationFeatures
      return [.send(Self.openFrame(domain: domain))]

    case .awaitingPostAuthenticationFeatures:
      guard element.name == "features" else { return [] }
      guard
        element.descendants(
          named: "bind",
          namespace: "urn:ietf:params:xml:ns:xmpp-bind"
        ).isEmpty == false
      else {
        state = .failed
        throw XMPPNegotiationError.resourceBindingUnavailable
      }
      // The explicit stanza namespace matters: over RFC 7395 WebSocket framing
      // every frame is a standalone document, and a server rejects an IQ that
      // is not in `jabber:client` with `unsupported-stanza-type`. BOSH masked
      // this by re-namespacing body children.
      let bind = XMPPElement(
        name: "iq",
        namespace: XMPPElement.clientNamespace,
        attributes: ["id": bindID, "type": "set"],
        children: [
          XMPPElement(
            name: "bind",
            namespace: "urn:ietf:params:xml:ns:xmpp-bind",
            children: [XMPPElement(name: "resource", text: resource)]
          )
        ]
      )
      state = .awaitingBindResult(id: bindID)
      return [.send(XMPPWriter.serialize(bind))]

    case .awaitingBindResult(let id):
      guard element.name == "iq", element[attribute: "id"] == id else { return [] }
      guard element[attribute: "type"] == "result" else {
        state = .failed
        throw XMPPNegotiationError.resourceBindingFailed
      }
      guard
        let jid = element.child(
          named: "bind",
          namespace: "urn:ietf:params:xml:ns:xmpp-bind"
        )?.child(named: "jid")?.text,
        !jid.isEmpty
      else {
        state = .failed
        throw XMPPNegotiationError.missingBoundJID
      }
      state = .ready(jid: jid)
      return [.ready(jid: jid)]

    case .idle, .ready, .failed:
      throw XMPPNegotiationError.invalidState(state)
    }
  }

  public static func openFrame(domain: String) -> String {
    XMPPWriter.serialize(
      XMPPElement(
        name: "open",
        namespace: "urn:ietf:params:xml:ns:xmpp-framing",
        attributes: ["to": domain, "version": "1.0"]
      )
    )
  }
}
