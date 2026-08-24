# Third-party notices

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
