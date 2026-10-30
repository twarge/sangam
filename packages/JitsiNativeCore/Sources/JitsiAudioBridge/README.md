# WebRTC audio tap

This bridge uses the native `RTCAudioTrack.nativeAudioTrack` accessor and
`AudioTrackInterface.AddSink` in Jitsi WebRTC 155.0.1. It does not inspect object
memory or assume vtable offsets. The accessor is a WebRTC implementation API,
not an Apple private API. Keep the binary pinned and run the audio loopback
tests whenever upgrading it.

The unmodified C++ interface headers in Vendor come from Jitsi's M155 source
revision 623fcfe044d5037b3ecd92001c2ef80ca1d932d5 (tag v155.0.1): exactly the
closure of `api/media_stream_interface.h`. The transitive Abseil headers come
from the Chromium third_party revision that release's DEPS pins,
74ec8c2ee533c9eb78e660876c6fa12d47626176. WebRTC's LICENSE and PATENTS and
Abseil's Apache license (ABSEIL_LICENSE) are included in Vendor. These headers
require C++20. Replace Vendor wholesale on an upgrade; files move between
releases.

WebRTC calls the sink's virtual `OnData` overloads by slot, so headers from
another release still compile and attach while the tap silently hears nothing.
`remoteAudioReachesTheTapOverLoopback` catches that; the attachment test alone
does not.

One WebRTC decode thread writes into a fixed-size ring; one consumer calls
`drain`. Creation, drain and stop must be serialized by the caller. Overflow is
reported as a discontinuity. No Objective-C/Swift allocation, lock, inference,
file IO or task scheduling happens in the audio callback. The tap does not
change track enablement or playback volume. LocalAudioSource's AddSink is a
no-op, so this bridge explicitly rejects local tracks.
