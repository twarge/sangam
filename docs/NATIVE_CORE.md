# JitsiNativeCore implementation plan

This document translates the target architecture into source packages and
testable work. It deliberately separates protocol correctness from product UI.

## Current status

The foundation milestone is implemented and linked into both application
targets:

- immutable conference, participant, publication, and source models;
- an actor-isolated conference state machine with validated transitions;
- bounded, entity-free XMPP XML parsing and safe XML serialization;
- typed Jingle session, RTP source, ICE, and DTLS parsing;
- typed Colibri events and receiver-video-constraint encoding;
- controlled-deployment manifest discovery with a conventional endpoint
  fallback;
- live XMPP WebSocket transport with bounded frames;
- anonymous and PLAIN SASL negotiation, stream restart, and resource binding;
- correlated Jicofo IQ requests and initial MUC join/self-presence handling;
- a Jitsi WebRTC 124.0.2 media factory for unified-plan peer connections and
  native microphone, camera, and screencast tracks;
- complete Jingle offer-to-SDP and WebRTC-answer-to-session-accept translation,
  including BUNDLE, codecs, feedback, RTP extensions, ICE/DTLS, and SSRC groups;
- an actor-isolated native peer-connection negotiator for offers, answers,
  trickled ICE candidates, ICE restart, and close;
- a live native coordinator for discovery, XMPP bootstrap, focus allocation,
  MUC join, Jingle IQ acknowledgement, session acceptance, and ICE signaling;
- remote WebRTC track events and platform Metal aspect-fill renderers (including
  an in-house macOS I420 renderer because Jitsi's binary omits its declared
  `RTCMTLNSVideoView` implementation);
- a direct CVPixelBuffer media input, zero-copy macOS system window/display
  capture, plus the bounded iOS ReplayKit app-group receiver;
- Jitsi-compatible desktop source publication, retained-sender mute/reuse,
  source-add IQs, MUC source presence, and incoming source-add/remove
  renegotiation;
- Bridge-only by design: the coordinator answers Jingle only from the room
  focus and declines a peer's peer-to-peer `session-initiate` (a web client
  attempts direct P2P when only two participants are present), so a peer
  never receives an SDP the native path cannot support;
- Jitsi lobby support on both sides: a members-only refusal sends the client
  to the lobby room to wait for a moderator's invitation or kick, and a
  moderator learns the lobby address from the room's disco#info, watches the
  lobby room, and admits (mediated invite) or denies (kick) who is waiting;
- 40 unit tests covering lifecycle, negotiation, parsing, bounds, buffering,
  and serialization.

The native coordinator and renderer are the default meeting implementation.
The transition adapters can be selected explicitly with
`SANGAM_LEGACY_JITSI=1`. The next milestone is integration testing against the
pinned deployment, reconnect behavior, and the remaining Apple integrations.
Current lib-jitsi-meet does not implement client-side `transport-replace`, so
the native coordinator acknowledges and reports it without unsafe mutation.

## Package layout

```text
packages/JitsiNativeCore/
  Package.swift
  Sources/
    JitsiNativeCore/
      ConferenceSession.swift
      ConferenceSnapshot.swift
      Participant.swift
      MediaSource.swift
    JitsiDiscovery/
      DeploymentConfiguration.swift
      DiscoveryClient.swift
    JitsiXMPP/
      XMLStream.swift
      XMPPClient.swift
      MultiUserChat.swift
      Authentication.swift
    JitsiJingle/
      JingleSession.swift
      JingleIQ.swift
      SDP.swift
      SourceSignaling.swift
    JitsiBridge/
      BridgeChannel.swift
      ColibriMessage.swift
      ReceiverConstraints.swift
    JitsiMedia/
      PeerConnectionEngine.swift
      LocalTrack.swift
      RemoteTrack.swift
      DeviceManager.swift
      Statistics.swift
    JitsiAppleIntegration/
      AudioSessionController.swift
      CallController.swift
      PictureInPictureController.swift
      ScreenSharingController.swift
  Tests/
    JitsiXMPPTests/Fixtures/
    JitsiJingleTests/Fixtures/
    JitsiBridgeTests/Fixtures/
    JitsiNativeCoreTests/
```

The first package commit should contain models, protocols, parsers, and fixture
tests. It should not contain placeholder networking that reports a successful
conference without a negotiated bridge connection.

## Public API

The app should need only one long-lived object:

```swift
public actor ConferenceSession {
  public nonisolated let updates: AsyncStream<ConferenceSnapshot>

  public func join(_ request: JoinRequest) async throws
  public func setMicrophoneMuted(_ muted: Bool) async
  public func setCameraEnabled(_ enabled: Bool) async throws
  public func publishShare(_ source: ShareSource) async throws
  public func stopSharing() async
  public func selectVideo(_ sourceID: MediaSource.ID?) async
  public func selectAudioRoute(_ route: AudioRoute.ID) async throws
  public func leave() async
}
```

`ConferenceSnapshot` is `Sendable`, equatable, and independent of WebRTC
objects. Rendering binds a `MediaSource.ID` to a platform renderer through a
small `VideoRendererRegistry`; tracks never leak into SwiftUI state.

## First supported deployment profile

- One controlled, version-pinned Jitsi Meet deployment.
- XMPP over WebSocket.
- Anonymous rooms plus JWT-authenticated rooms.
- Jitsi Videobridge only; P2P disabled in server and client configuration.
- One microphone source, one camera source, and one desktop source per endpoint.
- Opus audio; H.264 and VP8 video.
- Lobby rooms are supported (wait, admit, deny); switching the lobby on or off
  from the client is not.
- No password-protected rooms, breakout rooms, recording, livestreaming,
  transcription, remote control, or end-to-end encryption in the first
  release.

Unsupported server features must fail explicitly or remain absent. They must
not be silently approximated in the UI.

## Screen-sharing publication sequence

```text
User chooses Share
  -> platform picker returns ShareSource
  -> capture permission is confirmed
  -> capture produces bounded video-frame stream
  -> MediaEngine creates desktop RTCRtpSender/transceiver
  -> Jingle signals source name, SSRC/RID metadata, and video type desktop
  -> BridgeChannel selects sender constraints
  -> ConferenceSnapshot reports sharing only after publication is acknowledged
```

Stopping reverses that order: signal source removal, stop the sender, then stop
capture. On failure the state machine returns to camera-only publication and
reports a recoverable error.

## Verification matrix

Each release candidate is exercised against a stock browser client and another
native client.

| Scenario | macOS | iPhone | iPad |
|---|---:|---:|---:|
| Join, reconnect, leave | yes | yes | yes |
| Camera and microphone | yes | yes | yes |
| Bluetooth/wired route changes | yes | yes | yes |
| Window share | yes | n/a | n/a |
| Display/device-screen share | yes | yes | yes |
| Share while camera remains published | yes | yes | yes |
| PiP during remote presentation | n/a | yes | yes |
| Call interruption and recovery | n/a | yes | yes |
| Wi-Fi to cellular handoff | n/a | yes | yes |
| Permission revoked mid-call | yes | yes | yes |

Protocol fixtures are captured from the pinned deployment with secrets and
participant identifiers removed. CI validates parsing, serialization, state
transitions, and unexpected-message handling before device integration tests.

## Migration from the scaffold

1. Add `JitsiNativeCore` and Jitsi's `WebRTC` Swift package product without
   changing the current meeting adapters.
2. Connect a headless native session to the integration deployment and land
   protocol fixtures and tests. **In progress:** the live coordinator is built;
   deployment interoperability and reconnect remain.
3. Add native Metal video surfaces behind a development-only transport switch.
   **Complete.**
4. Complete audio, camera, sharing publication, and reconnect behavior on both
   platforms.
5. Replace the remaining iOS SDK adapter and remove `JitsiMeetSDK`. The macOS
   WebKit adapter is already removed. **In progress.**
6. Add ScreenCaptureKit, ReplayKit, PiP, CallKit, and device-route product UI.

The temporary transport switch must never ship in a release build. There is one
conference implementation when the native core reaches the product target.
