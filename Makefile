# Builds the native Sangam clients using the same schemes as Xcode.
#
#   make             native-core tests + macOS + iOS simulator builds
#   make test        native conference-core unit tests
#   make media       compile the native WebRTC and conference targets
#   make mac         macOS debug build
#   make ios         iOS simulator build
#   make ios-device  signed generic iOS device build
#   make format      format all Swift sources
#   make project     regenerate the checked-in Xcode project
#   make icon        regenerate the checked-in app icon
#   make clean

.PHONY: all project icon format webrtc-headers app-webrtc-headers test stage-webrtc media mac ios \
  ios-device clean

all: test mac ios

project:
	xcodegen generate --spec apps/project.yml --project apps

icon:
	python3 Scripts/make-app-icon.py

format:
	swift format --in-place --recursive apps/Sangam apps/SangamBroadcastExtension \
	  packages/JitsiNativeCore/Sources packages/JitsiNativeCore/Tests

# Jitsi's WebRTC 155.0.1 xcframework ships a macOS slice with only the
# umbrella WebRTC.h, so the Mac build of anything importing WebRTC fails.
# Resolving extracts the xcframework; the script then restores the headers in
# place before anything compiles against it. SwiftPM and Xcode each keep their
# own extracted copy. Drop both targets once Jitsi publishes a fixed release.
WEBRTC_XCFRAMEWORK = artifacts/webrtc/WebRTC/WebRTC.xcframework

webrtc-headers:
	@swift package --package-path packages/JitsiNativeCore resolve
	@Scripts/repair-webrtc-macos-headers.sh packages/JitsiNativeCore/.build/$(WEBRTC_XCFRAMEWORK)

app-webrtc-headers:
	@xcodebuild -resolvePackageDependencies -project apps/Sangam.xcodeproj -scheme Sangam \
	  -derivedDataPath build/DerivedData -quiet
	@Scripts/repair-webrtc-macos-headers.sh build/DerivedData/SourcePackages/$(WEBRTC_XCFRAMEWORK)

# SwiftPM does not embed a binary xcframework next to its test bundles, so
# dyld cannot resolve @rpath/WebRTC.framework when JitsiConferenceTests loads.
# PackageFrameworks is already on the bundle's search path, so staging the
# framework there is enough. Xcode embeds it for the app targets and needs none
# of this.
stage-webrtc: webrtc-headers
	@swift build --package-path packages/JitsiNativeCore --target JitsiMedia >/dev/null
	@bin="$$(swift build --package-path packages/JitsiNativeCore --show-bin-path)"; \
	  mkdir -p "$$bin/PackageFrameworks"; \
	  ln -sfn ../WebRTC.framework "$$bin/PackageFrameworks/WebRTC.framework"

test: stage-webrtc
	swift test --package-path packages/JitsiNativeCore

# Serially, for CI: coordinator tests construct real WebRTC factories, and on
# a headless runner concurrent first-touch CoreAudio init deadlocks — freezing
# the whole parallel run. One at a time, each init completes.
test-ci: stage-webrtc
	swift test --package-path packages/JitsiNativeCore --no-parallel

media: webrtc-headers
	swift build --package-path packages/JitsiNativeCore --target JitsiMedia
	swift build --package-path packages/JitsiNativeCore --target JitsiConference

mac: app-webrtc-headers
	xcodebuild -project apps/Sangam.xcodeproj -scheme Sangam \
	  -destination "platform=macOS" -derivedDataPath build/DerivedData \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built Sangam for macOS"

ios:
	xcodebuild -project apps/Sangam.xcodeproj -scheme Sangam \
	  -destination "generic/platform=iOS Simulator" \
	  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet build
	@echo "==> Built Sangam for iOS Simulator"

ios-device:
	xcodebuild -project apps/Sangam.xcodeproj -scheme Sangam \
	  -destination "generic/platform=iOS" -derivedDataPath build/DerivedData \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built Sangam for iOS device"

clean:
	xcodebuild -project apps/Sangam.xcodeproj -scheme Sangam clean
