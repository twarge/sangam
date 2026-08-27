import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

@preconcurrency import WebRTC

public enum VirtualBackgroundMode: String, Sendable {
  case none
  case blur
}

/// Sits between the camera capturer and the WebRTC video source, so frames
/// can be rewritten before they reach the encoder (and the self-preview,
/// which renders the same source). With no processor installed it is a
/// straight passthrough.
final class CameraFrameRouter: NSObject, RTCVideoCapturerDelegate, @unchecked Sendable {
  private let source: RTCVideoSource
  private let lock = NSLock()
  private var processor: VirtualBackgroundProcessor?

  init(source: RTCVideoSource) {
    self.source = source
  }

  func setMode(_ mode: VirtualBackgroundMode) {
    lock.lock()
    defer { lock.unlock() }
    switch mode {
    case .none: processor = nil
    case .blur: processor = processor ?? VirtualBackgroundProcessor()
    }
  }

  func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
    lock.lock()
    let active = processor
    lock.unlock()
    if let active, let processed = active.process(frame) {
      source.capturer(capturer, didCapture: processed)
    } else {
      source.capturer(capturer, didCapture: frame)
    }
  }
}

/// Apple-native background blur: Vision's person segmentation produces the
/// mask, Core Image blends the sharp person over a blurred background, and
/// the result goes out as a normal camera frame. Runs synchronously on the
/// capture callback — balanced-quality segmentation keeps up with 720p30 on
/// Apple silicon, and a frame that cannot be processed passes through
/// unmodified rather than stalling the call.
final class VirtualBackgroundProcessor: @unchecked Sendable {
  private let request: VNGeneratePersonSegmentationRequest
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var poolFormat: OSType = 0

  init() {
    request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
  }

  func process(_ frame: RTCVideoFrame) -> RTCVideoFrame? {
    guard
      let sourceBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer
    else { return nil }
    let handler = VNImageRequestHandler(cvPixelBuffer: sourceBuffer, options: [:])
    guard
      (try? handler.perform([request])) != nil,
      let mask = request.results?.first?.pixelBuffer
    else { return nil }

    let original = CIImage(cvPixelBuffer: sourceBuffer)
    var maskImage = CIImage(cvPixelBuffer: mask)
    maskImage = maskImage.transformed(
      by: CGAffineTransform(
        scaleX: original.extent.width / maskImage.extent.width,
        y: original.extent.height / maskImage.extent.height
      )
    )
    let background = original
      .clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
      .cropped(to: original.extent)
    let blended = original.applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: background,
        kCIInputMaskImageKey: maskImage,
      ]
    )

    guard let output = makeBuffer(like: sourceBuffer) else { return nil }
    context.render(blended, to: output)
    return RTCVideoFrame(
      buffer: RTCCVPixelBuffer(pixelBuffer: output),
      rotation: frame.rotation,
      timeStampNs: frame.timeStampNs
    )
  }

  private func makeBuffer(like sourceBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(sourceBuffer)
    let height = CVPixelBufferGetHeight(sourceBuffer)
    let format = CVPixelBufferGetPixelFormatType(sourceBuffer)
    if pool == nil || poolWidth != width || poolHeight != height || poolFormat != format {
      var newPool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        nil,
        [
          kCVPixelBufferWidthKey: width,
          kCVPixelBufferHeightKey: height,
          kCVPixelBufferPixelFormatTypeKey: format,
          kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary,
        &newPool
      )
      pool = newPool
      poolWidth = width
      poolHeight = height
      poolFormat = format
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return buffer
  }
}
