import Foundation
@preconcurrency import WebRTC

public struct PeerConnectionPolicy: Equatable, Sendable {
  public var gatherContinually: Bool
  public var enableDSCP: Bool
  public var iceServers: [ICEServer]

  public init(
    gatherContinually: Bool = true,
    enableDSCP: Bool = true,
    iceServers: [ICEServer] = []
  ) {
    self.gatherContinually = gatherContinually
    self.enableDSCP = enableDSCP
    self.iceServers = iceServers
  }
}

public struct ICEServer: Equatable, Sendable {
  public var urls: [String]
  public var username: String?
  public var credential: String?

  public init(urls: [String], username: String? = nil, credential: String? = nil) {
    self.urls = urls
    self.username = username
    self.credential = credential
  }
}

public enum WebRTCMediaError: Error, Equatable, Sendable {
  case peerConnectionCreationFailed
}

public final class WebRTCMediaFactory: @unchecked Sendable {
  public let peerConnectionFactory: RTCPeerConnectionFactory

  private static let initializeSSL: Void = {
    RTCInitializeSSL()
  }()

  public init() {
    _ = Self.initializeSSL
    peerConnectionFactory = RTCPeerConnectionFactory(
      encoderFactory: RTCDefaultVideoEncoderFactory(),
      decoderFactory: RTCDefaultVideoDecoderFactory()
    )
  }

  public func makePeerConnection(
    policy: PeerConnectionPolicy = .init(),
    delegate: RTCPeerConnectionDelegate? = nil
  ) throws -> RTCPeerConnection {
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    configuration.bundlePolicy = .maxBundle
    configuration.rtcpMuxPolicy = .require
    configuration.enableDscp = policy.enableDSCP
    configuration.continualGatheringPolicy =
      policy.gatherContinually
      ? .gatherContinually
      : .gatherOnce
    configuration.iceServers = policy.iceServers.map { server in
      if let username = server.username, let credential = server.credential {
        return RTCIceServer(
          urlStrings: server.urls,
          username: username,
          credential: credential
        )
      }
      return RTCIceServer(urlStrings: server.urls)
    }

    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
    )
    guard
      let connection = peerConnectionFactory.peerConnection(
        with: configuration,
        constraints: constraints,
        delegate: delegate
      )
    else {
      throw WebRTCMediaError.peerConnectionCreationFailed
    }
    return connection
  }

  public func makeAudioTrack(id: String) -> RTCAudioTrack {
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: [
        "googEchoCancellation": "true",
        "googAutoGainControl": "true",
        "googNoiseSuppression": "true",
      ]
    )
    let source = peerConnectionFactory.audioSource(with: constraints)
    return peerConnectionFactory.audioTrack(with: source, trackId: id)
  }

  public func makeLocalAudioTrack(id: String) -> LocalAudioTrack {
    LocalAudioTrack(track: makeAudioTrack(id: id))
  }

  public func makeVideoTrack(id: String, screenCast: Bool) -> LocalVideoTrack {
    let source = peerConnectionFactory.videoSource(forScreenCast: screenCast)
    let capturer = RTCVideoCapturer(delegate: source)
    let track = peerConnectionFactory.videoTrack(with: source, trackId: id)
    return LocalVideoTrack(
      source: source, track: track, capturer: capturer, isScreenCast: screenCast)
  }

  public func makeCameraTrack(id: String) -> LocalCameraTrack {
    let source = peerConnectionFactory.videoSource(forScreenCast: false)
    let capturer = RTCCameraVideoCapturer(delegate: source)
    let track = peerConnectionFactory.videoTrack(with: source, trackId: id)
    return LocalCameraTrack(
      videoTrack: LocalVideoTrack(
        source: source, track: track, capturer: capturer, isScreenCast: false),
      capturer: capturer
    )
  }
}

public final class LocalAudioTrack: @unchecked Sendable {
  let track: RTCAudioTrack

  fileprivate init(track: RTCAudioTrack) {
    self.track = track
  }

  public var isMuted: Bool {
    get { !track.isEnabled }
    set { track.isEnabled = !newValue }
  }
}

public final class LocalVideoTrack: @unchecked Sendable {
  public let source: RTCVideoSource
  public let track: RTCVideoTrack
  public let capturer: RTCVideoCapturer
  /// Screen shares get the desktop simulcast ladder (higher top-layer
  /// bitrate) instead of the camera one.
  public let isScreenCast: Bool

  /// The WebRTC track id, the handle senders are looked up by.
  public var id: String { track.trackId }

  fileprivate init(
    source: RTCVideoSource,
    track: RTCVideoTrack,
    capturer: RTCVideoCapturer,
    isScreenCast: Bool
  ) {
    self.source = source
    self.track = track
    self.capturer = capturer
    self.isScreenCast = isScreenCast
  }

  public func adapt(width: Int32, height: Int32, framesPerSecond: Int32) {
    source.adaptOutputFormat(
      toWidth: width,
      height: height,
      fps: framesPerSecond
    )
  }

  public var isEnabled: Bool {
    get { track.isEnabled }
    set { track.isEnabled = newValue }
  }

  /// Injects a platform capture frame without converting it through an image
  /// codec. ScreenCaptureKit and ReplayKit can therefore stay on the native
  /// CVPixelBuffer path all the way into WebRTC's hardware encoder.
  public func push(
    pixelBuffer: CVPixelBuffer,
    rotationDegrees: Int = 0,
    timestampNanoseconds: Int64
  ) {
    let rotation: RTCVideoRotation
    switch rotationDegrees {
    case 90: rotation = ._90
    case 180: rotation = ._180
    case 270: rotation = ._270
    default: rotation = ._0
    }
    let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
    let frame = RTCVideoFrame(
      buffer: buffer,
      rotation: rotation,
      timeStampNs: timestampNanoseconds
    )
    source.capturer(capturer, didCapture: frame)
  }
}

public enum CameraPosition: Sendable {
  case front
  case back
  case unspecified
}

public enum CameraCaptureError: Error, Equatable, Sendable {
  case noCamera
  case noSupportedFormat
  case startFailed(String)
}

public final class LocalCameraTrack: @unchecked Sendable {
  public let videoTrack: LocalVideoTrack

  private let capturer: RTCCameraVideoCapturer

  fileprivate init(videoTrack: LocalVideoTrack, capturer: RTCCameraVideoCapturer) {
    self.videoTrack = videoTrack
    self.capturer = capturer
  }

  deinit {
    // RTCCameraVideoCapturer traps if it is deallocated while its capture
    // session is still running — which happens when a join is torn down before
    // `stop()` runs (e.g. cancelled or failed while waiting in the lobby, with
    // the camera already started). Stopping synchronously here keeps teardown
    // safe on every path. Harmless if capture was never started or already
    // stopped.
    capturer.stopCapture()
  }

  public func start(
    position: CameraPosition = .front,
    width: Int32 = 1_280,
    height: Int32 = 720,
    framesPerSecond: Int = 30
  ) async throws {
    let devices = RTCCameraVideoCapturer.captureDevices()
    let device: AVCaptureDevice
    #if os(macOS)
      // A Mac's built-in camera reports position `.unspecified`, so honouring a
      // `.front` request would instead match a Continuity Camera (a nearby
      // iPhone). Continuity Camera publishes black frames when the phone is not
      // propped up as a webcam, which looks exactly like a broken capture.
      // Prefer the built-in wide-angle camera and only fall back past it.
      guard
        let macDevice = devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
          ?? devices.first(where: {
            $0.deviceType != .continuityCamera && $0.deviceType != .external
          })
          ?? devices.first
      else { throw CameraCaptureError.noCamera }
      device = macDevice
    #else
      let desiredPosition: AVCaptureDevice.Position =
        switch position {
        case .front: .front
        case .back: .back
        case .unspecified: .unspecified
        }
      guard
        let iosDevice = devices.first(where: { $0.position == desiredPosition }) ?? devices.first
      else { throw CameraCaptureError.noCamera }
      device = iosDevice
    #endif
    let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
    guard
      let format = formats.min(by: { lhs, rhs in
        let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
        let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
        let leftDistance = abs(left.width - width) + abs(left.height - height)
        let rightDistance = abs(right.width - width) + abs(right.height - height)
        return leftDistance < rightDistance
      })
    else { throw CameraCaptureError.noSupportedFormat }
    let maximumFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
    let fps = min(framesPerSecond, max(1, Int(maximumFPS)))
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      capturer.startCapture(with: device, format: format, fps: fps) { error in
        if let error {
          continuation.resume(
            throwing: CameraCaptureError.startFailed(error.localizedDescription)
          )
        } else {
          continuation.resume()
        }
      }
    }
  }

  public func stop() async {
    await withCheckedContinuation { continuation in
      capturer.stopCapture {
        continuation.resume()
      }
    }
  }
}
