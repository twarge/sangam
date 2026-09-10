import Foundation

public struct FocusConferenceRequest: Equatable, Sendable {
  public var id: String
  public var focusJID: String
  public var roomJID: String
  public var machineUID: String
  public var token: String?
  public var sessionID: String?
  public var properties: [String: String]

  public init(
    id: String,
    focusJID: String,
    roomJID: String,
    machineUID: String,
    token: String? = nil,
    sessionID: String? = nil,
    properties: [String: String] = ["visitors-version": "1"]
  ) {
    self.id = id
    self.focusJID = focusJID
    self.roomJID = roomJID
    self.machineUID = machineUID
    self.token = token
    self.sessionID = sessionID
    self.properties = properties
  }

  public func element() -> XMPPElement {
    var conferenceAttributes = [
      "machine-uid": machineUID,
      "room": roomJID,
    ]
    if let token, !token.isEmpty { conferenceAttributes["token"] = token }
    if let sessionID, !sessionID.isEmpty {
      conferenceAttributes["session-id"] = sessionID
    }
    let propertyElements = properties.keys.sorted().compactMap { name -> XMPPElement? in
      guard let value = properties[name] else { return nil }
      return XMPPElement(name: "property", attributes: ["name": name, "value": value])
    }
    return XMPPElement(
      name: "iq",
      attributes: ["id": id, "to": focusJID, "type": "set"],
      children: [
        XMPPElement(
          name: "conference",
          namespace: FocusConferenceResponse.namespace,
          attributes: conferenceAttributes,
          children: propertyElements
        )
      ]
    )
  }
}

public struct FocusConferenceResponse: Equatable, Sendable {
  public static let namespace = "http://jitsi.org/protocol/focus"

  public var id: String?
  public var ready: Bool
  public var focusJID: String?
  public var sessionID: String?
  public var identity: String?
  public var vnode: String?
  public var properties: [String: String]

  public init(
    ready: Bool,
    focusJID: String? = nil,
    sessionID: String? = nil,
    identity: String? = nil,
    vnode: String? = nil,
    properties: [String: String] = [:]
  ) {
    id = nil
    self.ready = ready
    self.focusJID = focusJID
    self.sessionID = sessionID
    self.identity = identity
    self.vnode = vnode
    self.properties = properties
  }

  public init(element: XMPPElement) throws {
    guard element.name == "iq", element[attribute: "type"] == "result" else {
      throw FocusConferenceError.notSuccessfulIQ
    }
    guard
      let conference = element.child(named: "conference", namespace: Self.namespace)
    else {
      throw FocusConferenceError.missingConference
    }
    id = element[attribute: "id"]
    ready = conference[attribute: "ready"] == "true"
    focusJID = conference[attribute: "focusjid"]
    sessionID = conference[attribute: "session-id"]
    identity = conference[attribute: "identity"]
    vnode = conference[attribute: "vnode"]
    properties = Dictionary(
      uniqueKeysWithValues: conference.children(named: "property", namespace: Self.namespace)
        .compactMap { property in
          guard
            let name = property[attribute: "name"],
            let value = property[attribute: "value"]
          else { return nil }
          return (name, value)
        }
    )
  }
}

public enum FocusConferenceError: Error, Equatable, Sendable {
  case notSuccessfulIQ
  case missingConference
}

extension FocusConferenceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notSuccessfulIQ:
      return "The Jitsi conference focus refused to allocate the meeting."
    case .missingConference:
      return "The Jitsi conference focus did not name a meeting to join."
    }
  }
}
