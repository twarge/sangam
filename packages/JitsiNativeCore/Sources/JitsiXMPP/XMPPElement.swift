import Foundation

public struct XMPPElement: Equatable, Sendable {
  /// The namespace client stanzas (`iq`, `presence`, `message`) live in.
  public static let clientNamespace = "jabber:client"

  public var name: String
  public var namespace: String?
  public var attributes: [String: String]
  public var children: [XMPPElement]
  public var text: String

  /// Whether this is a top-level client stanza that RFC 7395 requires to be
  /// explicitly qualified when sent as a WebSocket frame.
  public var isClientStanza: Bool {
    name == "iq" || name == "presence" || name == "message"
  }

  public init(
    name: String,
    namespace: String? = nil,
    attributes: [String: String] = [:],
    children: [XMPPElement] = [],
    text: String = ""
  ) {
    self.name = name
    self.namespace = namespace
    self.attributes = attributes
    self.children = children
    self.text = text
  }

  public subscript(attribute name: String) -> String? {
    attributes[name]
  }

  public func child(named name: String, namespace: String? = nil) -> XMPPElement? {
    children.first { child in
      child.name == name && (namespace == nil || child.namespace == namespace)
    }
  }

  public func children(named name: String, namespace: String? = nil) -> [XMPPElement] {
    children.filter { child in
      child.name == name && (namespace == nil || child.namespace == namespace)
    }
  }

  public func descendants(named name: String, namespace: String? = nil) -> [XMPPElement] {
    children.flatMap { child -> [XMPPElement] in
      let current =
        child.name == name && (namespace == nil || child.namespace == namespace)
        ? [child]
        : []
      return current + child.descendants(named: name, namespace: namespace)
    }
  }
}

public enum XMPPStanza: Equatable, Sendable {
  case iq(IQ)
  case message(Message)
  case presence(Presence)
  case streamOpen(XMPPElement)
  case streamClose
  case other(XMPPElement)

  public struct IQ: Equatable, Sendable {
    public var id: String?
    public var from: String?
    public var to: String?
    public var type: String?
    public var children: [XMPPElement]
  }

  public struct Message: Equatable, Sendable {
    public var id: String?
    public var from: String?
    public var to: String?
    public var type: String?
    public var children: [XMPPElement]
  }

  public struct Presence: Equatable, Sendable {
    public var id: String?
    public var from: String?
    public var to: String?
    public var type: String?
    public var children: [XMPPElement]
  }

  public init(element: XMPPElement) {
    switch element.name {
    case "iq":
      self = .iq(
        IQ(
          id: element[attribute: "id"],
          from: element[attribute: "from"],
          to: element[attribute: "to"],
          type: element[attribute: "type"],
          children: element.children
        )
      )
    case "message":
      self = .message(
        Message(
          id: element[attribute: "id"],
          from: element[attribute: "from"],
          to: element[attribute: "to"],
          type: element[attribute: "type"],
          children: element.children
        )
      )
    case "presence":
      self = .presence(
        Presence(
          id: element[attribute: "id"],
          from: element[attribute: "from"],
          to: element[attribute: "to"],
          type: element[attribute: "type"],
          children: element.children
        )
      )
    case "open" where element.namespace == "urn:ietf:params:xml:ns:xmpp-framing":
      self = .streamOpen(element)
    case "close" where element.namespace == "urn:ietf:params:xml:ns:xmpp-framing":
      self = .streamClose
    default:
      self = .other(element)
    }
  }
}
