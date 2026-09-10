# WebRTC audio tap

This bridge uses the native `RTCAudioTrack.nativeAudioTrack` accessor and
`AudioTrackInterface.AddSink` in Jitsi WebRTC 124.0.2. It does not inspect object
memory or assume vtable offsets. The accessor is a WebRTC implementation API,
not an Apple private API. Keep the binary pinned and run the audio loopback
tests whenever upgrading it.

The unmodified C++ interface headers in Vendor come from Jitsi's M124 source
revision e7fccf32f8833bbe66b9ffdb73e5990af0809840. The transitive Abseil headers
come from the corresponding Chromium revision
0ee7acc04862615acafccb621c4cbf38974dc1e3. WebRTC's LICENSE and PATENTS and Abseil's
Apache license (ABSEIL_LICENSE) are included in Vendor.

One WebRTC decode thread writes into a fixed-size ring; one consumer calls
`drain`. Creation, drain and stop must be serialized by the caller. Overflow is
reported as a discontinuity. No Objective-C/Swift allocation, lock, inference,
file IO or task scheduling happens in the audio callback. The tap does not
change track enablement or playback volume. LocalAudioSource's AddSink is a
no-op, so this bridge explicitly rejects local tracks.
