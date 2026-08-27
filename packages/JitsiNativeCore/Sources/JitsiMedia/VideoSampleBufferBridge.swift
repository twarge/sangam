import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

@preconcurrency import WebRTC

/// Renders a remote WebRTC video track into an `AVSampleBufferDisplayLayer`
/// — the content source AVKit's Picture in Picture accepts on both macOS
/// and iOS. Decoded frames arrive as CVPixelBuffers from hardware decoders
/// or as I420 from software ones; the latter are converted to NV12.
public final class VideoSampleBufferBridge: NSObject, @unchecked Sendable {
  public let layer = AVSampleBufferDisplayLayer()

  private let forwarder = FrameForwarder()
  private weak var currentTrack: RTCVideoTrack?

  public override init() {
    super.init()
    layer.videoGravity = .resizeAspect
    forwarder.layer = layer
  }

  public func attach(to track: RemoteVideoTrack) {
    detach()
    layer.sampleBufferRenderer.flush()
    track.track.add(forwarder)
    currentTrack = track.track
  }

  public func detach() {
    currentTrack?.remove(forwarder)
    currentTrack = nil
  }
}

/// The RTCVideoRenderer half: converts each frame to a sample buffer and
/// enqueues it. Runs on WebRTC's decode thread; the display layer's
/// renderer is thread-safe.
private final class FrameForwarder: NSObject, RTCVideoRenderer, @unchecked Sendable {
  weak var layer: AVSampleBufferDisplayLayer?

  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard
      let frame,
      let layer,
      layer.sampleBufferRenderer.isReadyForMoreMediaData,
      let pixelBuffer = pixelBuffer(from: frame),
      let sample = sampleBuffer(for: pixelBuffer, timeStampNs: frame.timeStampNs)
    else { return }
    layer.sampleBufferRenderer.enqueue(sample)
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
