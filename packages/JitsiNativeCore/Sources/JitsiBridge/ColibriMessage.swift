import Foundation

public enum ColibriMessage: Equatable, Sendable {
  case dominantSpeaker(endpointID: String?)
  case endpointConnectivity(endpointID: String, active: Bool)
  case lastNChanged(current: [String], entering: [String], leaving: [String])
  case sourceVideoType(sourceName: String, videoType: String)
  case endpointMessage(from: String?, to: String?, payload: JSONValue?)
  /// The sources the bridge currently forwards to this client. A source
  /// missing here is a source whose media simply stops arriving — the single
  /// most direct explanation the bridge ever gives for a frozen tile.
  case forwardedSources([String])
  /// The bridge's cap for one of this client's outgoing sources. `maxHeight`
  /// 0 means no receiver has asked for the source, so the bridge will not
  /// forward it at all.
  case senderSourceConstraints(sourceName: String, maxHeight: Int)
  /// Older bridges send one overall sending cap instead of per-source ones.
  case senderVideoConstraints(idealHeight: Int)
  case serverHello(version: String?)
  /// The bridge's downlink bandwidth estimate for this client.
  case connectionStats(estimatedDownlinkBandwidthBps: Double?)
  /// An SSRC-rewriting bridge remapped which stream carries which source.
  /// A client that ignores this listens to stale SSRCs and shows freezes.
  case sourcesRemapped(media: String, mappedSources: String)
  case unknown(type: String)
}

public enum JSONValue: Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null
}

public struct VideoConstraint: Equatable, Codable, Sendable {
  /// Matches the Jitsi Videobridge wire key. The bridge forwards a source only
  /// up to this height; a source left with height 0 is not forwarded at all.
  public var maxHeight: Int

  public init(maxHeight: Int) {
    self.maxHeight = max(0, maxHeight)
  }
}

/// The receiver video constraints message a client sends the videobridge over
/// the colibri bridge channel. The schema mirrors lib-jitsi-meet's
/// `IReceiverVideoConstraints` exactly (see `ReceiveVideoController.ts`): only
/// `lastN`, `assumedBandwidthBps`, `defaultConstraints` and the per-source
/// `constraints` map are understood by a current bridge. The older
/// `selectedSources`/`onStageSources` fields were removed upstream and a modern
/// videobridge ignores them, so naming sources there forwarded nothing. `lastN`
/// = -1 requests every remote source; `defaultConstraints.maxHeight` caps any
/// source not individually listed. Unset fields are omitted, as the reference
/// client omits them.
public struct ReceiverVideoConstraints: Equatable, Sendable {
  public var lastN: Int?
  public var assumedBandwidthBps: Int?
  public var defaultConstraints: VideoConstraint?
  public var constraints: [String: VideoConstraint]

  public init(
    lastN: Int? = nil,
    assumedBandwidthBps: Int? = nil,
    defaultConstraints: VideoConstraint? = nil,
    constraints: [String: VideoConstraint] = [:]
  ) {
    self.lastN = lastN.map { max(-1, $0) }
    self.assumedBandwidthBps = assumedBandwidthBps
    self.defaultConstraints = defaultConstraints
    self.constraints = constraints
  }

  public func encoded() throws -> Data {
    let payload = EncodableConstraints(
      colibriClass: "ReceiverVideoConstraints",
      lastN: lastN,
      assumedBandwidthBps: assumedBandwidthBps,
      defaultConstraints: defaultConstraints,
      constraints: constraints.isEmpty ? nil : constraints
    )
    return try JSONEncoder().encode(payload)
  }

  private struct EncodableConstraints: Codable {
    var colibriClass: String
    var lastN: Int?
    var assumedBandwidthBps: Int?
    var defaultConstraints: VideoConstraint?
    var constraints: [String: VideoConstraint]?
  }
}

/// An emoji reaction broadcast to the whole meeting, encoded exactly as the
/// web app sends it: an EndpointMessage with the `endpoint-reaction` payload.
public struct ReactionEndpointMessage: Equatable, Sendable {
  /// Reaction names from the shared jitsi-meet vocabulary: like, clap, laugh,
  /// surprised, boo, silence, love.
  public var reactions: [String]
  public var timestampMilliseconds: Int

  public init(reactions: [String], timestampMilliseconds: Int) {
    self.reactions = reactions
    self.timestampMilliseconds = timestampMilliseconds
  }

  public func encoded() throws -> Data {
    try JSONEncoder().encode(
      Envelope(
        colibriClass: "EndpointMessage",
        to: "",
        msgPayload: Payload(
          name: "endpoint-reaction",
          reactions: reactions,
          timestamp: timestampMilliseconds
        )
      )
    )
  }

  private struct Envelope: Codable {
    var colibriClass: String
    var to: String
    var msgPayload: Payload
  }

  private struct Payload: Codable {
    var name: String
    var reactions: [String]
    var timestamp: Int
  }
}

public struct ColibriParser: Sendable {
  public var maximumBytes: Int
  public var maximumDepth: Int
  public var maximumNodes: Int

  public init(maximumBytes: Int = 262_144, maximumDepth: Int = 32, maximumNodes: Int = 10_000) {
    self.maximumBytes = maximumBytes
    self.maximumDepth = maximumDepth
    self.maximumNodes = maximumNodes
  }

  public func parse(_ data: Data) throws -> ColibriMessage {
    guard data.count <= maximumBytes else {
      throw ColibriParsingError.documentTooLarge(limit: maximumBytes)
    }
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    var nodeCount = 0
    try validate(object, depth: 0, nodeCount: &nodeCount)
    guard let dictionary = object as? [String: Any] else {
      throw ColibriParsingError.expectedObject
    }
    guard let type = dictionary["colibriClass"] as? String, !type.isEmpty else {
      throw ColibriParsingError.missingClass
    }

    switch type {
    case "DominantSpeakerEndpointChangeEvent":
      return .dominantSpeaker(endpointID: dictionary["dominantSpeakerEndpoint"] as? String)
    case "EndpointConnectivityStatusChangeEvent":
      guard
        let endpoint = dictionary["endpoint"] as? String,
        let active = dictionary["active"] as? Bool
      else { throw ColibriParsingError.missingField(type: type) }
      return .endpointConnectivity(endpointID: endpoint, active: active)
    case "LastNEndpointsChangeEvent":
      return .lastNChanged(
        current: dictionary["lastNEndpoints"] as? [String] ?? [],
        entering: dictionary["endpointsEnteringLastN"] as? [String] ?? [],
        leaving: dictionary["endpointsLeavingLastN"] as? [String] ?? []
      )
    case "SourceVideoTypeMessage":
      guard
        let sourceName = dictionary["sourceName"] as? String,
        let videoType = dictionary["videoType"] as? String
      else { throw ColibriParsingError.missingField(type: type) }
      return .sourceVideoType(sourceName: sourceName, videoType: videoType)
    case "EndpointMessage":
      return .endpointMessage(
        from: dictionary["from"] as? String,
        to: dictionary["to"] as? String,
        payload: dictionary["msgPayload"].map(JSONValue.init(any:))
      )
    // Current bridges say "ForwardedSources"; older ones append "ChangeEvent".
    case "ForwardedSources", "ForwardedSourcesChangeEvent":
      return .forwardedSources(dictionary["forwardedSources"] as? [String] ?? [])
    case "SenderSourceConstraints":
      guard
        let sourceName = dictionary["sourceName"] as? String,
        let maxHeight = dictionary["maxHeight"] as? NSNumber
      else { throw ColibriParsingError.missingField(type: type) }
      return .senderSourceConstraints(sourceName: sourceName, maxHeight: maxHeight.intValue)
    case "SenderVideoConstraints":
      guard
        let constraints = dictionary["videoConstraints"] as? [String: Any],
        let idealHeight = constraints["idealHeight"] as? NSNumber
      else { throw ColibriParsingError.missingField(type: type) }
      return .senderVideoConstraints(idealHeight: idealHeight.intValue)
    case "ServerHello":
      return .serverHello(version: (dictionary["version"]).map { "\($0)" })
    case "ConnectionStats":
      return .connectionStats(
        estimatedDownlinkBandwidthBps:
          (dictionary["estimatedDownlinkBandwidth"] as? NSNumber)?.doubleValue
      )
    case "VideoSourcesMap", "AudioSourcesMap":
      return .sourcesRemapped(
        media: type == "VideoSourcesMap" ? "video" : "audio",
        mappedSources: String(describing: dictionary["mappedSources"] ?? "?")
      )
    default:
      return .unknown(type: type)
    }
  }

  private func validate(_ value: Any, depth: Int, nodeCount: inout Int) throws {
    guard depth <= maximumDepth else {
      throw ColibriParsingError.nestingTooDeep(limit: maximumDepth)
    }
    nodeCount += 1
    guard nodeCount <= maximumNodes else {
      throw ColibriParsingError.tooManyNodes(limit: maximumNodes)
    }
    if let dictionary = value as? [String: Any] {
      for child in dictionary.values {
        try validate(child, depth: depth + 1, nodeCount: &nodeCount)
      }
    } else if let array = value as? [Any] {
      for child in array {
        try validate(child, depth: depth + 1, nodeCount: &nodeCount)
      }
    }
  }
}

public enum ColibriParsingError: Error, Equatable, Sendable {
  case documentTooLarge(limit: Int)
  case expectedObject
  case missingClass
  case missingField(type: String)
  case nestingTooDeep(limit: Int)
  case tooManyNodes(limit: Int)
}

extension JSONValue {
  fileprivate init(any: Any) {
    switch any {
    case let value as String:
      self = .string(value)
    case let value as Bool:
      self = .bool(value)
    case let value as NSNumber:
      self = .number(value.doubleValue)
    case let value as [String: Any]:
      self = .object(value.mapValues(JSONValue.init(any:)))
    case let value as [Any]:
      self = .array(value.map(JSONValue.init(any:)))
    default:
      self = .null
    }
  }
}
