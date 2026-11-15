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
# anything builds against it. The Makefile's webrtc-headers targets do both for
# command-line builds. Builds started in Xcode get it from the Sangam scheme's
# pre-build action, because Xcode extracts its own copy afresh — headers
# missing again — whenever it re-resolves packages.
#
#   Scripts/repair-webrtc-macos-headers.sh path/to/WebRTC.xcframework ...
#   Scripts/repair-webrtc-macos-headers.sh --xcode    # scheme pre-build action

set -euo pipefail

vendored="$(cd "$(dirname "$0")" && pwd)/webrtc-macos-headers"
slice="macos-arm64_x86_64/WebRTC.framework/Versions/A/Headers"

repair() {
  local xcframework="$1"
  local mac="$xcframework/$slice"
  local simulator="$xcframework/ios-arm64_x86_64-simulator/WebRTC.framework/Headers"
  [ -f "$mac/WebRTC.h" ] || { echo "error: no macOS WebRTC.h in $xcframework" >&2; exit 1; }

  local restored=0 header
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
}

if [ "${1:-}" = "--xcode" ]; then
  # Xcode keeps packages beside its build folder, wherever DerivedData is. With
  # nothing extracted there — packages not resolved yet, or kept somewhere this
  # cannot guess — there is nothing to repair, and that is not a failure.
  [ -n "${BUILD_DIR:-}" ] || exit 0
  xcframework="${BUILD_DIR%/Build/*}/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework"
  [ -f "$xcframework/$slice/WebRTC.h" ] || exit 0
  repair "$xcframework"

  # An earlier build may already have copied the bare slice into its products,
  # and Xcode does not copy it again just because headers appeared at the
  # source.
  for product in "$BUILD_DIR"/*/WebRTC.framework/Versions/A/Headers; do
    [ -d "$product" ] || continue
    for header in "$xcframework/$slice"/*.h; do
      [ -f "$product/$(basename "$header")" ] || cp "$header" "$product/"
    done
  done
  exit 0
fi

[ "$#" -gt 0 ] || { echo "usage: $0 WebRTC.xcframework ... | --xcode" >&2; exit 2; }

for xcframework in "$@"; do
  repair "$xcframework"
done
