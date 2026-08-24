import Foundation
import Testing

@testable import JitsiDiscovery

@Test
func infersConventionalJitsiEndpoints() throws {
  let configuration = try DeploymentConfiguration.inferred(
    from: #require(URL(string: "https://meet.example.test/subpath"))
  )
  #expect(configuration.xmppWebSocketURL.absoluteString == "wss://meet.example.test/xmpp-websocket")
  #expect(configuration.mucDomain == "conference.meet.example.test")
  #expect(configuration.focusJID == "focus.meet.example.test")
}

@Test
func rejectsPlaintextRemoteServers() {
  #expect(throws: DiscoveryError.insecureURL(URL(string: "http://example.test")!)) {
    try DeploymentConfiguration.inferred(from: URL(string: "http://example.test")!)
  }
}

@Test
func loadsControlledDeploymentManifest() async throws {
  let response = try #require(
    HTTPURLResponse(
      url: URL(string: "https://meet.example.test/gafsaf-native.json")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )
  )
  let manifest = Data(
    """
    {
      "xmppWebSocketURL": "wss://xmpp.example.test/xmpp-websocket",
      "xmppDomain": "meet.example.test",
      "anonymousDomain": "guest.meet.example.test",
      "mucDomain": "conference.meet.example.test",
      "focusJID": "focus.meet.example.test",
      "bridgeWebSocketURL": "wss://bridge.example.test/colibri-ws/native"
    }
    """.utf8
  )
  let client = DiscoveryClient { _ in (manifest, response) }
  let configuration = try await client.discover(
    baseURL: URL(string: "https://meet.example.test")!
  )

  #expect(configuration.xmppWebSocketURL.host == "xmpp.example.test")
  #expect(configuration.anonymousDomain == "guest.meet.example.test")
  #expect(configuration.bridgeWebSocketURL?.host == "bridge.example.test")
}

@Test
func fallsBackFromHTMLShellToStandardJitsiConfig() async throws {
  let client = DiscoveryClient { url in
    let response = try #require(
      HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )
    )
    if url.lastPathComponent == "gafsaf-native.json" {
      return (Data("<html>Jitsi Meet</html>".utf8), response)
    }
    return (
      Data(
        """
        var subdomainDot = '';
        var config = {
          hosts: {
            domain: 'meet.jit.si',
            anonymousdomain: 'guest.meet.jit.si',
            muc: 'conference.' + subdomainDot + 'meet.jit.si',
            focus: 'focus.meet.jit.si'
          },
          bosh: 'https://meet.jit.si/http-bind',
          websocket: 'wss://meet.jit.si/xmpp-websocket',
          conferenceRequestUrl: 'https://meet.jit.si/conference-request/v1'
        };
        """.utf8
      ),
      response
    )
  }
  let configuration = try await client.discover(baseURL: URL(string: "https://meet.jit.si")!)

  #expect(configuration.xmppDomain == "meet.jit.si")
  #expect(configuration.anonymousDomain == "guest.meet.jit.si")
  #expect(configuration.mucDomain == "conference.meet.jit.si")
  #expect(configuration.focusJID == "focus.meet.jit.si")
  #expect(configuration.xmppWebSocketURL.absoluteString == "wss://meet.jit.si/xmpp-websocket")
  // This deployment advertises a WebSocket, which delivers pushed stanzas
  // without waiting for a poll to come back, so BOSH is only the fallback.
  #expect(!configuration.prefersBOSH)
  #expect(
    configuration.conferenceRequestURL?.absoluteString
      == "https://meet.jit.si/conference-request/v1")
}

@Test
func parsesSelfHostedConfigWithInferredWebSocketAndFocus() async throws {
  let client = DiscoveryClient { url in
    let status = url.lastPathComponent == "gafsaf-native.json" ? 404 : 200
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    )
    let body =
      status == 404
      ? Data()
      : Data(
        """
        var subdomain = '';
        var config = {
          hosts: {
            domain: 'meet.example.com',
            anonymousdomain: 'guest.meet.example.com',
            // focus: 'ignored.example.test',
            muc: 'conference.' + subdomain + 'meet.example.com'
          },
          bosh: 'https://meet.example.com/' + subdomain + 'http-bind',
          // websocket: 'wss://ignored.example.test/xmpp-websocket'
        };
        """.utf8
      )
    return (body, response)
  }
  let configuration = try await client.discover(
    baseURL: URL(string: "https://meet.example.com")!
  )

  #expect(configuration.xmppDomain == "meet.example.com")
  #expect(configuration.anonymousDomain == "guest.meet.example.com")
  #expect(configuration.mucDomain == "conference.meet.example.com")
  #expect(configuration.focusJID == "focus.meet.example.com")
  #expect(configuration.boshURL?.absoluteString == "https://meet.example.com/http-bind")
  #expect(configuration.prefersBOSH)
  #expect(
    configuration.xmppWebSocketURL.absoluteString
      == "wss://meet.example.com/xmpp-websocket")
}

@Test
func fallsBackToConventionalEndpointsOn404() async throws {
  let response = try #require(
    HTTPURLResponse(
      url: URL(string: "https://meet.example.test/gafsaf-native.json")!,
      statusCode: 404,
      httpVersion: nil,
      headerFields: nil
    )
  )
  let client = DiscoveryClient { _ in (Data(), response) }
  let configuration = try await client.discover(
    baseURL: URL(string: "https://meet.example.test")!
  )
  #expect(configuration.xmppWebSocketURL.path == "/xmpp-websocket")
}

@Test
func prefersWebSocketWhenTheDeploymentAdvertisesOne() throws {
  let source = """
    var config = {
      hosts: {
        domain: 'jitsi.test',
        muc: 'conference.jitsi.test'
      },
      bosh: 'https://jitsi.test/http-bind',
      websocket: 'wss://jitsi.test/xmpp-websocket',
    };
    """
  let configuration = try StandardJitsiConfigParser().configuration(
    from: source,
    baseURL: URL(string: "https://jitsi.test")!
  )
  #expect(!configuration.prefersBOSH)
  #expect(configuration.xmppWebSocketURL.absoluteString == "wss://jitsi.test/xmpp-websocket")
}

@Test
func fallsBackToBOSHWhenNoWebSocketIsAdvertised() throws {
  // A commented-out websocket line is not an advertisement: the inferred URL
  // is a guess, and deployments that do not proxy that path reject it.
  let source = """
    var config = {
      hosts: {
        domain: 'jitsi.test',
        muc: 'conference.jitsi.test'
      },
      bosh: 'https://jitsi.test/http-bind',
      // websocket: 'wss://jitsi.test/xmpp-websocket',
    };
    """
  let configuration = try StandardJitsiConfigParser().configuration(
    from: source,
    baseURL: URL(string: "https://jitsi.test")!
  )
  #expect(configuration.prefersBOSH)
}

@Test
func honoursAnExplicitBOSHPreference() throws {
  let source = """
    var config = {
      hosts: {
        domain: 'jitsi.test',
        muc: 'conference.jitsi.test'
      },
      bosh: 'https://jitsi.test/http-bind',
      websocket: 'wss://jitsi.test/xmpp-websocket',
      preferBosh: true,
    };
    """
  let configuration = try StandardJitsiConfigParser().configuration(
    from: source,
    baseURL: URL(string: "https://jitsi.test")!
  )
  #expect(configuration.prefersBOSH)
}
