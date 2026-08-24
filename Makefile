# Builds the native Gafsaf clients using the same schemes as Xcode.
#
#   make             native-core tests + macOS + iOS simulator builds
#   make test        native conference-core unit tests
#   make media       compile the native WebRTC and conference targets
#   make mac         macOS debug build
#   make ios         iOS simulator build
#   make ios-device  signed generic iOS device build
#   make format      format all Swift sources
#   make project     regenerate the checked-in Xcode project
#   make clean

.PHONY: all project format test stage-webrtc media mac ios ios-device clean

all: test mac ios

project:
	xcodegen generate --spec apps/project.yml --project apps

format:
	swift format --in-place --recursive apps/Gafsaf apps/GafsafBroadcastExtension \
	  packages/JitsiNativeCore/Sources packages/JitsiNativeCore/Tests

# SwiftPM does not embed a binary xcframework next to its test bundles, so
# dyld cannot resolve @rpath/WebRTC.framework when JitsiConferenceTests loads.
# PackageFrameworks is already on the bundle's search path, so staging the
# framework there is enough. Xcode embeds it for the app targets and needs none
# of this.
stage-webrtc:
	@swift build --package-path packages/JitsiNativeCore --target JitsiMedia >/dev/null
	@bin="$$(swift build --package-path packages/JitsiNativeCore --show-bin-path)"; \
	  mkdir -p "$$bin/PackageFrameworks"; \
	  ln -sfn ../WebRTC.framework "$$bin/PackageFrameworks/WebRTC.framework"

test: stage-webrtc
	swift test --package-path packages/JitsiNativeCore

media:
	swift build --package-path packages/JitsiNativeCore --target JitsiMedia
	swift build --package-path packages/JitsiNativeCore --target JitsiConference

mac:
	xcodebuild -project apps/Gafsaf.xcodeproj -scheme Gafsaf-macOS \
	  -destination "platform=macOS" -derivedDataPath build/DerivedData \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built Gafsaf for macOS"

ios:
	xcodebuild -project apps/Gafsaf.xcodeproj -scheme Gafsaf-iOS \
	  -destination "generic/platform=iOS Simulator" \
	  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet build
	@echo "==> Built Gafsaf for iOS Simulator"

ios-device:
	xcodebuild -project apps/Gafsaf.xcodeproj -scheme Gafsaf-iOS \
	  -destination "generic/platform=iOS" -derivedDataPath build/DerivedData \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built Gafsaf for iOS device"

clean:
	xcodebuild -project apps/Gafsaf.xcodeproj -scheme Gafsaf-macOS clean
	xcodebuild -project apps/Gafsaf.xcodeproj -scheme Gafsaf-iOS clean
