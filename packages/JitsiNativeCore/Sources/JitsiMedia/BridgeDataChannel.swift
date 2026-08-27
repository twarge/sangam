import Foundation

@preconcurrency import WebRTC

/// The bridge channel as a WebRTC data channel — how deployments without
/// colibri websockets (meet.jit.si) carry receiver video constraints and the
/// bridge's control messages. Wraps the `RTCDataChannel` so callers outside
/// this module never touch WebRTC types: they read `events` and call `send`.
///
/// `@unchecked` because `RTCDataChannel` is not Sendable; every use of it here
/// is either from the delegate callbacks (WebRTC's own signaling thread) or a
/// thread-safe libwebrtc entry point (`sendData`, `close`).
public final class BridgeDataChannel: NSObject, @unchecked Sendable {
  public enum Event: Sendable {
    case opened
    case message(Data)
    case closed
  }

  public let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let channel: RTCDataChannel

  init(channel: RTCDataChannel) {
    self.channel = channel
    (events, continuation) = AsyncStream.makeStream(
      of: Event.self, bufferingPolicy: .bufferingNewest(256))
    super.init()
    channel.delegate = self
    // Created after the SCTP association is already up? Then no state-change
    // callback is coming — report the channel usable now.
    if channel.readyState == .open { continuation.yield(.opened) }
  }

  /// Sends one colibri message. Text, as the reference client sends them.
  public func send(raw data: Data) {
    channel.sendData(RTCDataBuffer(data: data, isBinary: false))
  }

  public func close() {
    channel.delegate = nil
    channel.close()
    continuation.finish()
  }
}

extension BridgeDataChannel: RTCDataChannelDelegate {
  public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    switch dataChannel.readyState {
    case .open: continuation.yield(.opened)
    case .closed: continuation.yield(.closed)
    default: break
    }
  }

  public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer)
  {
    continuation.yield(.message(buffer.data))
  }
}
