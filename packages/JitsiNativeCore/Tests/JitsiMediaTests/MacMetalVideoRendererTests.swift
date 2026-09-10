#if os(macOS)
  import CoreGraphics
  import Testing
  import WebRTC

  @testable import JitsiMedia

  /// The Metal renderer draws one quad and decides two things: which slice of
  /// the frame it samples, and how much of the view it covers. Filling trims
  /// the frame; fitting shrinks the quad, which is what keeps a sender's
  /// whole picture on a stage that isn't their shape.
  private let square = CGSize(width: 800, height: 800)

  private func quad(
    videoWidth: Int,
    videoHeight: Int,
    into size: CGSize,
    contentMode: VideoContentMode
  ) -> [MacVideoVertex] {
    MacMetalVideoRenderer.vertices(
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      rotation: ._0,
      drawableSize: size,
      contentMode: contentMode
    )
  }

  @Test
  func fittingKeepsTheWholeFrameAndLetterboxesTheView() {
    let vertices = quad(videoWidth: 1280, videoHeight: 720, into: square, contentMode: .fit)
    // Every corner of the frame is sampled: nothing is cropped away.
    let textureX = Set(vertices.map(\.texture.x))
    let textureY = Set(vertices.map(\.texture.y))
    #expect(textureX == [0, 1])
    #expect(textureY == [0, 1])
    // A 16:9 frame in a square view spans the full width and 9/16 the height.
    #expect(Set(vertices.map(\.position.x)) == [-1, 1])
    let height = vertices.map(\.position.y).max() ?? 0
    #expect(abs(height - 9.0 / 16.0) < 0.001)
  }

  @Test
  func fittingATallFrameLeavesBarsAtTheSides() {
    let vertices = quad(videoWidth: 720, videoHeight: 1280, into: square, contentMode: .fit)
    #expect(Set(vertices.map(\.position.y)) == [-1, 1])
    let width = vertices.map(\.position.x).max() ?? 0
    #expect(abs(width - 9.0 / 16.0) < 0.001)
  }

  @Test
  func fillingCropsTheFrameToCoverTheView() {
    let vertices = quad(videoWidth: 1280, videoHeight: 720, into: square, contentMode: .fill)
    // The quad still covers the view edge to edge…
    #expect(Set(vertices.map(\.position.x)) == [-1, 1])
    #expect(Set(vertices.map(\.position.y)) == [-1, 1])
    // …and the sides of the frame are the part left out.
    let left = vertices.map(\.texture.x).min() ?? 0
    #expect(abs(left - (1 - 9.0 / 16.0) / 2) < 0.001)
  }

  @Test
  func aFrameMatchingTheViewIsNeitherCroppedNorInset() {
    for mode in [VideoContentMode.fit, .fill] {
      let vertices = quad(
        videoWidth: 1280,
        videoHeight: 720,
        into: CGSize(width: 1600, height: 900),
        contentMode: mode
      )
      #expect(Set(vertices.map(\.position.x)) == [-1, 1])
      #expect(Set(vertices.map(\.position.y)) == [-1, 1])
      #expect(Set(vertices.map(\.texture.x)) == [0, 1])
      #expect(Set(vertices.map(\.texture.y)) == [0, 1])
    }
  }
#endif
