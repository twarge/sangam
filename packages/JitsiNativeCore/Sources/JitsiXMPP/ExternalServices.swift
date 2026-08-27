import Foundation

/// One STUN or TURN server advertised by the deployment through XEP-0215
/// External Service Discovery.
///
/// Jitsi hands out time-limited TURN credentials this way rather than in
/// `config.js`, so a client that never asks has no relay to fall back on when
/// the videobridge's media port is unreachable.
public struct ExternalService: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case stun
    case stuns
    case turn
    case turns
  }

  public var kind: Kind
  public var host: String
  public var port: Int
  public var transport: String?
  public var username: String?
  public var password: String?
  public var isRestricted: Bool

  public init(
    kind: Kind,
    host: String,
    port: Int,
    transport: String? = nil,
    username: String? = nil,
    password: String? = nil,
    isRestricted: Bool = false
  ) {
    self.kind = kind
    self.host = host
    self.port = port
    self.transport = transport
    self.username = username
    self.password = password
    self.isRestricted = isRestricted
  }

  /// The ICE URL form WebRTC expects, e.g. `turns:host:5349?transport=tcp`.
  public var iceURL: String {
    var url = "\(kind.rawValue):\(host):\(port)"
    // Only TURN URIs take a transport parameter (RFC 7065). STUN URIs
    // (RFC 7064) do not — and deployments do advertise `transport` on
    // their STUN services (meet.jit.si does), which WebRTC then rejects as
    // a malformed URL, invalidating the entire ICE configuration.
    if kind == .turn || kind == .turns, let transport, !transport.isEmpty {
      url += "?transport=\(transport)"
    }
    return url
  }

  init?(element: XMPPElement) {
    guard
      element.name == "service",
      let type = element[attribute: "type"].flatMap(Kind.init(rawValue:)),
      let host = element[attribute: "host"], !host.isEmpty,
      let port = element[attribute: "port"].flatMap(Int.init),
      (1...65_535).contains(port)
    else { return nil }
    kind = type
    self.host = host
    self.port = port
    transport = element[attribute: "transport"]
    username = element[attribute: "username"]
    password = element[attribute: "password"]
    isRestricted = element[attribute: "restricted"] == "1"
  }
}

public enum ExternalServiceDiscoveryError: Error, Equatable, Sendable {
  case invalidResponse
}

extension XMPPConnection {
  public static let externalServicesNamespace = "urn:xmpp:extdisco:2"

  /// Asks the deployment for its STUN and TURN servers.
  ///
  /// A deployment that does not implement XEP-0215 answers with an IQ error;
  /// callers should treat that as "no relays offered" rather than a failure to
  /// join, because direct connectivity may still work.
  public func discoverExternalServices(
    domain: String,
    id: String = "sangam-extdisco-\(UUID().uuidString.lowercased())",
    maximumUnmatchedFrames: Int = 128
  ) async throws -> [ExternalService] {
    let query = XMPPElement(
      name: "iq",
      attributes: ["type": "get", "id": id, "to": domain],
      children: [
        XMPPElement(name: "services", namespace: Self.externalServicesNamespace)
      ]
    )
    let response = try await request(
      query,
      id: id,
      maximumUnmatchedFrames: maximumUnmatchedFrames
    )
    guard
      let services = response.child(
        named: "services",
        namespace: Self.externalServicesNamespace
      )
    else {
      throw ExternalServiceDiscoveryError.invalidResponse
    }
    return services.children.compactMap(ExternalService.init(element:))
  }
}
