import Foundation
import JitsiXMPP

public enum JingleParsingError: Error, Equatable, Sendable {
  case notJingle
  case missingAction
  case unsupportedAction(String)
  case missingSessionID
  case missingContentName
  case missingMedia
  case invalidNumber(field: String, value: String)
}

public struct JingleParser: Sendable {
  public static let jingleNamespace = "urn:xmpp:jingle:1"
  public static let rtpNamespace = "urn:xmpp:jingle:apps:rtp:1"
  public static let sourceNamespace = "urn:xmpp:jingle:apps:rtp:ssma:0"
  public static let iceNamespace = "urn:xmpp:jingle:transports:ice-udp:1"
  public static let dtlsNamespace = "urn:xmpp:jingle:apps:dtls:0"
  public static let headerExtensionNamespace = "urn:xmpp:jingle:apps:rtp:rtp-hdrext:0"
  public static let feedbackNamespace = "urn:xmpp:jingle:apps:rtp:rtcp-fb:0"
  public static let groupingNamespace = "urn:xmpp:jingle:apps:grouping:0"
  public static let colibriNamespace = "http://jitsi.org/protocol/colibri"
  public static let jitsiMeetNamespace = "http://jitsi.org/jitmeet"

  public init() {}

  public func parse(_ root: XMPPElement) throws -> JingleSessionDescription {
    let jingle: XMPPElement
    if root.name == "jingle" && root.namespace == Self.jingleNamespace {
      jingle = root
    } else if let child = root.child(named: "jingle", namespace: Self.jingleNamespace) {
      jingle = child
    } else {
      throw JingleParsingError.notJingle
    }

    guard let actionValue = jingle[attribute: "action"] else {
      throw JingleParsingError.missingAction
    }
    guard let action = JingleAction(rawValue: actionValue) else {
      throw JingleParsingError.unsupportedAction(actionValue)
    }
    guard let sessionID = jingle[attribute: "sid"], !sessionID.isEmpty else {
      throw JingleParsingError.missingSessionID
    }

    let contents = try jingle.children(named: "content", namespace: Self.jingleNamespace).map(
      parseContent)
    return JingleSessionDescription(
      action: action,
      sessionID: sessionID,
      initiator: jingle[attribute: "initiator"],
      contents: expandingJSONSources(
        into: contents,
        from: jingle.child(named: "json-message", namespace: Self.jitsiMeetNamespace)),
      bundle: jingle.child(named: "group", namespace: Self.groupingNamespace)?
        .children(named: "content", namespace: Self.groupingNamespace)
        .compactMap { $0[attribute: "name"] } ?? []
    )
  }

  /// Expands Jitsi's JSON-encoded remote sources into the parsed contents,
  /// mirroring lib-jitsi-meet's `expandSourcesFromJson`.
  ///
  /// A source-name-signalling deployment does not put remote `<source>`
  /// elements in the RTP description; it lists them in a `<json-message>`:
  /// `{"sources":{"<owner>":[[videoSources],[videoGroups],[audioSources],
  /// [audioGroups]]}}` where each source is `{s:ssrc,n:name,m:msid,v:videoType}`
  /// and each group is `[semantics, ssrc…]` with "f" = FID and "s" = SIM. The
  /// four tuple positions are positional — nothing about a source itself says
  /// which media it belongs to. Every source of every owner is added to the
  /// matching content (created if the stanza carried none, as a source-add
  /// does); the SDP translation later gives each its own media line.
  private func expandingJSONSources(
    into contents: [JingleContent],
    from jsonMessage: XMPPElement?
  ) -> [JingleContent] {
    guard
      let text = jsonMessage?.text, !text.isEmpty,
      let data = text.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sourcesByOwner = root["sources"] as? [String: Any]
    else { return contents }

    var result = contents
    // The reference client creates both RTP descriptions up front; a
    // source-add's jingle element has no contents of its own.
    func descriptionIndex(for media: String) -> Int {
      if let index = result.firstIndex(where: { $0.description?.media == media }) {
        return index
      }
      result.append(
        JingleContent(name: media, description: RTPDescription(media: media, rtcpMux: false))
      )
      return result.count - 1
    }
    let audioIndex = descriptionIndex(for: "audio")
    let videoIndex = descriptionIndex(for: "video")

    func ssrcValue(_ value: Any?) -> UInt32? {
      let number: UInt64?
      if let numeric = value as? NSNumber {
        number = numeric.int64Value >= 0 ? numeric.uint64Value : nil
      } else {
        number = (value as? String).flatMap(UInt64.init)
      }
      guard let number, number <= UInt64(UInt32.max) else { return nil }
      return UInt32(number)
    }

    func sources(_ value: Any?, owner: String, isVideo: Bool) -> [RTPSource] {
      (value as? [Any] ?? []).compactMap { item in
        guard let object = item as? [String: Any], let ssrc = ssrcValue(object["s"]) else {
          return nil
        }
        // Jicofo only marks desktop sources; an unmarked video source is a
        // camera, and audio sources carry no video type at all.
        let videoType: String? =
          if !isVideo {
            nil
          } else if let value = object["v"], !(value is NSNull),
            (value as? NSNumber)?.boolValue != false
          {
            "desktop"
          } else {
            "camera"
          }
        return RTPSource(
          ssrc: ssrc,
          name: object["n"] as? String,
          videoType: videoType,
          owner: owner,
          parameters: (object["m"] as? String).map { ["msid": $0] } ?? [:]
        )
      }
    }

    func groups(_ value: Any?) -> [RTPSourceGroup] {
      (value as? [Any] ?? []).compactMap { item in
        guard let group = item as? [Any], let short = group.first as? String else { return nil }
        let semantics: String? =
          switch short {
          case "f": "FID"
          case "s": "SIM"
          default: nil
          }
        guard let semantics else { return nil }
        let ssrcs = group.dropFirst().compactMap(ssrcValue)
        guard !ssrcs.isEmpty else { return nil }
        return RTPSourceGroup(semantics: semantics, sources: ssrcs)
      }
    }

    // Iterate owners in the order the JSON lists them, as the reference client
    // does; a dictionary would make media-line numbering nondeterministic.
    for owner in Self.orderedOwners(inSourcesJSON: text, known: Set(sourcesByOwner.keys)) {
      // The tuple positions are: video sources, video ssrc-groups, audio
      // sources, audio ssrc-groups.
      guard let tuple = sourcesByOwner[owner] as? [Any] else { continue }
      func element(_ index: Int) -> Any? { tuple.count > index ? tuple[index] : nil }
      result[videoIndex].description?.sources
        .append(contentsOf: sources(element(0), owner: owner, isVideo: true))
      result[videoIndex].description?.sourceGroups.append(contentsOf: groups(element(1)))
      result[audioIndex].description?.sources
        .append(contentsOf: sources(element(2), owner: owner, isVideo: false))
      result[audioIndex].description?.sourceGroups.append(contentsOf: groups(element(3)))
    }
    return result
  }

  /// The top-level keys of the `"sources"` object in `text`, in document order.
  /// `JSONSerialization` hands back an unordered dictionary, but which owner
  /// comes first decides which source shares the sending media line, so the
  /// original order matters. Falls back to the unordered keys for any owner the
  /// scan misses.
  private static func orderedOwners(inSourcesJSON text: String, known: Set<String>) -> [String] {
    var ordered: [String] = []
    var seen: Set<String> = []
    var depth = 0
    var inString = false
    var escaped = false
    var currentKey = ""
    var collectingKey = false
    var keyPending = false
    guard let start = text.range(of: "\"sources\"")?.upperBound else {
      return known.sorted()
    }
    scan: for character in text[start...] {
      if inString {
        if escaped {
          escaped = false
          if collectingKey { currentKey.append(character) }
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
          if collectingKey {
            collectingKey = false
            keyPending = true
          }
        } else if collectingKey {
          currentKey.append(character)
        }
        continue
      }
      switch character {
      case "\"":
        inString = true
        if depth == 1, !keyPending {
          collectingKey = true
          currentKey = ""
        }
      case ":":
        if depth == 1, keyPending {
          keyPending = false
          if known.contains(currentKey), seen.insert(currentKey).inserted {
            ordered.append(currentKey)
          }
        }
      case ",":
        if depth == 1 { keyPending = false }
      case "{", "[":
        depth += 1
      case "}", "]":
        depth -= 1
        if depth <= 0 { break scan }
      default:
        break
      }
    }
    ordered.append(contentsOf: known.subtracting(seen).sorted())
    return ordered
  }

  private func parseContent(_ element: XMPPElement) throws -> JingleContent {
    guard let name = element[attribute: "name"], !name.isEmpty else {
      throw JingleParsingError.missingContentName
    }

    return try JingleContent(
      name: name,
      creator: element[attribute: "creator"],
      senders: element[attribute: "senders"],
      description: element.child(named: "description", namespace: Self.rtpNamespace).map(
        parseDescription
      ),
      transport: element.child(named: "transport", namespace: Self.iceNamespace).map(
        parseTransport
      )
    )
  }

  private func parseDescription(_ element: XMPPElement) throws -> RTPDescription {
    guard let media = element[attribute: "media"], !media.isEmpty else {
      throw JingleParsingError.missingMedia
    }

    return try RTPDescription(
      media: media,
      payloadTypes: element.children(named: "payload-type", namespace: Self.rtpNamespace).map(
        parsePayloadType
      ),
      headerExtensions: element.children(
        named: "rtp-hdrext",
        namespace: Self.headerExtensionNamespace
      ).compactMap(parseHeaderExtension),
      sources: element.children(named: "source", namespace: Self.sourceNamespace).map(parseSource),
      sourceGroups: try element.children(
        named: "ssrc-group",
        namespace: Self.sourceNamespace
      ).map(parseSourceGroup),
      rtcpMux: element.child(named: "rtcp-mux", namespace: Self.rtpNamespace) != nil,
      extmapAllowMixed: element.child(
        named: "extmap-allow-mixed",
        namespace: Self.headerExtensionNamespace
      ) != nil
    )
  }

  private func parsePayloadType(_ element: XMPPElement) throws -> RTPPayloadType {
    let id = try requiredInt(element, attribute: "id")
    var parameters: [String: String] = [:]
    for parameter in element.children(named: "parameter", namespace: Self.rtpNamespace) {
      if let name = parameter[attribute: "name"], let value = parameter[attribute: "value"] {
        parameters[name] = value
      }
    }
    return RTPPayloadType(
      id: id,
      name: element[attribute: "name"],
      clockRate: optionalInt(element, attribute: "clockrate"),
      channels: optionalInt(element, attribute: "channels"),
      parameters: parameters,
      feedback: element.children(named: "rtcp-fb", namespace: Self.feedbackNamespace)
        .compactMap { feedback in
          guard let type = feedback[attribute: "type"] else { return nil }
          return RTPFeedback(type: type, subtype: feedback[attribute: "subtype"])
        }
    )
  }

  private func parseHeaderExtension(_ element: XMPPElement) -> RTPHeaderExtension? {
    guard
      let idValue = element[attribute: "id"],
      let id = Int(idValue),
      let uri = element[attribute: "uri"]
    else { return nil }
    return RTPHeaderExtension(id: id, uri: uri)
  }

  private func parseSource(_ element: XMPPElement) throws -> RTPSource {
    guard let value = element[attribute: "ssrc"], let ssrc = UInt32(value) else {
      throw JingleParsingError.invalidNumber(
        field: "ssrc",
        value: element[attribute: "ssrc"] ?? ""
      )
    }
    var parameters: [String: String] = [:]
    for parameter in element.children(named: "parameter", namespace: Self.sourceNamespace) {
      if let name = parameter[attribute: "name"], let value = parameter[attribute: "value"] {
        parameters[name] = value
      }
    }
    // The reference client signals the source name and video type as XML
    // attributes; parameter form is tolerated for older stanzas.
    return RTPSource(
      ssrc: ssrc,
      name: element[attribute: "name"] ?? parameters["name"],
      videoType: element[attribute: "videoType"] ?? parameters["videoType"],
      owner: element.child(named: "ssrc-info", namespace: Self.jitsiMeetNamespace)?[
        attribute: "owner"],
      parameters: parameters
    )
  }

  private func parseSourceGroup(_ element: XMPPElement) throws -> RTPSourceGroup {
    let sources = try element.children(named: "source", namespace: Self.sourceNamespace).map {
      source -> UInt32 in
      guard let value = source[attribute: "ssrc"], let ssrc = UInt32(value) else {
        throw JingleParsingError.invalidNumber(
          field: "ssrc",
          value: source[attribute: "ssrc"] ?? ""
        )
      }
      return ssrc
    }
    return RTPSourceGroup(semantics: element[attribute: "semantics"] ?? "", sources: sources)
  }

  private func parseTransport(_ element: XMPPElement) throws -> ICETransport {
    let candidates = element.children(named: "candidate", namespace: Self.iceNamespace).map {
      candidate in
      ICECandidate(
        foundation: candidate[attribute: "foundation"],
        component: optionalInt(candidate, attribute: "component"),
        protocolName: candidate[attribute: "protocol"],
        priority: optionalUInt64(candidate, attribute: "priority"),
        ip: candidate[attribute: "ip"],
        port: optionalInt(candidate, attribute: "port"),
        type: candidate[attribute: "type"],
        generation: optionalInt(candidate, attribute: "generation"),
        relatedAddress: candidate[attribute: "rel-addr"],
        relatedPort: optionalInt(candidate, attribute: "rel-port"),
        tcpType: candidate[attribute: "tcptype"]
      )
    }
    let fingerprint = element.child(named: "fingerprint", namespace: Self.dtlsNamespace).map {
      DTLSFingerprint(
        hash: $0[attribute: "hash"] ?? "",
        setup: $0[attribute: "setup"],
        value: $0.text
      )
    }
    return ICETransport(
      usernameFragment: element[attribute: "ufrag"],
      password: element[attribute: "pwd"],
      candidates: candidates,
      fingerprint: fingerprint,
      bridgeWebSocketURL: element.child(
        named: "web-socket", namespace: Self.colibriNamespace)?[attribute: "url"]
    )
  }

  private func requiredInt(_ element: XMPPElement, attribute: String) throws -> Int {
    guard let value = element[attribute: attribute], let number = Int(value) else {
      throw JingleParsingError.invalidNumber(
        field: attribute,
        value: element[attribute: attribute] ?? ""
      )
    }
    return number
  }

  private func optionalInt(_ element: XMPPElement, attribute: String) -> Int? {
    element[attribute: attribute].flatMap(Int.init)
  }

  private func optionalUInt64(_ element: XMPPElement, attribute: String) -> UInt64? {
    element[attribute: attribute].flatMap(UInt64.init)
  }
}
