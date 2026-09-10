// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "JitsiNativeCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "JitsiNativeCore", targets: ["JitsiNativeCore"]),
    .library(name: "JitsiConcurrency", targets: ["JitsiConcurrency"]),
    .library(name: "JitsiMedia", targets: ["JitsiMedia"]),
    .library(name: "JitsiConference", targets: ["JitsiConference"]),
    .library(name: "JitsiXMPP", targets: ["JitsiXMPP"]),
    .library(name: "JitsiJingle", targets: ["JitsiJingle"]),
    .library(name: "JitsiBridge", targets: ["JitsiBridge"]),
    .library(name: "JitsiDiscovery", targets: ["JitsiDiscovery"]),
    .library(name: "JitsiMeetingNotes", targets: ["JitsiMeetingNotes"]),
  ],
  dependencies: [
    .package(url: "https://github.com/jitsi/webrtc", exact: "124.0.2")
  ],
  targets: [
    .target(name: "JitsiConcurrency"),
    .target(name: "JitsiXMPP"),
    .target(name: "JitsiJingle", dependencies: ["JitsiXMPP"]),
    .target(name: "JitsiBridge"),
    .target(name: "JitsiDiscovery"),
    .target(name: "JitsiMeetingNotes"),
    .target(
      name: "JitsiAudioBridge",
      dependencies: [.product(name: "WebRTC", package: "webrtc")],
      exclude: ["Vendor/LICENSE", "Vendor/PATENTS", "Vendor/ABSEIL_LICENSE", "README.md"],
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("Vendor"),
        .define("WEBRTC_POSIX"), .define("NDEBUG"),
      ]
    ),
    .target(
      name: "JitsiMedia",
      dependencies: [
        "JitsiConcurrency", "JitsiAudioBridge", .product(name: "WebRTC", package: "webrtc"),
      ]
    ),
    .target(
      name: "JitsiNativeCore",
      dependencies: [
        "JitsiXMPP", "JitsiJingle", "JitsiBridge", "JitsiDiscovery",
      ]
    ),
    .target(
      name: "JitsiConference",
      dependencies: [
        "JitsiNativeCore", "JitsiXMPP", "JitsiJingle", "JitsiBridge", "JitsiDiscovery",
        "JitsiMedia", "JitsiConcurrency",
      ]
    ),
    .testTarget(name: "JitsiConcurrencyTests", dependencies: ["JitsiConcurrency"]),
    .testTarget(
      name: "JitsiConferenceTests",
      dependencies: ["JitsiConference", "JitsiXMPP", "JitsiJingle", "JitsiMedia"]
    ),
    .testTarget(name: "JitsiXMPPTests", dependencies: ["JitsiXMPP"]),
    .testTarget(name: "JitsiJingleTests", dependencies: ["JitsiJingle", "JitsiXMPP"]),
    .testTarget(name: "JitsiBridgeTests", dependencies: ["JitsiBridge"]),
    .testTarget(name: "JitsiDiscoveryTests", dependencies: ["JitsiDiscovery"]),
    .testTarget(name: "JitsiMediaTests", dependencies: ["JitsiMedia"]),
    .testTarget(name: "JitsiNativeCoreTests", dependencies: ["JitsiNativeCore"]),
    .testTarget(name: "JitsiMeetingNotesTests", dependencies: ["JitsiMeetingNotes"]),
  ],
  cxxLanguageStandard: .cxx17
)
