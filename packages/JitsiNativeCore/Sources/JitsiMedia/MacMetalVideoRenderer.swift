#if os(macOS)
  import Foundation
  import MetalKit
  @preconcurrency import WebRTC

  final class MacMetalVideoRenderer: NSObject, RTCVideoRenderer, MTKViewDelegate,
    @unchecked Sendable
  {
    let view: MTKView

    /// Whether frames are cropped to cover the view or fitted whole inside
    /// it. Set from the main actor, read while drawing.
    var videoContentMode: VideoContentMode = .fill {
      didSet {
        guard videoContentMode != oldValue else { return }
        // The view is main-actor bound and this class is not, so the redraw
        // hops the same way a decoded frame's does.
        DispatchQueue.main.async { [weak view] in view?.needsDisplay = true }
      }
    }

    private let store = MacVideoFrameStore()
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    @MainActor
    override init() {
      guard
        let device = MTLCreateSystemDefaultDevice(),
        let commandQueue = device.makeCommandQueue()
      else { fatalError("Metal is required for native video rendering") }
      view = MTKView(frame: .zero, device: device)
      self.commandQueue = commandQueue
      do {
        pipeline = try Self.makePipeline(device: device, pixelFormat: view.colorPixelFormat)
      } catch {
        fatalError("Unable to create native video renderer: \(error)")
      }
      super.init()
      view.framebufferOnly = true
      view.enableSetNeedsDisplay = true
      view.isPaused = true
      view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      view.delegate = self
    }

    /// WebRTC reports the stream's own dimensions here, on its decode
    /// thread. The view above uses them to take the picture's shape rather
    /// than letterboxing it.
    nonisolated(unsafe) var onVideoSize: (@MainActor @Sendable (CGSize) -> Void)?

    func setSize(_ size: CGSize) {
      guard size.width > 0, size.height > 0, let onVideoSize else { return }
      Task { @MainActor in onVideoSize(size) }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
      store.update(frame)
      DispatchQueue.main.async { [weak view] in
        view?.needsDisplay = true
      }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
      // The fitted quad depends on the view's aspect ratio, so redraw the
      // frame already on screen instead of waiting for the next one.
      view.needsDisplay = true
    }

    func draw(in view: MTKView) {
      guard
        let packet = store.current(),
        let descriptor = view.currentRenderPassDescriptor,
        let drawable = view.currentDrawable,
        let device = view.device,
        let commandBuffer = commandQueue.makeCommandBuffer(),
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
        let yTexture = Self.texture(
          device: device,
          width: packet.width,
          height: packet.height,
          bytes: packet.y
        ),
        let uTexture = Self.texture(
          device: device,
          width: packet.chromaWidth,
          height: packet.chromaHeight,
          bytes: packet.u
        ),
        let vTexture = Self.texture(
          device: device,
          width: packet.chromaWidth,
          height: packet.chromaHeight,
          bytes: packet.v
        )
      else { return }

      let vertices = Self.vertices(
        videoWidth: packet.width,
        videoHeight: packet.height,
        rotation: packet.rotation,
        drawableSize: view.drawableSize,
        contentMode: videoContentMode
      )
      encoder.setRenderPipelineState(pipeline)
      vertices.withUnsafeBytes { storage in
        guard let address = storage.baseAddress else { return }
        encoder.setVertexBytes(address, length: storage.count, index: 0)
      }
      encoder.setFragmentTexture(yTexture, index: 0)
      encoder.setFragmentTexture(uTexture, index: 1)
      encoder.setFragmentTexture(vTexture, index: 2)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      encoder.endEncoding()
      commandBuffer.present(drawable)
      commandBuffer.commit()
    }

    private static func makePipeline(
      device: MTLDevice,
      pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
      let library = try device.makeLibrary(source: shaderSource, options: nil)
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "sangam_video_vertex")
      descriptor.fragmentFunction = library.makeFunction(name: "sangam_video_fragment")
      descriptor.colorAttachments[0].pixelFormat = pixelFormat
      return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func texture(
      device: MTLDevice,
      width: Int,
      height: Int,
      bytes: Data
    ) -> MTLTexture? {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm,
        width: width,
        height: height,
        mipmapped: false
      )
      descriptor.usage = .shaderRead
      guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
      bytes.withUnsafeBytes { storage in
        guard let address = storage.baseAddress else { return }
        texture.replace(
          region: MTLRegionMake2D(0, 0, width, height),
          mipmapLevel: 0,
          withBytes: address,
          bytesPerRow: width
        )
      }
      return texture
    }

    static func vertices(
      videoWidth: Int,
      videoHeight: Int,
      rotation: RTCVideoRotation,
      drawableSize: CGSize,
      contentMode: VideoContentMode
    ) -> [MacVideoVertex] {
      let rotated = rotation == ._90 || rotation == ._270
      let width = rotated ? videoHeight : videoWidth
      let height = rotated ? videoWidth : videoHeight
      let videoRatio = Float(width) / Float(max(height, 1))
      let viewRatio = Float(drawableSize.width / max(drawableSize.height, 1))
      // The slice of the frame that is sampled…
      var left: Float = 0
      var right: Float = 1
      var top: Float = 0
      var bottom: Float = 1
      // …and the slice of the view it is drawn into, in normalized device
      // coordinates where the whole view is the square from -1 to 1.
      var quadX: Float = 1
      var quadY: Float = 1
      switch contentMode {
      case .fill:
        // Trim the frame down to the view's shape: the drawn quad stays
        // edge to edge and the overhanging side is cropped away.
        if videoRatio > viewRatio {
          let visible = viewRatio / videoRatio
          left = (1 - visible) / 2
          right = 1 - left
        } else {
          let visible = videoRatio / max(viewRatio, 0.0001)
          top = (1 - visible) / 2
          bottom = 1 - top
        }
      case .fit:
        // Shrink the quad instead of the frame: every pixel the sender put
        // on the wire is drawn, and the black clear color fills the rest.
        if videoRatio > viewRatio {
          quadY = viewRatio / max(videoRatio, 0.0001)
        } else {
          quadX = videoRatio / max(viewRatio, 0.0001)
        }
      }

      func rotate(_ point: SIMD2<Float>) -> SIMD2<Float> {
        switch rotation {
        case ._90: SIMD2(1 - point.y, point.x)
        case ._180: SIMD2(1 - point.x, 1 - point.y)
        case ._270: SIMD2(point.y, 1 - point.x)
        default: point
        }
      }
      return [
        MacVideoVertex(position: SIMD2(-quadX, -quadY), texture: rotate(SIMD2(left, bottom))),
        MacVideoVertex(position: SIMD2(quadX, -quadY), texture: rotate(SIMD2(right, bottom))),
        MacVideoVertex(position: SIMD2(-quadX, quadY), texture: rotate(SIMD2(left, top))),
        MacVideoVertex(position: SIMD2(quadX, quadY), texture: rotate(SIMD2(right, top))),
      ]
    }

    private static let shaderSource = """
      #include <metal_stdlib>
      using namespace metal;

      struct VideoVertex { float2 position; float2 textureCoordinate; };
      struct RasterizerData { float4 position [[position]]; float2 textureCoordinate; };

      vertex RasterizerData sangam_video_vertex(
        uint vertexID [[vertex_id]],
        constant VideoVertex *vertices [[buffer(0)]]) {
        RasterizerData out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.textureCoordinate = vertices[vertexID].textureCoordinate;
        return out;
      }

      fragment float4 sangam_video_fragment(
        RasterizerData in [[stage_in]],
        texture2d<float> yTexture [[texture(0)]],
        texture2d<float> uTexture [[texture(1)]],
        texture2d<float> vTexture [[texture(2)]]) {
        constexpr sampler videoSampler(address::clamp_to_edge, filter::linear);
        float y = 1.16438356 * (yTexture.sample(videoSampler, in.textureCoordinate).r - 0.0625);
        float u = uTexture.sample(videoSampler, in.textureCoordinate).r - 0.5;
        float v = vTexture.sample(videoSampler, in.textureCoordinate).r - 0.5;
        float3 rgb = float3(
          y + 1.79274107 * v,
          y - 0.21324861 * u - 0.53290933 * v,
          y + 2.11240179 * u);
        return float4(saturate(rgb), 1.0);
      }
      """
  }

  struct MacVideoVertex {
    var position: SIMD2<Float>
    var texture: SIMD2<Float>
  }

  private struct MacVideoFramePacket: @unchecked Sendable {
    var width: Int
    var height: Int
    var chromaWidth: Int
    var chromaHeight: Int
    var rotation: RTCVideoRotation
    var y: Data
    var u: Data
    var v: Data
  }

  private final class MacVideoFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var packet: MacVideoFramePacket?

    func update(_ frame: RTCVideoFrame?) {
      guard let frame else {
        lock.withLock { packet = nil }
        return
      }
      let buffer = frame.buffer.toI420()
      let next = MacVideoFramePacket(
        width: Int(buffer.width),
        height: Int(buffer.height),
        chromaWidth: Int(buffer.chromaWidth),
        chromaHeight: Int(buffer.chromaHeight),
        rotation: frame.rotation,
        y: Self.copy(
          buffer.dataY,
          width: Int(buffer.width),
          height: Int(buffer.height),
          stride: Int(buffer.strideY)
        ),
        u: Self.copy(
          buffer.dataU,
          width: Int(buffer.chromaWidth),
          height: Int(buffer.chromaHeight),
          stride: Int(buffer.strideU)
        ),
        v: Self.copy(
          buffer.dataV,
          width: Int(buffer.chromaWidth),
          height: Int(buffer.chromaHeight),
          stride: Int(buffer.strideV)
        )
      )
      lock.withLock { packet = next }
    }

    func current() -> MacVideoFramePacket? {
      lock.withLock { packet }
    }

    private static func copy(
      _ source: UnsafePointer<UInt8>,
      width: Int,
      height: Int,
      stride: Int
    ) -> Data {
      var result = Data(count: width * height)
      result.withUnsafeMutableBytes { destination in
        guard let base = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
          return
        }
        for row in 0..<height {
          base.advanced(by: row * width).update(
            from: source.advanced(by: row * stride),
            count: width
          )
        }
      }
      return result
    }
  }
#endif
