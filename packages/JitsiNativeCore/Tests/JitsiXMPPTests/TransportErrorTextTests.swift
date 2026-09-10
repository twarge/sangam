import Foundation
import Testing

@testable import JitsiXMPP

/// Everything the transport can throw reaches the join screen through
/// `localizedDescription`. Without text of its own a Swift error renders there
/// as "The operation couldn't be completed. (JitsiXMPP.XMPPTransportError
/// error 0.)", which tells the person nothing about the server they typed.
@Suite
struct TransportErrorTextTests {
  /// Foundation's fallback names the type and the case's ordinal; real text
  /// never does either.
  private func expectReadable(_ error: any Error, _ type: String) {
    let text = error.localizedDescription
    #expect(!text.contains(type))
    #expect(!text.contains("couldn’t be completed"))
    #expect(text.hasSuffix("."))
  }

  @Test
  func transportFailuresReadAsSentences() {
    let failures: [XMPPTransportError] = [
      .notConnected, .alreadyConnected, .unsupportedFrame, .frameTooLarge(limit: 1_048_576),
    ]
    for failure in failures { expectReadable(failure, "XMPPTransportError") }
  }

  @Test
  func parsingFailuresReadAsSentences() {
    let failures: [XMPPParsingError] = [
      .emptyDocument, .documentTooLarge(limit: 65_536), .documentTypeNotAllowed, .malformedXML,
      .nestingTooDeep(limit: 32), .tooManyElements(limit: 512), .tooManyAttributes(limit: 64),
      .textTooLarge(limit: 8_192), .multipleRootElements,
    ]
    for failure in failures { expectReadable(failure, "XMPPParsingError") }
  }

  /// A proxy that answers the XMPP WebSocket address with an error page is the
  /// deployment mistake behind most unexplained joins, so the limit shows up
  /// in the text rather than only in the case name.
  @Test
  func boundedParsingFailuresNameTheirLimit() {
    #expect(XMPPParsingError.documentTooLarge(limit: 65_536).localizedDescription.contains("65536"))
    #expect(XMPPParsingError.nestingTooDeep(limit: 32).localizedDescription.contains("32"))
    #expect(XMPPParsingError.tooManyElements(limit: 512).localizedDescription.contains("512"))
  }

  @Test
  func focusAndPresenceFailuresReadAsSentences() {
    for failure in [FocusConferenceError.notSuccessfulIQ, .missingConference] {
      expectReadable(failure, "FocusConferenceError")
    }
    let presence: [MUCPresenceError] = [
      .notPresence, .missingEndpointID, .invalidSourceInfo,
      .sourceInfoTooLarge(limit: 4_096), .tooManySources(limit: 16),
    ]
    for failure in presence { expectReadable(failure, "MUCPresenceError") }
  }

  #if canImport(Network)
    @Test
    func socketFailuresReadAsSentences() {
      let failures: [NetworkXMPPSocketError] = [
        .invalidURL, .cancelledBeforeOpen, .invalidUpgrade, .invalidText,
        .remoteClosed(code: nil, reason: nil), .unsupportedFrame(0x8), .frameTooLarge,
      ]
      for failure in failures { expectReadable(failure, "NetworkXMPPSocketError") }
    }

    /// A close carries a code, a reason, both, or neither; each has to end up
    /// as one sentence rather than a dangling bracket.
    @Test
    func closeReasonAndCodeAreReportedWhenPresent() {
      #expect(
        NetworkXMPPSocketError.remoteClosed(code: nil, reason: nil).localizedDescription
          == "The Jitsi server closed the connection.")
      #expect(
        NetworkXMPPSocketError.remoteClosed(code: 1006, reason: nil).localizedDescription
          == "The Jitsi server closed the connection (code 1006).")
      #expect(
        NetworkXMPPSocketError.remoteClosed(code: nil, reason: "going away").localizedDescription
          == "The Jitsi server closed the connection (going away).")
      #expect(
        NetworkXMPPSocketError.remoteClosed(code: 1001, reason: "going away").localizedDescription
          == "The Jitsi server closed the connection (going away, code 1001).")
      // An empty reason is not a reason; it must not leave empty brackets.
      #expect(
        NetworkXMPPSocketError.remoteClosed(code: nil, reason: "").localizedDescription
          == "The Jitsi server closed the connection.")
    }
  #endif
}
