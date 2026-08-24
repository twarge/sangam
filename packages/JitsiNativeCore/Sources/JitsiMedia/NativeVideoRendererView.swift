@preconcurrency import WebRTC

#if os(iOS)
  import UIKit

  @MainActor
  public final class NativeVideoRendererView: UIView {
    private let renderer = RTCMTLVideoView(frame: .zero)
    private var activeTrack: RTCVideoTrack?

    public override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
      clipsToBounds = true
      renderer.videoContentMode = .scaleAspectFill
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
