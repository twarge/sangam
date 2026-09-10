import Foundation
import Testing

@testable import JitsiMedia

/// The camera starts before the room is entered, so a refused or missing
/// camera ends the join — and reaches the person joining as text.
@Suite
struct CameraErrorTextTests {
  @Test
  func cameraFailuresReadAsSentences() {
    for failure in [CameraCaptureError.noCamera, .noSupportedFormat] {
      let text = (failure as any Error).localizedDescription
      #expect(!text.contains("CameraCaptureError"))
      #expect(!text.contains("couldn’t be completed"))
      #expect(text.hasSuffix("."))
    }
  }

  /// The underlying capturer's message is already a sentence; it is carried
  /// through rather than replaced, so the reason survives.
  @Test
  func startFailureCarriesTheUnderlyingReason() {
    let text = CameraCaptureError.startFailed("The camera is in use by another app.")
      .localizedDescription
    #expect(text == "The camera could not start: The camera is in use by another app.")
  }
}
