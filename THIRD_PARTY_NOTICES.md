# Third-party notices

## WebRTC audio bridge headers

`packages/JitsiNativeCore/Sources/JitsiAudioBridge/Vendor` contains unmodified
WebRTC M155 interface headers from Jitsi revision
`623fcfe044d5037b3ecd92001c2ef80ca1d932d5`, distributed under the BSD license and
patent grant in `Vendor/LICENSE` and `Vendor/PATENTS`. Transitive Abseil headers
come from Chromium third_party revision `74ec8c2ee533c9eb78e660876c6fa12d47626176`
and are distributed under Apache 2.0 in `Vendor/ABSEIL_LICENSE`. The source
files retain their copyright notices. Include these notices when distributing
the app.

## Jitsi Meet

Copyright 8x8, Inc., Atlassian Pty Ltd, and Jitsi contributors.

Jitsi Meet, lib-jitsi-meet, the transitional Jitsi Meet iOS SDK, and the
screen-sharing protocol on which the ReplayKit extension is based are
distributed under the Apache License, Version 2.0. The license text is available
at:

https://www.apache.org/licenses/LICENSE-2.0

Source projects:

- https://github.com/jitsi/jitsi-meet
- https://github.com/jitsi/lib-jitsi-meet
- https://github.com/jitsi/webrtc
- https://github.com/jitsi/jitsi-meet-ios-sdk-releases
- https://github.com/jitsi/jitsi-meet-sdk-samples

Before distributing an application binary, generate acknowledgments for the
resolved Swift package graph as well. The Jitsi SDK currently brings additional
binary and source dependencies, including Jitsi WebRTC, Hermes, and Giphy. The
target native client retains applicable Apache notices when behavior or source
is ported from lib-jitsi-meet. Jitsi WebRTC also contains third-party components
under their own permissive licenses; ship the license inventory generated from
the exact pinned binary release.
