import Foundation
import JitsiXMPP

public enum JingleSDPError: Error, Equatable, Sendable {
  case unsupportedAction
  case missingDescription(content: String)
  case missingPayloads(content: String)
  case incompleteTransport(content: String)
  case malformedSDP
  case sdpTooLarge(limit: Int)
  case tooManySDPLines(limit: Int)
}

public struct JingleSDPTranslator: Sendable {
  public var sessionOriginID: UInt64

  public init(sessionOriginID: UInt64 = 1) {
    self.sessionOriginID = sessionOriginID
  }

  /// Translates Jicofo's offer into the SDP handed to WebRTC, following
  /// lib-jitsi-meet's `SDP.fromJingle` for a bridge session: every remote
  /// source gets its **own media line**. Unified Plan binds one receiver per
  /// m-line, so folding several remote sources into one line would leave all
  /// but one undecodable. The first source of each content stays on that
  /// content's original (send/receive) line — Jicofo orders the bridge's own
  /// mixed source first so a participant's departure never tears that line
  /// down — and each further source becomes a receive-only line carrying the
  /// source together with its retransmission (FID) partner. Media identifiers
  /// are renumbered sequentially, exactly as the reference client does.
  public func offerSDP(from session: JingleSessionDescription) throws -> String {
    guard session.action == .sessionInitiate || session.action == .transportReplace else {
      throw JingleSDPError.unsupportedAction
    }

    var mediaSections: [[String]] = []

    for content in session.contents {
      guard let description = content.description else {
        throw JingleSDPError.missingDescription(content: content.name)
      }
      guard !description.payloadTypes.isEmpty else {
        throw JingleSDPError.missingPayloads(content: content.name)
      }
      guard
        let transport = content.transport,
        let ufrag = transport.usernameFragment,
        let password = transport.password,
        let fingerprint = transport.fingerprint,
        !fingerprint.hash.isEmpty,
        !fingerprint.value.isEmpty
      else {
        throw JingleSDPError.incompleteTransport(content: content.name)
      }

      let payloadIDs = description.payloadTypes.map { String($0.id) }.joined(separator: " ")
      let head = [
        "m=\(description.media) 9 UDP/TLS/RTP/SAVPF \(payloadIDs)",
        "c=IN IP4 0.0.0.0",
        "a=rtcp:9 IN IP4 0.0.0.0",
        "a=ice-ufrag:\(ufrag)",
        "a=ice-pwd:\(password)",
        "a=ice-options:trickle",
        "a=fingerprint:\(fingerprint.hash) \(fingerprint.value)",
        "a=setup:\(fingerprint.setup ?? "actpass")",
      ]
      // Deliberately no inline `a=candidate` lines. WebRTC parses inline
      // candidates into the remote description but does not reliably feed them
      // to the ICE agent, and their presence then makes the explicit
      // `addIceCandidate` calls look like duplicates and get dropped — leaving
      // ICE with no remote candidates. The coordinator adds every candidate
      // through `addIceCandidate` instead (standard trickle ICE).

      var tail: [String] = []
      for payload in description.payloadTypes {
        if let name = payload.name, let clockRate = payload.clockRate {
          var mapping = "a=rtpmap:\(payload.id) \(name)/\(clockRate)"
          if let channels = payload.channels, channels > 1 { mapping += "/\(channels)" }
          tail.append(mapping)
        }
        if !payload.parameters.isEmpty {
          let parameters = payload.parameters.keys.sorted().compactMap { name -> String? in
            guard let value = payload.parameters[name] else { return nil }
            return name.isEmpty ? value : "\(name)=\(value)"
          }.joined(separator: ";")
          tail.append("a=fmtp:\(payload.id) \(parameters)")
        }
        for feedback in payload.feedback {
          let subtype = feedback.subtype.map { " \($0)" } ?? ""
          tail.append("a=rtcp-fb:\(payload.id) \(feedback.type)\(subtype)")
        }
      }
      for extensionInfo in description.headerExtensions {
        tail.append("a=extmap:\(extensionInfo.id) \(extensionInfo.uri)")
      }
      if description.rtcpMux { tail.append("a=rtcp-mux") }
      if description.extmapAllowMixed { tail.append("a=extmap-allow-mixed") }

      func ssrcLines(for source: RTPSource) -> [String] {
        source.parameters.keys.sorted().compactMap { name in
          source.parameters[name].map { "a=ssrc:\(source.ssrc) \(name):\($0)" }
        }
      }

      // The bridge's mixed ("mixedmslabel") sources come first so the m-line
      // that also carries our sending direction holds the one source that is
      // never removed — the same ordering jingle2media applies upstream.
      let visible = description.sources.filter { !$0.parameters.isEmpty }
      let ordered =
        visible.filter(Self.isMixedBridgeSource) + visible.filter { !Self.isMixedBridgeSource($0) }

      var placed = Set<UInt32>()
      var contentSections: [[String]] = []
      for source in ordered where !placed.contains(source.ssrc) {
        placed.insert(source.ssrc)
        let sectionDirection =
          contentSections.isEmpty ? direction(senders: content.senders) : "sendonly"
        var section = head + ["a=\(sectionDirection)"] + tail
        // A media-level msid line, so WebRTC surfaces the remote track under
        // the signaled id instead of synthesizing one — the id is how a track
        // is attributed back to its source.
        if let msid = source.parameters["msid"] {
          section.append("a=msid:\(msid)")
        }
        var sourceLines = ssrcLines(for: source)
        if let group = description.sourceGroups.first(where: { $0.sources.contains(source.ssrc) }),
          !group.sources.isEmpty
        {
          if let partner = group.sources.first(where: { $0 != source.ssrc }),
            let partnerSource = visible.first(where: { $0.ssrc == partner })
          {
            placed.insert(partner)
            sourceLines += ssrcLines(for: partnerSource)
          }
          section.append(
            "a=ssrc-group:\(group.semantics) "
              + group.sources.map(String.init).joined(separator: " ")
          )
        }
        section += sourceLines
        contentSections.append(section)
      }
      if contentSections.isEmpty {
        contentSections.append(head + ["a=\(direction(senders: content.senders))"] + tail)
      }
      mediaSections += contentSections
    }

    // Renumber the media identifiers sequentially and bundle them all, as the
    // reference client regenerates the BUNDLE group after splitting.
    var mids: [String] = []
    for index in mediaSections.indices {
      let mid = String(index)
      mids.append(mid)
      // The direction line directly follows the fixed 8-line head.
      mediaSections[index].insert("a=mid:\(mid)", at: 8)
    }
    let lines =
      [
        "v=0",
        "o=- \(sessionOriginID) 2 IN IP4 0.0.0.0",
        "s=-",
        "t=0 0",
        "a=msid-semantic: WMS *",
        "a=group:BUNDLE \(mids.joined(separator: " "))",
      ] + mediaSections.flatMap { $0 }
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  /// Whether a source is the videobridge's own mixed stream, recognized the way
  /// the reference client does: any attribute value containing "mixedmslabel".
  private static func isMixedBridgeSource(_ source: RTPSource) -> Bool {
    source.parameters.values.contains { $0.contains("mixedmslabel") }
  }

  private func direction(senders: String?) -> String {
    switch senders {
    case "initiator": "sendonly"
    case "responder": "recvonly"
    case "none": "inactive"
    default: "sendrecv"
    }
  }

}

public struct LocalSourceMetadata: Equatable, Sendable {
  public var name: String
  public var videoType: String?

  public init(name: String, videoType: String? = nil) {
    self.name = name
    self.videoType = videoType
  }
}

public struct JingleAnswerBuilder: Sendable {
  public init() {}

  /// Serializes the local WebRTC answer as a Jingle session-accept, the way
  /// lib-jitsi-meet's `SDP.toJingle` does for a bridge session: one content per
  /// **media type**, named "audio"/"video", with every media line of that type
  /// folding its sources into it. The extra receive-only lines the split offer
  /// produced carry no local sources, so in practice the accept describes just
  /// this client's own microphone and camera.
  public func element(
    from answerSDP: String,
    sessionID: String,
    responder: String,
    sourceMetadataByMediaType: [String: LocalSourceMetadata] = [:]
  ) throws -> XMPPElement {
    let document = try SDPDocument(answerSDP)
    var kinds: [String] = []
    var sectionsByKind: [String: [SDPMediaSection]] = [:]
    for media in document.media {
      if sectionsByKind[media.kind] == nil { kinds.append(media.kind) }
      sectionsByKind[media.kind, default: []].append(media)
    }
    let contents = try kinds.map { kind in
      try contentElement(
        kind: kind,
        sections: sectionsByKind[kind] ?? [],
        metadata: sourceMetadataByMediaType[kind]
      )
    }
    let group = XMPPElement(
      name: "group",
      namespace: JingleParser.groupingNamespace,
      attributes: ["semantics": "BUNDLE"],
      children: kinds.map { XMPPElement(name: "content", attributes: ["name": $0]) }
    )
    return XMPPElement(
      name: "jingle",
      namespace: JingleParser.jingleNamespace,
      attributes: [
        "action": JingleAction.sessionAccept.rawValue,
        "responder": responder,
        "sid": sessionID,
      ],
      children: contents + [group]
    )
  }

  private func contentElement(
    kind: String,
    sections: [SDPMediaSection],
    metadata: LocalSourceMetadata?
  ) throws -> XMPPElement {
    guard let media = sections.first else { throw JingleSDPError.malformedSDP }
    let payloads = media.formats.compactMap { format -> XMPPElement? in
      let prefix = "a=rtpmap:\(format) "
      guard
        let mapping = media.lines.first(where: { $0.hasPrefix(prefix) })?
          .dropFirst(prefix.count)
      else { return nil }
      let components = mapping.split(separator: "/", omittingEmptySubsequences: false)
      guard components.count >= 2 else { return nil }
      var attributes = [
        "id": format, "name": String(components[0]), "clockrate": String(components[1]),
      ]
      if components.count > 2 { attributes["channels"] = String(components[2]) }
      var children: [XMPPElement] = []
      if let fmtp = media.value(after: "a=fmtp:\(format) ") {
        for part in fmtp.split(separator: ";", omittingEmptySubsequences: false) {
          let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          children.append(
            XMPPElement(
              name: "parameter",
              attributes: [
                "name": pair.count == 2 ? String(pair[0]) : "",
                "value": pair.count == 2 ? String(pair[1]) : String(pair[0]),
              ]
            )
          )
        }
      }
      for feedback in media.values(after: "a=rtcp-fb:\(format) ") {
        let parts = feedback.split(separator: " ", maxSplits: 1)
        guard let type = parts.first else { continue }
        var feedbackAttributes = ["type": String(type)]
        if parts.count > 1 { feedbackAttributes["subtype"] = String(parts[1]) }
        children.append(
          XMPPElement(
            name: "rtcp-fb",
            namespace: JingleParser.feedbackNamespace,
            attributes: feedbackAttributes
          )
        )
      }
      return XMPPElement(
        name: "payload-type",
        attributes: attributes,
        children: children
      )
    }

    var descriptionChildren = payloads
    for extmap in media.values(after: "a=extmap:") {
      let parts = extmap.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let id = parts[0].split(separator: "/").first.map(String.init) ?? ""
      descriptionChildren.append(
        XMPPElement(
          name: "rtp-hdrext",
          namespace: JingleParser.headerExtensionNamespace,
          attributes: ["id": id, "uri": String(parts[1])]
        )
      )
    }
    if media.lines.contains("a=rtcp-mux") {
      descriptionChildren.append(XMPPElement(name: "rtcp-mux"))
    }
    if media.lines.contains("a=extmap-allow-mixed") {
      descriptionChildren.append(
        XMPPElement(name: "extmap-allow-mixed", namespace: JingleParser.headerExtensionNamespace)
      )
    }

    // Fold the local sources of every SENDING media line of this type into the
    // one content. Receive-only lines carry receiver-report SSRCs with a cname
    // but no msid — those are not sources, and Jicofo rejects the whole accept
    // over any advertised source without an msid ("Required source parameter
    // 'msid' is not present"). The reference client signals the source name
    // and video type as XML attributes and sends only the msid as a parameter.
    let sendingSections = sections.filter { ["sendrecv", "sendonly"].contains($0.direction) }
    let groupValues = sendingSections.flatMap { $0.values(after: "a=ssrc-group:") }
    var sourceParameters: [UInt32: [String: String]] = [:]
    for section in sendingSections {
      var sectionSSRCs: Set<UInt32> = []
      for value in section.values(after: "a=ssrc:") {
        let pair = value.split(separator: " ", maxSplits: 1)
        guard pair.count == 2, let ssrc = UInt32(pair[0]) else { continue }
        let parameter = pair[1].split(
          separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parameter.count == 2 else { continue }
        sectionSSRCs.insert(ssrc)
        sourceParameters[ssrc, default: [:]][String(parameter[0])] = String(parameter[1])
      }
      // Current WebRTC puts the msid at media level and only the cname on the
      // ssrc lines; the media-level value covers every ssrc the line sends.
      if let mediaMsid = section.value(after: "a=msid:") {
        for ssrc in sectionSSRCs where sourceParameters[ssrc]?["msid"] == nil {
          sourceParameters[ssrc, default: [:]]["msid"] = mediaMsid
        }
      }
    }
    // A group's members share one msid; a member with no lines of its own
    // (an RTX stream, say) inherits its partner's rather than being dropped.
    let groups = groupValues.compactMap { value -> (semantics: String, members: [UInt32])? in
      let parts = value.split(separator: " ")
      guard parts.count > 1 else { return nil }
      return (String(parts[0]), parts.dropFirst().compactMap { UInt32($0) })
    }
    for group in groups {
      guard
        let msid = group.members.compactMap({ sourceParameters[$0]?["msid"] }).first
      else { continue }
      for member in group.members where sourceParameters[member]?["msid"] == nil {
        sourceParameters[member, default: [:]]["msid"] = msid
      }
    }
    let advertised = sourceParameters.filter { $0.value["msid"] != nil }
    for ssrc in advertised.keys.sorted() {
      var attributes = ["ssrc": String(ssrc)]
      if let metadata {
        attributes["name"] = metadata.name
        if let videoType = metadata.videoType { attributes["videoType"] = videoType }
      }
      let msid = advertised[ssrc]?["msid"] ?? ""
      descriptionChildren.append(
        XMPPElement(
          name: "source",
          namespace: JingleParser.sourceNamespace,
          attributes: attributes,
          children: [XMPPElement(name: "parameter", attributes: ["name": "msid", "value": msid])]
        )
      )
    }
    for group in groups where group.members.allSatisfy({ advertised[$0] != nil }) {
      descriptionChildren.append(
        XMPPElement(
          name: "ssrc-group",
          namespace: JingleParser.sourceNamespace,
          attributes: ["semantics": group.semantics],
          children: group.members.map {
            XMPPElement(name: "source", attributes: ["ssrc": String($0)])
          }
        )
      )
    }

    let description = XMPPElement(
      name: "description",
      namespace: JingleParser.rtpNamespace,
      attributes: ["media": kind],
      children: descriptionChildren
    )
    let transport = try transportElement(media)
    return XMPPElement(
      name: "content",
      attributes: [
        "creator": "initiator",
        "name": kind,
        "senders": senders(direction: media.direction),
      ],
      children: [description, transport]
    )
  }

  private func transportElement(_ media: SDPMediaSection) throws -> XMPPElement {
    guard
      let ufrag = media.value(after: "a=ice-ufrag:"),
      let password = media.value(after: "a=ice-pwd:"),
      let fingerprintValue = media.value(after: "a=fingerprint:")
    else { throw JingleSDPError.incompleteTransport(content: media.mid ?? media.kind) }
    let fingerprintParts = fingerprintValue.split(separator: " ", maxSplits: 1)
    guard fingerprintParts.count == 2 else { throw JingleSDPError.malformedSDP }
    var children = [
      XMPPElement(
        name: "fingerprint",
        namespace: JingleParser.dtlsNamespace,
        attributes: [
          "hash": String(fingerprintParts[0]),
          "setup": media.value(after: "a=setup:") ?? "active",
        ],
        text: String(fingerprintParts[1])
      )
    ]
    children += media.values(after: "a=candidate:").compactMap {
      JingleCandidateCodec.element(sdp: $0)
    }
    return XMPPElement(
      name: "transport",
      namespace: JingleParser.iceNamespace,
      attributes: ["pwd": password, "ufrag": ufrag],
      children: children
    )
  }

  // The reference client's direction-to-senders mapping (`SDP.toJingle`).
  private func senders(direction: String) -> String {
    switch direction {
    case "sendonly": "initiator"
    case "recvonly": "responder"
    case "inactive": "none"
    default: "both"
    }
  }
}

private struct SDPDocument {
  var session: [String] = []
  var media: [SDPMediaSection] = []

  init(_ sdp: String, maximumBytes: Int = 1_048_576, maximumLines: Int = 10_000) throws {
    guard sdp.utf8.count <= maximumBytes else {
      throw JingleSDPError.sdpTooLarge(limit: maximumBytes)
    }
    let lines = sdp.split(whereSeparator: \.isNewline).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard lines.count <= maximumLines else {
      throw JingleSDPError.tooManySDPLines(limit: maximumLines)
    }
    guard lines.first == "v=0" else { throw JingleSDPError.malformedSDP }
    for line in lines where !line.isEmpty {
      if line.hasPrefix("m=") {
        media.append(try SDPMediaSection(mediaLine: line))
      } else if media.isEmpty {
        session.append(line)
      } else {
        media[media.count - 1].lines.append(line)
      }
    }
    guard !media.isEmpty else { throw JingleSDPError.malformedSDP }
  }
}

private struct SDPMediaSection {
  var kind: String
  var port: String
  var protocolName: String
  var formats: [String]
  var lines: [String] = []

  init(mediaLine: String) throws {
    let parts = mediaLine.dropFirst(2).split(separator: " ").map(String.init)
    guard parts.count >= 4 else { throw JingleSDPError.malformedSDP }
    kind = parts[0]
    port = parts[1]
    protocolName = parts[2]
    formats = Array(parts.dropFirst(3))
  }

  var mid: String? { value(after: "a=mid:") }

  var direction: String {
    ["sendrecv", "sendonly", "recvonly", "inactive"].first {
      lines.contains("a=\($0)")
    } ?? "sendrecv"
  }

  func value(after prefix: String) -> String? {
    lines.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
  }

  func values(after prefix: String) -> [String] {
    lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
  }
}
