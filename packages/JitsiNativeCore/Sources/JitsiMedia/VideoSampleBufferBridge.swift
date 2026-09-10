import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import WebRTC

/// Renders a remote WebRTC video track into an `AVSampleBufferDisplayLayer`
/// — the content source AVKit's Picture in Picture accepts on both macOS
/// and iOS. Decoded frames arrive as CVPixelBuffers from hardware decoders
/// or as I420 from software ones; the latter are converted to NV12.
///
/// The layer, like every CALayer, is main-actor bound; frames bypass it and
/// go through its `AVSampleBufferVideoRenderer`, which is documented
/// thread-safe and is captured once here so the decode thread never touches
/// the layer itself.
@MainActor
public final class VideoSampleBufferBridge {
  public let layer = AVSampleBufferDisplayLayer()

  /// The size of the frames arriving, whenever it changes. Picture in
  /// Picture takes the floating window's shape from this; without it the
  /// window keeps whatever aspect it was guessed into.
  public var onVideoSize: (@MainActor @Sendable (CGSize) -> Void)? {
    didSet {
      forwarder.sizeHandler = { [weak self] size in
        self?.rawSize = size
        self?.publishSize()
      }
    }
  }

  private let forwarder: FrameForwarder
  private weak var currentTrack: RTCVideoTrack?

  /// The rotation WebRTC last asked for, and the frame size before it is
  /// applied.
  private var rotationDegrees = 0
  private var rawSize: CGSize = .zero

  public init() {
    forwarder = FrameForwarder(renderer: layer.sampleBufferRenderer)
    layer.videoGravity = .resizeAspect
    forwarder.rotationHandler = { [weak self] degrees in self?.apply(rotation: degrees) }
  }

  /// WebRTC hands over frames with their rotation still to apply — the
  /// camera's sensor orientation, mostly, which is why the local self view
  /// arrives upside down on a device held one way and not the other. WebRTC's
  /// own renderers apply it; a sample-buffer layer does not, so the layer
  /// carries it as a transform instead.
  ///
  /// A half turn is exact. A quarter turn comes out upright but fitted to the
  /// unrotated frame, so it letterboxes; the window at least takes the right
  /// shape, because the size published below is swapped to match.
  private func apply(rotation degrees: Int) {
    rotationDegrees = degrees
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = CATransform3DMakeRotation(CGFloat(degrees) * .pi / 180, 0, 0, 1)
    CATransaction.commit()
    publishSize()
  }

  private func publishSize() {
    guard let onVideoSize, rawSize.width > 0, rawSize.height > 0 else { return }
    let quarterTurn = rotationDegrees == 90 || rotationDegrees == 270
    onVideoSize(
      quarterTurn ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize)
  }

  public func attach(to track: RemoteVideoTrack) {
    attachTrack(track.track)
  }

  /// The local camera can feed the bridge too — how PiP shows the self
  /// view while waiting alone in a room.
  public func attach(to track: LocalVideoTrack) {
    attachTrack(track.track)
  }

  public func detach() {
    currentTrack?.remove(forwarder)
    currentTrack = nil
  }

  private func attachTrack(_ track: RTCVideoTrack) {
    detach()
    forwarder.flush()
    track.add(forwarder)
    currentTrack = track
  }
}

/// The RTCVideoRenderer half: converts each frame to a sample buffer and
/// enqueues it. Runs on WebRTC's decode thread; the video renderer is
/// thread-safe.
private final class FrameForwarder: NSObject, RTCVideoRenderer, @unchecked Sendable {
  // The renderer object is documented thread-safe; the class's @unchecked
  // Sendable covers holding it across the decode thread.
  nonisolated(unsafe) private let renderer: AVSampleBufferVideoRenderer

  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  /// Written from the main actor when the bridge is wired, read on WebRTC's
  /// decode thread. The closure itself only ever runs back on the main actor.
  nonisolated(unsafe) var sizeHandler: (@MainActor @Sendable (CGSize) -> Void)?
  nonisolated(unsafe) var rotationHandler: (@MainActor @Sendable (Int) -> Void)?
  nonisolated(unsafe) private var lastSize: CGSize = .zero
  nonisolated(unsafe) private var lastRotation = -1

  init(renderer: AVSampleBufferVideoRenderer) {
    self.renderer = renderer
  }

  func flush() {
    renderer.flush()
  }

  /// WebRTC calls this on the decode thread when the stream's dimensions
  /// change — a resolution switch, or the first frame of a new track.
  func setSize(_ size: CGSize) {
    guard size.width > 0, size.height > 0, size != lastSize else { return }
    lastSize = size
    guard let sizeHandler else { return }
    Task { @MainActor in sizeHandler(size) }
  }

  func renderFrame(_ frame: RTCVideoFrame?) {
    if let frame { note(rotation: Int(frame.rotation.rawValue)) }
    guard
      let frame,
      renderer.isReadyForMoreMediaData,
      let pixelBuffer = pixelBuffer(from: frame),
      let sample = sampleBuffer(for: pixelBuffer, timeStampNs: frame.timeStampNs)
    else { return }
    renderer.enqueue(sample)
  }

  private func note(rotation degrees: Int) {
    guard degrees != lastRotation else { return }
    lastRotation = degrees
    guard let rotationHandler else { return }
    Task { @MainActor in rotationHandler(degrees) }
  }

  private func pixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
    if let native = frame.buffer as? RTCCVPixelBuffer {
      return native.pixelBuffer
    }
    // Software decoders hand out I420; repack into NV12 for the layer.
    let i420 = frame.buffer.toI420()
    let width = Int(i420.width)
    let height = Int(i420.height)
    guard let output = makeNV12Buffer(width: width, height: height) else { return nil }
    CVPixelBufferLockBaseAddress(output, [])
    defer { CVPixelBufferUnlockBaseAddress(output, []) }

    if let yBase = CVPixelBufferGetBaseAddressOfPlane(output, 0) {
      let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
      let source = i420.dataY
      let sourceStride = Int(i420.strideY)
      for row in 0..<height {
        memcpy(yBase + row * yStride, source + row * sourceStride, width)
      }
    }
    if let uvBase = CVPixelBufferGetBaseAddressOfPlane(output, 1) {
      let uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
      let uSource = i420.dataU
      let vSource = i420.dataV
      let uStride = Int(i420.strideU)
      let vStride = Int(i420.strideV)
      let chromaWidth = (width + 1) / 2
      let chromaHeight = (height + 1) / 2
      let uv = uvBase.assumingMemoryBound(to: UInt8.self)
      for row in 0..<chromaHeight {
        let target = uv + row * uvStride
        let uRow = uSource + row * uStride
        let vRow = vSource + row * vStride
        for column in 0..<chromaWidth {
          target[column * 2] = uRow[column]
          target[column * 2 + 1] = vRow[column]
        }
      }
    }
    return output
  }

  private func makeNV12Buffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pool == nil || poolWidth != width || poolHeight != height {
      var newPool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        nil,
        [
          kCVPixelBufferWidthKey: width,
          kCVPixelBufferHeightKey: height,
          kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
          kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary,
        &newPool
      )
      pool = newPool
      poolWidth = width
      poolHeight = height
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return buffer
  }

  private func sampleBuffer(
    for pixelBuffer: CVPixelBuffer,
    timeStampNs: Int64
  ) -> CMSampleBuffer? {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &format
    )
    guard let format else { return nil }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: timeStampNs, timescale: 1_000_000_000),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sample
    )
    guard let sample else { return nil }
    // Live video: render each frame the moment it arrives, ignoring the
    // stream clock.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let entry = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        entry,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sample
  }
}
