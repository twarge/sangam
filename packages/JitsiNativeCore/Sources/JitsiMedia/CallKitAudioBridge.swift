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
    ///
    /// The session runs in `.videoChat` rather than WebRTC's default
    /// `.voiceChat`: the same voice-processing unit, echo cancellation and
    /// all, but routed to the speaker instead of the earpiece. On the
    /// earpiece iOS treats the side button as End Call, so locking the phone
    /// hung up the meeting; on the speaker it only locks the screen.
    public static func prepare() {
      let configuration = RTCAudioSessionConfiguration.webRTC()
      configuration.mode = AVAudioSession.Mode.videoChat.rawValue
      configuration.categoryOptions.insert(.defaultToSpeaker)
      RTCAudioSessionConfiguration.setWebRTC(configuration)
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

    /// Turns on WebRTC's own logging, so the audio device's handling of the
    /// session — configure, activate, audio unit start — lands in the
    /// console beside the app's events.
    public static func enableVerboseLogging() {
      RTCSetMinDebugLogLevel(.info)
    }

    /// The audio session as WebRTC sees it, in one line.
    public static var diagnosticState: String {
      let rtc = RTCAudioSession.sharedInstance()
      let session = AVAudioSession.sharedInstance()
      let inputs = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
      let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
      return "manual=\(rtc.useManualAudio) enabled=\(rtc.isAudioEnabled) active=\(rtc.isActive)"
        + " category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
        + " inputs=[\(inputs)] outputs=[\(outputs)] otherAudio=\(session.isOtherAudioPlaying)"
        + " mic=\(AVAudioApplication.shared.recordPermission.rawValue)"
    }
  }
#endif
