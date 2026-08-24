# Sangam

A deliberately small Apple-native Jitsi client for iOS and macOS. The meeting
video owns the window; the native interface is a compact bottom toolbar for
microphone, camera, screen sharing, and hangup. The product target uses a shared
Swift conference core and native WebRTC rendering with no WebKit, Chromium, or
React Native meeting surface.

The repository follows the Twarge Calcium layout: application code lives under
`apps/`, the checked-in Xcode project is opened directly, and Make targets run
the same schemes and destinations as Xcode.

```bash
make project      # only needed after editing apps/project.yml
make test         # native Jitsi protocol and state tests
make mac
make ios
make ios-device   # signing and the ReplayKit extension need a real device
make format
```

Open `apps/Sangam.xcodeproj` for normal development. Xcode resolves the official
Jitsi iOS SDK Swift package at version 13.1.1.

## Structure

```text
apps/Sangam/Sources/                 shared SwiftUI app and platform integration
apps/SangamBroadcastExtension/       bounded ReplayKit frame uploader
apps/Sangam.xcodeproj/               checked-in Xcode project
apps/project.yml                     reproducible XcodeGen project description
packages/JitsiNativeCore/            shared state and protocol implementation
docs/ARCHITECTURE.md                 target native architecture and delivery gates
docs/NATIVE_CORE.md                  package layout, scope, and verification plan
THIRD_PARTY_NOTICES.md               redistribution notes
```

## Transition status

- iOS uses `JitsiMeetSDK` and the official ReplayKit socket protocol. Camera,
  microphone, camera switching, hangup, and device screen sharing are connected
  to the native toolbar.
- macOS has no fallback transport. The `WKWebView` iframe adapter has been
  removed, so macOS always runs the native core.

The iOS adapter is the last remaining fallback transport. Both platforms default
to `JitsiNativeCore`, the Jitsi WebRTC XCFramework, and native platform capture.
Set `SANGAM_LEGACY_JITSI=1` on iOS only when explicitly testing that adapter; the
variable has no effect on macOS.

The native core now includes bounded XMPP WebSocket transport, SASL and resource
binding, Jicofo focus allocation, MUC presence/source state, Jitsi lobby support
(waiting to be admitted, and admitting or denying lobby participants as a
host), typed Jingle and Colibri messages, deployment discovery, Jingle-to-SDP offer translation,
WebRTC-answer-to-Jingle serialization, trickled ICE support, and a pinned Jitsi
WebRTC media factory. The default native path connects those pieces to a live
conference coordinator and full-window Metal renderer. Native macOS
ScreenCaptureKit and iOS ReplayKit capture publish a retained desktop sender
through Jitsi source-add signaling, source presence updates, and native WebRTC
renegotiation. Reconnect and production interoperability hardening remain.

The default server is `https://meet.jit.si`; self-hosted HTTPS Jitsi servers can
be entered on the join screen. Plain HTTP is accepted only for `localhost`.
