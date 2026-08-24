import Foundation
import JitsiXMPP

public enum JingleIQError: Error, Equatable, Sendable {
  case notSetIQ
  case missingID
  case missingSender
  case malformedCandidate
}

public struct IncomingJingleIQ: Equatable, Sendable {
  public var id: String
  public var sender: String
  public var recipient: String?
  public var session: JingleSessionDescription

  public init(element: XMPPElement, parser: JingleParser = .init()) throws {
    guard element.name == "iq", element[attribute: "type"] == "set" else {
      throw JingleIQError.notSetIQ
    }
    guard let id = element[attribute: "id"], !id.isEmpty else { throw JingleIQError.missingID }
    guard let sender = element[attribute: "from"], !sender.isEmpty else {
      throw JingleIQError.missingSender
    }
    self.id = id
    self.sender = sender
    recipient = element[attribute: "to"]
    session = try parser.parse(element)
  }

  public func acknowledgment() -> XMPPElement {
    var attributes = ["id": id, "to": sender, "type": "result"]
    if let recipient { attributes["from"] = recipient }
    return XMPPElement(name: "iq", attributes: attributes)
  }
}

public struct JingleIQBuilder: Sendable {
  public init() {}

  public func sessionAccept(
    answerSDP: String,
    incoming: IncomingJingleIQ,
    responder: String,
    id: String,
    sourceMetadataByMediaType: [String: LocalSourceMetadata] = [:]
  ) throws -> XMPPElement {
    let jingle = try JingleAnswerBuilder().element(
      from: answerSDP,
      sessionID: incoming.session.sessionID,
      responder: responder,
      sourceMetadataByMediaType: sourceMetadataByMediaType
    )
    return iq(id: id, to: incoming.sender, from: responder, jingle: jingle)
  }

  /// Builds a `session-terminate` carrying a single Jingle reason, e.g.
  /// `decline` to refuse a session the client will not run (a peer's P2P
  /// offer) or `success` for an ordinary hang-up.
  public func sessionTerminate(
    sessionID: String,
    reason: String,
    initiator: String,
    to recipient: String,
    from sender: String,
    id: String
  ) -> XMPPElement {
    let jingle = XMPPElement(
      name: "jingle",
      namespace: JingleParser.jingleNamespace,
      attributes: [
        "action": JingleAction.sessionTerminate.rawValue,
        "initiator": initiator,
        "sid": sessionID,
      ],
      children: [
        XMPPElement(
          name: "reason",
          namespace: JingleParser.jingleNamespace,
          children: [XMPPElement(name: reason, namespace: JingleParser.jingleNamespace)]
        )
      ]
    )
    return iq(id: id, to: recipient, from: sender, jingle: jingle)
  }

  /// Builds a trickled-candidate `transport-info`.
  ///
  /// `credentials` are required rather than optional because a transport
  /// element without them is actively harmful to Jitsi Videobridge — see
  /// `ICECredentials`.
  public func transportInfo(
    sessionID: String,
    candidateSDP: String,
    mid: String,
    credentials: ICECredentials,
    initiator: String,
    to recipient: String,
    from sender: String,
    id: String
  ) throws -> XMPPElement {
    guard let candidate = JingleCandidateCodec.element(sdp: candidateSDP) else {
      throw JingleIQError.malformedCandidate
    }
    let transport = XMPPElement(
      name: "transport",
      namespace: JingleParser.iceNamespace,
      attributes: ["pwd": credentials.password, "ufrag": credentials.usernameFragment],
      children: [candidate]
    )
    let content = XMPPElement(
      name: "content",
      attributes: ["creator": "initiator", "name": mid],
      children: [transport]
    )
    let jingle = XMPPElement(
      name: "jingle",
      namespace: JingleParser.jingleNamespace,
      attributes: [
        "action": JingleAction.transportInfo.rawValue,
        "initiator": initiator,
        "sid": sessionID,
      ],
      children: [content]
    )
    return iq(id: id, to: recipient, from: sender, jingle: jingle)
  }

  public func sourceUpdate(
    action: JingleAction,
    sessionID: String,
    content: JingleContent,
    initiator: String,
    to recipient: String,
    from sender: String,
    id: String
  ) -> XMPPElement {
    precondition(action == .sourceAdd || action == .sourceRemove)
    let description = content.description
    // The reference client signals the source name and video type as XML
    // attributes of `<source>`, with the msid as its only parameter.
    var children = (description?.sources ?? []).map { source in
      var attributes = ["ssrc": String(source.ssrc)]
      if let name = source.name { attributes["name"] = name }
      if let videoType = source.videoType { attributes["videoType"] = videoType }
      return XMPPElement(
        name: "source",
        namespace: JingleParser.sourceNamespace,
        attributes: attributes,
        children: source.parameters.keys.sorted().compactMap { name in
          source.parameters[name].map {
            XMPPElement(name: "parameter", attributes: ["name": name, "value": $0])
          }
        }
      )
    }
    children += (description?.sourceGroups ?? []).map { group in
      XMPPElement(
        name: "ssrc-group",
        namespace: JingleParser.sourceNamespace,
        attributes: ["semantics": group.semantics],
        children: group.sources.map {
          XMPPElement(name: "source", attributes: ["ssrc": String($0)])
        }
      )
    }
    let descriptionElement = XMPPElement(
      name: "description",
      namespace: JingleParser.rtpNamespace,
      attributes: ["media": description?.media ?? "video"],
      children: children
    )
    let contentElement = XMPPElement(
      name: "content",
      attributes: ["creator": content.creator ?? "initiator", "name": content.name],
      children: [descriptionElement]
    )
    let jingle = XMPPElement(
      name: "jingle",
      namespace: JingleParser.jingleNamespace,
      attributes: [
        "action": action.rawValue,
        "initiator": initiator,
        "sid": sessionID,
      ],
      children: [contentElement]
    )
    return iq(id: id, to: recipient, from: sender, jingle: jingle)
  }

  private func iq(
    id: String,
    to recipient: String,
    from sender: String,
    jingle: XMPPElement
  ) -> XMPPElement {
    XMPPElement(
      name: "iq",
      attributes: ["from": sender, "id": id, "to": recipient, "type": "set"],
      children: [jingle]
    )
  }
}

public enum JingleCandidateCodec {
  public static func sdp(_ candidate: ICECandidate, contentName: String) throws -> String {
    guard
      let foundation = candidate.foundation,
      let component = candidate.component,
      let protocolName = candidate.protocolName,
      let priority = candidate.priority,
      let ip = candidate.ip,
      let port = candidate.port,
      let type = candidate.type
    else { throw JingleSDPError.incompleteTransport(content: contentName) }

    var line =
      "a=candidate:\(foundation) \(component) \(protocolName.lowercased()) \(priority) \(ip) \(port) typ \(type)"
    if let address = candidate.relatedAddress { line += " raddr \(address)" }
    if let relatedPort = candidate.relatedPort { line += " rport \(relatedPort)" }
    if let tcpType = candidate.tcpType { line += " tcptype \(tcpType)" }
    if let generation = candidate.generation { line += " generation \(generation)" }
    return line
  }

  public static func element(sdp value: String) -> XMPPElement? {
    let candidate =
      value.hasPrefix("a=candidate:")
      ? String(value.dropFirst("a=candidate:".count))
      : value
    let parts = candidate.split(separator: " ").map(String.init)
    guard parts.count >= 8, parts[6] == "typ" else { return nil }
    var attributes = [
      "foundation": parts[0], "component": parts[1], "protocol": parts[2],
      "priority": parts[3], "ip": parts[4], "port": parts[5], "type": parts[7],
      "generation": "0",
    ]
    var index = 8
    while index + 1 < parts.count {
      switch parts[index] {
      case "raddr": attributes["rel-addr"] = parts[index + 1]
      case "rport": attributes["rel-port"] = parts[index + 1]
      case "tcptype": attributes["tcptype"] = parts[index + 1]
      case "generation": attributes["generation"] = parts[index + 1]
      default: break
      }
      index += 2
    }
    return XMPPElement(name: "candidate", attributes: attributes)
  }
}
