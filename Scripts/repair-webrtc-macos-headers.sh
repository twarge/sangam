#!/bin/bash
# Copyright (C) 2026 Twarge LLC
# SPDX-License-Identifier: Apache-2.0
#
# Restores the Objective-C headers missing from the macOS slice of Jitsi's
# WebRTC 155.0.1 xcframework. That release's macos-arm64_x86_64 Headers holds
# only the umbrella WebRTC.h, so nothing that imports WebRTC compiles for the
# Mac. Every header the umbrella imports is copied in: from the iOS simulator
# slice of the same release, which ships them unchanged, or, for the one
# AppKit-only header, from webrtc-macos-headers/ beside this script. Headers
# already present are left alone, so a fixed release makes this a no-op.
#
# Run it after package resolution has extracted the xcframework and before
# anything builds against it; the Makefile's webrtc-headers targets do both.
#
#   Scripts/repair-webrtc-macos-headers.sh path/to/WebRTC.xcframework ...

set -euo pipefail

vendored="$(cd "$(dirname "$0")" && pwd)/webrtc-macos-headers"

[ "$#" -gt 0 ] || { echo "usage: $0 WebRTC.xcframework ..." >&2; exit 2; }

for xcframework in "$@"; do
  mac="$xcframework/macos-arm64_x86_64/WebRTC.framework/Versions/A/Headers"
  simulator="$xcframework/ios-arm64_x86_64-simulator/WebRTC.framework/Headers"
  [ -f "$mac/WebRTC.h" ] || { echo "error: no macOS WebRTC.h in $xcframework" >&2; exit 1; }

  restored=0
  for header in $(sed -n 's|^#import <WebRTC/\(.*\)>.*|\1|p' "$mac/WebRTC.h"); do
    [ -f "$mac/$header" ] && continue
    if [ -f "$vendored/$header" ]; then
      cp "$vendored/$header" "$mac/"
    elif [ -f "$simulator/$header" ]; then
      cp "$simulator/$header" "$mac/"
    else
      echo "error: no copy of $header to restore in $xcframework" >&2
      exit 1
    fi
    restored=$((restored + 1))
  done
  echo "==> Restored $restored WebRTC macOS headers in $xcframework"
done
