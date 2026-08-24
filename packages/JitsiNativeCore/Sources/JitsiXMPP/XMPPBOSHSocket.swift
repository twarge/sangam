import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum XMPPBOSHError: Error, Equatable, Sendable {
  case invalidResponse
  case httpStatus(Int)
  case responseTooLarge(limit: Int)
  case missingSessionID
  case terminated(String?)
}

extension XMPPBOSHError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidResponse: return "The Jitsi BOSH endpoint returned an invalid response."
    case .httpStatus(let status): return "The Jitsi BOSH endpoint returned HTTP \(status)."
    case .responseTooLarge: return "The Jitsi BOSH response exceeded the safety limit."
    case .missingSessionID: return "The Jitsi BOSH endpoint did not create a session."
    case .terminated(let reason):
      return "The Jitsi BOSH session ended: \(reason ?? "unknown reason")."
    }
  }
}

/// Presents an XMPP-framing socket interface over XEP-0206 BOSH.
public actor URLSessionXMPPBOSHSocket: XMPPTextSocket {
  public typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  /// Seconds the server may hold a poll open before answering it empty.
  ///
  /// This has to stay meaningfully below `requestTimeout`. When the two are
  /// equal the transport races itself: an idle conference reaches the server's
  /// hold limit at the same moment URLSession abandons the request, and the
  /// connection dies with a spurious timeout instead of an empty poll.
  ///
  /// It is also an upper bound on how late an incoming stanza can be. A server
  /// is supposed to answer a held poll as soon as it has something to send,
  /// but not all deployments do, and on those the hold interval is added to
  /// every pushed message. Hence a value far below the sixty seconds BOSH
  /// clients traditionally ask for: signalling latency matters more here than
  /// saving a few requests per minute.
  static let holdSeconds = 15

  /// How long a single BOSH request may take before URLSession gives up.
  static let requestTimeout: TimeInterval = 55

  /// A `hold='1'` session permits `hold + 1` simultaneous requests: one the
  /// server may hold open, plus one carrying payload.
  static let maximumOutstandingRequests = 2

  /// Teardown is best effort. A conference that is already over must not keep
  /// a caller — or the join screen behind it — waiting on the network.
  static let terminateTimeout: TimeInterval = 3

  private let url: URL
  private let domain: String
  private let maximumResponseBytes: Int
  private let preflightURL: URL?
  private let loader: Loader
  private var sessionID: String?
  private var rid = UInt64.random(in: 1_000_000_000...9_000_000_000)
  private var pending: [XMPPElement] = []
  private var closed = false

  /// Stanzas waiting for the next request body. Bursts — a round of trickled
  /// ICE candidates, say — are coalesced into one POST instead of one each.
  private var outbox: [String] = []

  /// Requests currently on the wire, oldest first.
  ///
  /// A `hold='1'` session allows two. Creating a fresh poll per send, as this
  /// type used to, multiplies a burst of stanzas into twice as many overlapping
  /// requests; their request IDs then reach the server far enough out of order
  /// to fall outside its window, and the session is dropped with
  /// `item-not-found`.
  private var outstanding: [Task<Void, Error>] = []

  public init(
    url: URL,
    domain: String,
    preflightURL: URL? = nil,
    maximumResponseBytes: Int = 1_048_576,
    loader: @escaping Loader = URLSessionXMPPBOSHSocket.defaultLoader
  ) {
    self.url = url
    self.domain = domain
    self.preflightURL = preflightURL
    self.maximumResponseBytes = maximumResponseBytes
    self.loader = loader
  }

  public func start() async throws {
    if let preflightURL { _ = try await URLSession.shared.data(from: preflightURL) }
  }

  public func send(_ text: String) async throws {
    if text.contains("<open ") || text.hasPrefix("<open") {
      if sessionID == nil {
        try await beginSession()
      } else {
        try await restartStream()
      }
      return
    }
    outbox.append(text)
    try await flushOutbox()
  }

  public func receive() async throws -> XMPPWebSocketMessage {
    while pending.isEmpty {
      guard sessionID != nil else { throw XMPPBOSHError.missingSessionID }
      if outstanding.isEmpty {
        dispatch(try body(payload: ""))
      }
      try await awaitOldestRequest()
    }
    return .text(XMPPWriter.serialize(pending.removeFirst()))
  }

  public func close() async {
    guard !closed, sessionID != nil else { return }
    closed = true
    for request in outstanding { request.cancel() }
    outstanding.removeAll()
    outbox.removeAll()

    // `terminate` is a courtesy to the server. The session is finished either
    // way, so it gets a short deadline of its own: without one it queues
    // behind whatever poll the server is still holding and blocks teardown for
    // the full hold interval.
    if let terminate = try? body(payload: "", extraAttributes: " type='terminate'") {
      let request = self.request(body: terminate, timeout: Self.terminateTimeout)
      _ = try? await loader(request)
    }
    sessionID = nil
    pending.removeAll()
  }

  private func beginSession() async throws {
    let requestRID = nextRID()
    let body =
      "<body xmlns='http://jabber.org/protocol/httpbind' rid='\(requestRID)'"
      + " to='\(escape(domain))' wait='\(Self.holdSeconds)' hold='1' ver='1.6'"
      + " xml:lang='en' xmpp:version='1.0' xmlns:xmpp='urn:xmpp:xbosh'/>"
    try await perform(body, capturesSessionID: true)
  }

  private func restartStream() async throws {
    let body = try body(
      payload: "",
      extraAttributes:
        " xmpp:restart='true' xmlns:xmpp='urn:xmpp:xbosh' to='\(escape(domain))'"
    )
    // Part of the handshake, which is strictly request/response: the server
    // always has stream features to return, so it will not hold this one.
    try await perform(body)
  }

  /// Posts everything queued as a single request body.
  ///
  /// BOSH sessions with `hold='1'` let the server keep one request open. A
  /// payload request therefore has to overlap a poll: with nothing else
  /// outstanding the server may hold the payload request itself, and the
  /// sender waits out the whole hold interval for a response the server is
  /// deliberately sitting on. One poll is enough to prevent that, however many
  /// stanzas are queued behind it.
  private func flushOutbox() async throws {
    // Stay inside the session's request allowance. Waiting here is also what
    // lets a second caller's stanzas join this request's body: by the time the
    // wait is over, everything queued behind it goes out together.
    while outstanding.count >= Self.maximumOutstandingRequests {
      try await awaitOldestRequest()
    }
    guard !outbox.isEmpty else { return }

    let payload = outbox.joined()
    outbox.removeAll()
    dispatch(try body(payload: payload))
    try await awaitOldestRequest()
  }

  private func dispatch(_ xml: String) {
    outstanding.append(Task { try await self.perform(xml) })
  }

  /// Waits for the request the server will answer first.
  ///
  /// A BOSH server answers in request-ID order and holds the newest request
  /// open, so waiting on the request just dispatched would block for the whole
  /// hold interval — even though the response the caller needs has already
  /// come back on an earlier one.
  private func awaitOldestRequest() async throws {
    guard !outstanding.isEmpty else { return }
    let oldest = outstanding.removeFirst()
    try await oldest.value
  }

  private func body(payload: String, extraAttributes: String = "") throws -> String {
    guard let sessionID else { throw XMPPBOSHError.missingSessionID }
    return
      "<body xmlns='http://jabber.org/protocol/httpbind' rid='\(nextRID())'"
      + " sid='\(escape(sessionID))'\(extraAttributes)>\(payload)</body>"
  }

  private func request(body xml: String, timeout: TimeInterval? = nil) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("Sangam/1 CFNetwork", forHTTPHeaderField: "User-Agent")
    request.httpBody = Data(xml.utf8)
    if let timeout { request.timeoutInterval = timeout }
    return request
  }

  private func perform(_ xml: String, capturesSessionID: Bool = false) async throws {
    let (data, response) = try await loader(request(body: xml))
    guard (200..<300).contains(response.statusCode) else {
      throw XMPPBOSHError.httpStatus(response.statusCode)
    }
    guard data.count <= maximumResponseBytes else {
      throw XMPPBOSHError.responseTooLarge(limit: maximumResponseBytes)
    }
    let root = try XMPPParser(bounds: XMLBounds(maximumBytes: maximumResponseBytes)).parse(data)
    guard root.name == "body", root.namespace == "http://jabber.org/protocol/httpbind" else {
      throw XMPPBOSHError.invalidResponse
    }
    if capturesSessionID {
      guard let sid = root[attribute: "sid"], !sid.isEmpty else {
        throw XMPPBOSHError.missingSessionID
      }
      sessionID = sid
    }
    if root[attribute: "type"] == "terminate" {
      throw XMPPBOSHError.terminated(root[attribute: "condition"])
    }
    pending.append(contentsOf: root.children)
  }

  private func nextRID() -> UInt64 {
    rid &+= 1
    return rid
  }

  private func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "'", with: "&apos;")
      .replacingOccurrences(of: "<", with: "&lt;")
  }

  /// A session of its own rather than `URLSession.shared`, whose 60-second
  /// default request timeout collides with the BOSH hold interval.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.httpShouldUsePipelining = false
    return URLSession(configuration: configuration)
  }()

  public static func defaultLoader(_ request: URLRequest) async throws
    -> (Data, HTTPURLResponse)
  {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw XMPPBOSHError.invalidResponse
    }
    return (data, response)
  }
}
