@preconcurrency import WebRTC

/// How a decoded frame is fitted to the view drawing it.
public enum VideoContentMode: Sendable {
  /// Cover the whole view, cropping whatever falls outside it.
  case fill
  /// Scale until the entire frame is visible, letterboxing the remainder.
  case fit
}

#if os(iOS)
  import UIKit

  @MainActor
  public final class NativeVideoRendererView: UIView, RTCVideoViewDelegate {
    private let renderer = RTCMTLVideoView(frame: .zero)
    private var activeTrack: RTCVideoTrack?
    /// The stream's own dimensions, whenever they change. A caller that
    /// wants the picture's shape rather than bars around it sizes itself
    /// from this.
    public var onVideoSize: ((CGSize) -> Void)?

    /// Whether the sender's picture is cropped to cover this view or shown
    /// whole inside it. Stage and grid tiles fit, so nobody loses the sides
    /// of their frame; small thumbnails fill, where a full-bleed crop reads
    /// better than bars.
    public var videoContentMode: VideoContentMode = .fill {
      didSet {
        guard videoContentMode != oldValue else { return }
        applyContentMode()
      }
    }

    public override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
      clipsToBounds = true
      applyContentMode()
      renderer.delegate = self
      renderer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(renderer)
      NSLayoutConstraint.activate([
        renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
        renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
        renderer.topAnchor.constraint(equalTo: topAnchor),
        renderer.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public func display(_ track: RemoteVideoTrack?) {
      render(track?.track)
    }

    /// Renders the local camera or screen track for a self-preview.
    public func display(local track: LocalVideoTrack?) {
      render(track?.track)
    }

    public nonisolated func videoView(
      _ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize
    ) {
      Task { @MainActor [weak self] in
        guard size.width > 0, size.height > 0 else { return }
        self?.onVideoSize?(size)
      }
    }

    private func applyContentMode() {
      renderer.videoContentMode = videoContentMode == .fill ? .scaleAspectFill : .scaleAspectFit
    }

    private func render(_ track: RTCVideoTrack?) {
      guard activeTrack !== track else { return }
      activeTrack?.remove(renderer)
      activeTrack = track
      track?.add(renderer)
    }
  }
#elseif os(macOS)
  import AppKit

  @MainActor
  public final class NativeVideoRendererView: NSView {
    private let renderer: MacMetalVideoRenderer
    private var activeTrack: RTCVideoTrack?
    /// The stream's own dimensions, whenever they change.
    public var onVideoSize: ((CGSize) -> Void)? {
      didSet {
        let handler = onVideoSize
        renderer.onVideoSize = { size in handler?(size) }
      }
    }

    /// Whether the sender's picture is cropped to cover this view or shown
    /// whole inside it. Stage and grid tiles fit, so nobody loses the sides
    /// of their frame; small thumbnails fill, where a full-bleed crop reads
    /// better than bars.
    public var videoContentMode: VideoContentMode {
      get { renderer.videoContentMode }
      set { renderer.videoContentMode = newValue }
    }

    public override init(frame frameRect: NSRect) {
      renderer = MacMetalVideoRenderer()
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.backgroundColor = NSColor.black.cgColor
      addSubview(renderer.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
      super.layout()
      renderer.view.frame = bounds
    }

    public func display(_ track: RemoteVideoTrack?) {
      render(track?.track)
    }

    /// Renders the local camera or screen track for a self-preview.
    public func display(local track: LocalVideoTrack?) {
      render(track?.track)
    }

    private func render(_ track: RTCVideoTrack?) {
      guard activeTrack !== track else { return }
      activeTrack?.remove(renderer)
      activeTrack = track
      track?.add(renderer)
    }
  }
#endif
