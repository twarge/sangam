#if os(iOS)
  import AVFoundation
  import Foundation

  @preconcurrency import WebRTC

  /// CallKit owns audio-session activation: the system activates the
  /// session when the call starts (possibly before the app is foreground)
  /// and deactivates it when the call ends. WebRTC must wait for those
  /// callbacks instead of starting its audio units on its own, which is
  /// what manual-audio mode does.
  public enum CallKitAudioBridge {
    /// Puts WebRTC's audio session into manual mode. Call once, before any
    /// call's audio units start.
    public static func prepare() {
      let session = RTCAudioSession.sharedInstance()
      session.useManualAudio = true
      session.isAudioEnabled = false
    }

    /// CallKit failed to start the call: run audio the ordinary way so the
    /// meeting still has sound.
    public static func runWithoutCallKit() {
      let session = RTCAudioSession.sharedInstance()
      session.useManualAudio = false
      session.isAudioEnabled = true
    }

    public static func audioSessionDidActivate(_ session: AVAudioSession) {
      let rtcSession = RTCAudioSession.sharedInstance()
      rtcSession.audioSessionDidActivate(session)
      rtcSession.isAudioEnabled = true
    }

    public static func audioSessionDidDeactivate(_ session: AVAudioSession) {
      let rtcSession = RTCAudioSession.sharedInstance()
      rtcSession.audioSessionDidDeactivate(session)
      rtcSession.isAudioEnabled = false
    }
  }
#endif
