# Architecture

## Product shape

Gafsaf is an Apple-native Jitsi client. SwiftUI owns the application shell,
AppKit and UIKit provide the platform surfaces, and one shared Swift conference
core owns both signaling and WebRTC media. No meeting UI or media pipeline runs
in WebKit, Chromium, React Native, or an iframe.

The selected remote video fills the window. Controls are a native overlay at
the bottom and never change the size of the video surface.

```text
SwiftUI application
  |-- full-window NativeVideoSurface
  |     `-- RTCMTLVideoView / WebRTC renderer
  |-- native bottom MeetingControlBar
  `-- AppleSystemIntegration
        |-- iOS: CallKit, AVAudioSession, video-call PiP
        `-- macOS: ScreenCaptureKit, audio-device routing

JitsiNativeCore
  |-- ConferenceSession          single public state machine
  |-- JitsiDiscovery             deployment configuration and endpoints
  |-- XMPPTransport              WebSocket/BOSH, SASL/JWT, MUC presence
  |-- JingleSession              SDP, ICE, source add/remove, restart
  |-- BridgeChannel              Colibri endpoint and receiver messages
  |-- MediaEngine                peer connection, tracks, stats, devices
  `-- SharingEngine              ScreenCaptureKit / ReplayKit sources
             |
             `-- Jitsi WebRTC XCFramework
```

One transition adapter remains: iOS can still be switched to `JitsiMeetSDK`.
The macOS `WKWebView` iframe adapter has been removed, so macOS runs only the
native core. The iOS adapter is a bootstrap transport, not part of the target
architecture, and is removed when the native core reaches the first end-to-end
conference milestone.

The debug-only native path now owns live XMPP bootstrap, Jingle/SDP translation,
WebRTC offer-answer and trickled ICE, platform frame producers, remote-track
events, and full-window Metal rendering. The remaining gate is deployment
interoperability plus source renegotiation, transport replacement, and reconnect
hardening before this path becomes the release default.

## Dependency direction

`MeetingController` is the application-facing boundary. It consumes immutable
conference snapshots and sends typed intents. It must not import WebRTC, XMPP,
ScreenCaptureKit, ReplayKit, CallKit, or AVKit.

```text
Views -> MeetingController -> ConferenceSession -> protocol/media modules
                                      |
                                      `-> AppleSystemIntegration
```

Platform frameworks may depend on core models. The conference core may not
depend on SwiftUI. This keeps protocol tests headless and prevents call state
from becoming coupled to a particular window.

## Conference session

`ConferenceSession` is the only owner of meeting lifecycle state. Public state
is emitted as a snapshot containing:

- connection phase and recoverability;
- local microphone, camera, and sharing publication state;
- participants and their advertised media sources;
- selected video source, dominant speaker, and connection quality;
- available cameras, microphones, speakers, and share sources;
- active system call, audio route, and Picture in Picture state.

Commands are serialized through the session actor. Join, reconnect, track
replacement, screen sharing, CallKit actions, and hangup therefore cannot race
one another.

The initial implementation supports a pinned, self-hosted Jitsi deployment and
Jitsi Videobridge conferences only. Peer-to-peer switching is disabled until
the bridge path is production-stable.

## Signaling contract

The native core implements the client behavior presently supplied by
`lib-jitsi-meet`:

1. Discover XMPP WebSocket/BOSH and bridge-channel endpoints for the configured
   deployment.
2. Authenticate anonymously or with the deployment JWT and join the conference
   MUC.
3. Maintain participant presence, occupant identity, roles, and advertised
   source metadata. When the room is members-only, wait in its lobby until a
   moderator decides; as a moderator, watch the lobby and admit or deny.
4. Accept Jicofo Jingle sessions, negotiate unified-plan SDP, and maintain ICE
   and DTLS state with Jitsi Videobridge.
5. Signal source add/remove and desktop video type whenever local publications
   change.
6. Exchange Colibri endpoint messages, receiver constraints, `lastN`, selected
   sources, dominant-speaker events, and connection-quality data.
7. Rejoin safely after network changes and ICE failure without duplicating
   local sources.

Server compatibility is a versioned product contract. CI tests the client
against the exact Jitsi server release deployed in production; upgrades are
explicit compatibility projects rather than unbounded best-effort support for
arbitrary public installations.

## Media and rendering

Jitsi's native WebRTC XCFramework supplies peer connections, codecs, capture,
hardware acceleration, audio processing, and Metal-backed rendering. Gafsaf
owns source selection and layout.

- The selected remote track renders aspect-fill and crops at the window edge.
- Camera and screen are separate publications when the server supports
  multistream; the fallback replaces camera with desktop on older deployments.
- Audio uses Opus. The first video interoperability set is H.264 plus VP8.
- Simulcast encoding and receiver constraints are explicit, not inferred from
  view size on arbitrary threads.
- Track identity is keyed by Jitsi source name rather than WebRTC track ID.

## Screen and window sharing

### macOS

ScreenCaptureKit enumerates `SCDisplay`, `SCRunningApplication`, and `SCWindow`
content. A native picker returns a stable selection used to construct an
`SCContentFilter` and `SCStream`. Video sample buffers are converted to WebRTC
frames and published as a desktop source.

The sharing engine:

- excludes Gafsaf's own windows by default;
- follows a selected window across displays;
- stops cleanly when the source closes or permission is revoked;
- adapts frame rate and resolution independently from camera video;
- reports the macOS Screen Recording permission state before joining media;
- optionally captures system audio only after microphone-plus-desktop-audio
  behavior is verified against the pinned bridge release.

### iOS and iPadOS

ReplayKit supplies whole-device frames through a Broadcast Upload Extension.
The extension is capture-only: the containing app remains the sole Jitsi
endpoint and encodes/publishes the desktop track. App-group transport uses a
bounded queue and drops stale video frames instead of back-pressuring ReplayKit.

iOS does not expose arbitrary application-window selection. Users share the
whole device display using the system broadcast picker.

## Apple system integration

### Picture in Picture

iOS uses `AVPictureInPictureVideoCallViewController` and a video-call content
source. The PiP renderer follows the session's selected remote source and can
switch to the current presenter without rebuilding the peer connection. Camera
multitasking remains enabled while PiP is active.

On macOS, the meeting window uses native window management. A compact floating
meeting window is an app feature rather than AVKit playback PiP.

### CallKit

One process-wide `CXProvider` and `CXCallController` map an active conference to
one call UUID. Join, mute, hold, and end actions flow through
`ConferenceSession`; CallKit never mutates WebRTC directly. Incoming-call
support requires a real invitation service and PushKit and is not simulated by
ordinary Jitsi room URLs.

### Audio routing

On iOS, CallKit activation owns the lifetime of `AVAudioSession`. WebRTC audio
starts only after `provider(_:didActivate:)` and pauses on deactivation. Route
selection presents the native route picker and reflects receiver, speaker,
Bluetooth, AirPlay, and wired routes.

On macOS, the media engine observes capture/render devices and route changes.
Device selection is exposed through a native menu and reapplied after devices
are connected or removed.

## Security and privacy

- Only HTTPS meeting servers are accepted, except `http://localhost` in debug
  development builds.
- JWTs and credentials are supplied by an authentication service and are never
  persisted in logs or user defaults.
- Camera, microphone, screen recording, and ReplayKit permissions are requested
  just in time with a user-visible explanation.
- The ReplayKit extension and app share only the named app-group container.
- XMPP XML, SDP, and bridge messages are treated as untrusted network input and
  parsed with explicit size and depth bounds.
- Release builds disable protocol payload logging by default.

## Delivery gates

1. **Protocol harness:** discovery, authenticated XMPP, MUC presence, and XML
   fixture tests against a pinned deployment.
2. **Native media:** two native clients exchange audio and one camera source
   through Jitsi Videobridge on iOS and macOS.
3. **Desktop publication:** macOS window/display sharing and iOS ReplayKit are
   visible to the stock Jitsi web client as desktop sources.
4. **Product UX:** full-window renderer, device menus, reconnection, PiP,
   CallKit, interruption handling, and accessibility.
5. **Release hardening:** long-call soak tests, network handoff, Bluetooth route
   churn, extension termination, permission revocation, and server upgrade
   compatibility.

The WebKit adapter is already deleted. The iOS SDK adapter is deleted at gate 2,
not maintained as a hidden fallback conference engine.
