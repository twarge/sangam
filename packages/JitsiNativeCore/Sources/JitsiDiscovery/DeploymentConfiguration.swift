import Foundation

public struct DeploymentConfiguration: Equatable, Codable, Sendable {
  public var baseURL: URL
  public var xmppWebSocketURL: URL
  public var xmppDomain: String
  public var anonymousDomain: String?
  public var mucDomain: String
  public var focusJID: String
  public var boshURL: URL?
  public var webSocketKeepAliveURL: URL?
  public var conferenceRequestURL: URL?
  public var prefersBOSH: Bool
  public var bridgeWebSocketURL: URL?

  public init(
    baseURL: URL,
    xmppWebSocketURL: URL,
    xmppDomain: String,
    anonymousDomain: String? = nil,
    mucDomain: String,
    focusJID: String,
    boshURL: URL? = nil,
    webSocketKeepAliveURL: URL? = nil,
    conferenceRequestURL: URL? = nil,
    prefersBOSH: Bool = false,
    bridgeWebSocketURL: URL? = nil
  ) throws {
    self.baseURL = baseURL
    self.xmppWebSocketURL = xmppWebSocketURL
    self.xmppDomain = xmppDomain
    self.anonymousDomain = anonymousDomain
    self.mucDomain = mucDomain
    self.focusJID = focusJID
    self.boshURL = boshURL
    self.webSocketKeepAliveURL = webSocketKeepAliveURL
    self.conferenceRequestURL = conferenceRequestURL
    self.prefersBOSH = prefersBOSH
    self.bridgeWebSocketURL = bridgeWebSocketURL
    try validate()
  }

  public static func inferred(from baseURL: URL) throws -> DeploymentConfiguration {
    guard let host = baseURL.host, !host.isEmpty else {
      throw DiscoveryError.invalidBaseURL
    }
    let websocket = try websocketURL(baseURL: baseURL, path: "/xmpp-websocket")
    return try DeploymentConfiguration(
      baseURL: baseURL,
      xmppWebSocketURL: websocket,
      xmppDomain: host,
      anonymousDomain: "guest.\(host)",
      mucDomain: "conference.\(host)",
      focusJID: "focus.\(host)"
    )
  }

  public func validate() throws {
    guard let host = baseURL.host, !host.isEmpty else {
      throw DiscoveryError.invalidBaseURL
    }
    let secureBase = baseURL.scheme?.lowercased() == "https"
    let localhostBase = baseURL.scheme?.lowercased() == "http" && host == "localhost"
    guard secureBase || localhostBase else {
      throw DiscoveryError.insecureURL(baseURL)
    }

    guard let webSocketHost = xmppWebSocketURL.host, !webSocketHost.isEmpty else {
      throw DiscoveryError.invalidWebSocketURL
    }
    let secureSocket = xmppWebSocketURL.scheme?.lowercased() == "wss"
    let localhostSocket =
      xmppWebSocketURL.scheme?.lowercased() == "ws"
      && webSocketHost == "localhost"
    guard secureSocket || localhostSocket else {
      throw DiscoveryError.insecureURL(xmppWebSocketURL)
    }
    if let boshURL {
      let secureBOSH = boshURL.scheme?.lowercased() == "https"
      let localhostBOSH = boshURL.scheme?.lowercased() == "http" && boshURL.host == "localhost"
      guard secureBOSH || localhostBOSH else { throw DiscoveryError.insecureURL(boshURL) }
    }
    guard
      !xmppDomain.isEmpty,
      anonymousDomain?.isEmpty != true,
      !mucDomain.isEmpty,
      !focusJID.isEmpty
    else {
      throw DiscoveryError.incompleteManifest
    }
  }

  private static func websocketURL(baseURL: URL, path: String) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw DiscoveryError.invalidBaseURL
    }
    components.scheme = baseURL.scheme?.lowercased() == "http" ? "ws" : "wss"
    components.path = path
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw DiscoveryError.invalidWebSocketURL }
    return url
  }
}

public enum DiscoveryError: Error, Equatable, Sendable {
  case invalidBaseURL
  case invalidWebSocketURL
  case insecureURL(URL)
  case incompleteManifest
  case responseTooLarge(limit: Int)
  case invalidResponse
  case httpStatus(Int)
}

extension DiscoveryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL: return "The Jitsi server URL is invalid."
    case .invalidWebSocketURL: return "The Jitsi XMPP WebSocket URL is invalid."
    case .insecureURL: return "The Jitsi server must use a secure connection."
    case .incompleteManifest: return "The native Jitsi deployment configuration is incomplete."
    case .responseTooLarge: return "The Jitsi deployment configuration is too large."
    case .invalidResponse: return "The Jitsi deployment configuration is invalid."
    case .httpStatus(let status): return "Jitsi discovery returned HTTP \(status)."
    }
  }
}
