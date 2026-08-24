import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct DiscoveryClient: Sendable {
  public typealias Loader = @Sendable (URL) async throws -> (Data, HTTPURLResponse)

  public var maximumResponseBytes: Int
  public var maximumConfigResponseBytes: Int
  private let loader: Loader

  public init(
    maximumResponseBytes: Int = 65_536,
    maximumConfigResponseBytes: Int = 1_048_576,
    loader: @escaping Loader = DiscoveryClient.defaultLoader
  ) {
    self.maximumResponseBytes = maximumResponseBytes
    self.maximumConfigResponseBytes = maximumConfigResponseBytes
    self.loader = loader
  }

  public func discover(baseURL: URL) async throws -> DeploymentConfiguration {
    let manifestURL = baseURL.appending(path: "gafsaf-native.json")
    let (data, response) = try await loader(manifestURL)

    if (200..<300).contains(response.statusCode), Self.looksLikeJSON(data) {
      guard data.count <= maximumResponseBytes else {
        throw DiscoveryError.responseTooLarge(limit: maximumResponseBytes)
      }
      return try configuration(fromManifest: data, baseURL: baseURL)
    }

    return try await discoverStandardConfiguration(baseURL: baseURL)
  }

  private func configuration(fromManifest data: Data, baseURL: URL) throws
    -> DeploymentConfiguration
  {

    let manifest: Manifest
    do {
      manifest = try JSONDecoder().decode(Manifest.self, from: data)
    } catch {
      throw DiscoveryError.invalidResponse
    }
    guard let websocketURL = URL(string: manifest.xmppWebSocketURL) else {
      throw DiscoveryError.invalidResponse
    }
    let bridgeURL: URL?
    if let value = manifest.bridgeWebSocketURL {
      guard let parsedURL = URL(string: value) else { throw DiscoveryError.invalidResponse }
      bridgeURL = parsedURL
    } else {
      bridgeURL = nil
    }

    return try DeploymentConfiguration(
      baseURL: baseURL,
      xmppWebSocketURL: websocketURL,
      xmppDomain: manifest.xmppDomain,
      anonymousDomain: manifest.anonymousDomain,
      mucDomain: manifest.mucDomain,
      focusJID: manifest.focusJID,
      boshURL: manifest.boshURL.flatMap(URL.init(string:)),
      webSocketKeepAliveURL: manifest.webSocketKeepAliveURL.flatMap(URL.init(string:)),
      conferenceRequestURL: manifest.conferenceRequestURL.flatMap(URL.init(string:)),
      prefersBOSH: manifest.preferBOSH ?? false,
      bridgeWebSocketURL: bridgeURL
    )
  }

  private func discoverStandardConfiguration(baseURL: URL) async throws
    -> DeploymentConfiguration
  {
    let configURL = baseURL.appending(path: "config.js")
    let (data, response) = try await loader(configURL)
    guard (200..<300).contains(response.statusCode) else {
      return try DeploymentConfiguration.inferred(from: baseURL)
    }
    guard data.count <= maximumConfigResponseBytes else {
      throw DiscoveryError.responseTooLarge(limit: maximumConfigResponseBytes)
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw DiscoveryError.invalidResponse
    }
    return try StandardJitsiConfigParser().configuration(from: source, baseURL: baseURL)
  }

  private static func looksLikeJSON(_ data: Data) -> Bool {
    guard let text = String(data: data.prefix(256), encoding: .utf8) else { return false }
    return text.drop(while: { $0.isWhitespace }).first == "{"
  }

  public static func defaultLoader(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw DiscoveryError.invalidResponse
    }
    return (data, httpResponse)
  }

  private struct Manifest: Decodable {
    var xmppWebSocketURL: String
    var xmppDomain: String
    var anonymousDomain: String?
    var mucDomain: String
    var focusJID: String
    var boshURL: String?
    var webSocketKeepAliveURL: String?
    var conferenceRequestURL: String?
    var preferBOSH: Bool?
    var bridgeWebSocketURL: String?
  }
}

struct StandardJitsiConfigParser: Sendable {
  func configuration(from source: String, baseURL: URL) throws -> DeploymentConfiguration {
    guard let domain = value(named: "domain", in: source) else {
      return try DeploymentConfiguration.inferred(from: baseURL)
    }
    let inferred = try DeploymentConfiguration.inferred(from: baseURL)
    let websocketValue = value(named: "websocket", in: source)
    let boshURL = value(named: "bosh", in: source).flatMap(URL.init(string:))
    let websocketURL: URL
    if let websocket = websocketValue,
      let parsed = URL(string: websocket)
    {
      websocketURL = parsed
    } else {
      websocketURL = inferred.xmppWebSocketURL
    }
    return try DeploymentConfiguration(
      baseURL: baseURL,
      xmppWebSocketURL: websocketURL,
      xmppDomain: domain,
      anonymousDomain: value(named: "anonymousdomain", in: source),
      mucDomain: value(named: "muc", in: source) ?? "conference.\(domain)",
      focusJID: value(named: "focus", in: source) ?? "focus.\(domain)",
      boshURL: boshURL,
      webSocketKeepAliveURL: value(named: "websocketKeepAliveUrl", in: source)
        .flatMap(URL.init(string:)),
      conferenceRequestURL: value(named: "conferenceRequestUrl", in: source)
        .flatMap(URL.init(string:)),
      // WebSocket carries pushed stanzas immediately, while BOSH can only
      // deliver them when a long poll comes back — a deployment that does not
      // release held polls early adds its whole hold interval to every
      // incoming message. So prefer WebSocket wherever the deployment actually
      // advertises one, and fall back to BOSH otherwise: an inferred WebSocket
      // URL is a guess, and on a deployment that does not proxy that path it
      // is simply wrong.
      prefersBOSH: flag(named: "preferBosh", in: source)
        ?? (boshURL != nil && websocketValue == nil)
    )
  }

  /// Reads an unquoted boolean, which `value(named:)` cannot: it reports the
  /// quoted literals on a line, and `preferBosh: true` has none.
  private func flag(named name: String, in source: String) -> Bool? {
    let prefix = "\(name):"
    for rawLine in source.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("//") else { continue }
      let compact = line.replacingOccurrences(of: " ", with: "")
      guard compact.hasPrefix(prefix) else { continue }
      let remainder = compact.dropFirst(prefix.count).prefix { $0 != "," }
      if remainder == "true" { return true }
      if remainder == "false" { return false }
    }
    return nil
  }

  private func value(named name: String, in source: String) -> String? {
    let prefix = "\(name):"
    for rawLine in source.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("//") else { continue }
      let compact = line.replacingOccurrences(of: " ", with: "")
      guard compact.hasPrefix(prefix) else { continue }
      let literals = quotedLiterals(in: line)
      if !literals.isEmpty { return literals.joined() }
    }
    return nil
  }

  private func quotedLiterals(in line: String) -> [String] {
    var result: [String] = []
    var quote: Character?
    var value = ""
    var escaped = false
    for character in line {
      if let activeQuote = quote {
        if escaped {
          value.append(character)
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == activeQuote {
          result.append(value)
          value = ""
          quote = nil
        } else {
          value.append(character)
        }
      } else if character == "'" || character == "\"" {
        quote = character
      }
    }
    return result
  }
}
