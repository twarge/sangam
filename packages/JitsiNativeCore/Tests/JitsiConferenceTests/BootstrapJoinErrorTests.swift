import Foundation
import JitsiXMPP
import Testing

@testable import JitsiConference

/// A refused sign-in is answered during the SASL handshake, before the join
/// proper begins. Left untranslated it reaches the person joining as
/// "XMPPNegotiationError error 2" and drops them out of the sign-in card, so
/// every refusal the handshake can produce is mapped to something they can
/// act on.
@Suite
struct BootstrapJoinErrorTests {
  @Test
  func rejectedCredentialsBecomeInvalidCredentials() {
    let mapped = NativeConferenceBootstrap.joinError(
      from: XMPPNegotiationError.authenticationFailed, hasCredentials: true)
    #expect(mapped as? NativeConferenceBootstrapError == .invalidCredentials)
  }

  @Test
  func refusedAnonymousBindBecomesGuestAccessUnavailable() {
    let mapped = NativeConferenceBootstrap.joinError(
      from: XMPPNegotiationError.authenticationFailed, hasCredentials: false)
    #expect(mapped as? NativeConferenceBootstrapError == .guestAccessUnavailable)
  }

  @Test
  func missingMechanismsNameWhichSignInIsUnavailable() {
    #expect(
      NativeConferenceBootstrap.joinError(
        from: XMPPNegotiationError.missingMechanism("ANONYMOUS"), hasCredentials: false)
        as? NativeConferenceBootstrapError == .guestAccessUnavailable)
    #expect(
      NativeConferenceBootstrap.joinError(
        from: XMPPNegotiationError.missingMechanism("PLAIN"), hasCredentials: true)
        as? NativeConferenceBootstrapError == .passwordLoginUnavailable)
  }

  /// Only the credential-shaped refusals are reinterpreted. A cancelled join
  /// must stay a cancellation — the join path uses it to tell "the user left"
  /// apart from "the server said no".
  @Test
  func unrelatedErrorsPassThrough() {
    #expect(
      NativeConferenceBootstrap.joinError(from: CancellationError(), hasCredentials: true)
        is CancellationError)
    let streamError = NativeConferenceBootstrap.joinError(
      from: XMPPNegotiationError.streamError, hasCredentials: true)
    #expect(streamError as? XMPPNegotiationError == .streamError)
  }

  /// Whatever still reaches the failure alert has to read as a sentence.
  @Test
  func everyNegotiationFailureHasReadableText() {
    let failures: [XMPPNegotiationError] = [
      .invalidState(.awaitingAuthenticationResult), .missingMechanism("SCRAM-SHA-1"),
      .authenticationFailed, .resourceBindingUnavailable, .resourceBindingFailed,
      .missingBoundJID, .streamError,
    ]
    for failure in failures {
      let text = (failure as any Error).localizedDescription
      #expect(!text.contains("XMPPNegotiationError"))
      #expect(text.hasSuffix("."))
    }
  }

  @Test
  func everyJoinRefusalHasReadableText() {
    let refusals: [NativeConferenceBootstrapError] = [
      .invalidRoom, .focusNotReady, .invalidFocusResponse, .focusHTTPStatus(503),
      .authenticationRequired, .invalidCredentials, .membersOnly, .meetingEnded,
      .passwordRequired, .guestAccessUnavailable, .passwordLoginUnavailable,
    ]
    for refusal in refusals {
      let text = (refusal as any Error).localizedDescription
      #expect(!text.contains("NativeConferenceBootstrapError"))
      #expect(text.hasSuffix("."))
    }
  }
}
