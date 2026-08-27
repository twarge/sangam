import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct MeetingControlBar: View {
  @ObservedObject var controller: MeetingController
  /// True while one of the bar's popovers is open, so an auto-hiding host
  /// can keep the bar on screen underneath it.
  @Binding var popoverPinned: Bool

  /// jitsi-meet's bare-key shortcuts (M, V, D, R, C, W). Disabled while the
  /// chat panel is open so typing a message never toggles the microphone.
  private func shortcut(_ key: Character) -> KeyboardShortcut? {
    controller.isChatOpen ? nil : KeyboardShortcut(KeyEquivalent(key), modifiers: [])
  }

  var body: some View {
    HStack(spacing: 10) {
      ControlButton(
        title: controller.isAudioMuted ? "Unmute" : "Mute",
        symbol: controller.isAudioMuted ? "mic.slash.fill" : "mic.fill",
        isActive: controller.isAudioMuted,
        action: controller.toggleAudio
      )
      .keyboardShortcut(shortcut("m"))

      ControlButton(
        title: controller.isVideoMuted ? "Start Video" : "Stop Video",
        symbol: controller.isVideoMuted ? "video.slash.fill" : "video.fill",
        isActive: controller.isVideoMuted,
        action: controller.toggleVideo
      )
      .keyboardShortcut(shortcut("v"))
      // Right-click (macOS) or long-press (iOS) picks the camera.
      .contextMenu {
        if controller.cameras.isEmpty {
          Text("No camera detected")
        } else {
          ForEach(controller.cameras) { camera in
            Button {
              controller.selectCamera(id: camera.id)
            } label: {
              if camera.id == controller.currentCameraID {
                Label(camera.name, systemImage: "checkmark")
              } else {
                Text(camera.name)
              }
            }
          }
        }
      }

      #if os(iOS)
        ControlButton(
          title: "Flip",
          symbol: "arrow.triangle.2.circlepath.camera.fill",
          action: controller.flipCamera
        )
      #endif

      ControlButton(
        title: controller.isScreenSharing ? "Stop Sharing" : "Share",
        symbol: controller.isScreenSharing ? "rectangle.slash.fill" : "rectangle.on.rectangle",
        isActive: controller.isScreenSharing,
        action: controller.toggleScreenSharing
      )
      .keyboardShortcut(shortcut("d"))

      ControlButton(
        title: controller.isHandRaised ? "Lower Hand" : "Raise Hand",
        symbol: "hand.raised.fill",
        isActive: controller.isHandRaised,
        action: controller.toggleHandRaised
      )
      .keyboardShortcut(shortcut("r"))

      ReactionsButton(send: controller.sendReaction, pinned: $popoverPinned)

      ControlButton(
        title: controller.isChatOpen ? "Hide Chat" : "Chat",
        symbol: "bubble.left.and.bubble.right.fill",
        isActive: controller.isChatOpen,
        badge: controller.unreadChatCount,
        action: controller.toggleChat
      )
      .keyboardShortcut(shortcut("c"))

      ControlButton(
        title: controller.usesTileGrid ? "Speaker View" : "Grid View",
        symbol: controller.usesTileGrid
          ? "person.crop.rectangle.fill" : "square.grid.2x2.fill",
        action: controller.toggleLayout
      )
      .keyboardShortcut(shortcut("w"))

      InviteButton(link: controller.meetingLink, pinned: $popoverPinned)

      MoreMenu(controller: controller)

      ControlButton(
        title: "Leave",
        symbol: "phone.down.fill",
        role: .destructive,
        action: controller.hangUp
      )
    }
    .padding(10)
    .background(.ultraThinMaterial, in: .capsule)
    .overlay {
      Capsule().strokeBorder(.white.opacity(0.12))
    }
    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
  }
}

/// The overflow menu: settings that don't earn their own toolbar button,
/// starting with the incoming-video quality cap (the web's performance
/// setting).
private struct MoreMenu: View {
  @ObservedObject var controller: MeetingController

  private static let qualities: [(label: String, height: Int)] = [
    ("Low (180p)", 180), ("Standard (360p)", 360),
    ("High (720p)", 720), ("Full HD (1080p)", 1080),
  ]

  var body: some View {
    Menu {
      Picker(
        "Incoming video quality",
        selection: Binding(
          get: { controller.receiveQuality },
          set: { controller.setReceiveQuality($0) }
        )
      ) {
        ForEach(Self.qualities, id: \.height) { quality in
          Text(quality.label).tag(quality.height)
        }
      }
      if controller.isModerator {
        Divider()
        Toggle(
          "Require permission to speak",
          isOn: Binding(
            get: { controller.audioModerationOn },
            set: { controller.setAudioModeration($0) }
          )
        )
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 42, height: 42)
        .contentShape(.circle)
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .background(.black.opacity(0.48), in: .circle)
    .fixedSize()
    .help("More options")
    .accessibilityLabel("More options")
  }
}

/// Shares the meeting's join link — the same URL web participants use.
private struct InviteButton: View {
  let link: URL?
  @Binding var pinned: Bool

  @State private var showsPopover = false
  @State private var copied = false

  var body: some View {
    ControlButton(title: "Invite", symbol: "person.badge.plus", isActive: showsPopover) {
      showsPopover.toggle()
    }
    .onChange(of: showsPopover) { _, open in pinned = open }
    .popover(isPresented: $showsPopover, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Share this link to invite people")
          .font(.headline)
        if let link {
          Text(link.absoluteString)
            .font(.callout.monospaced())
            .textSelection(.enabled)
          HStack(spacing: 10) {
            Button(copied ? "Copied" : "Copy Link") {
              copy(link)
            }
            ShareLink(item: link) {
              Label("Share…", systemImage: "square.and.arrow.up")
            }
          }
        }
      }
      .padding(14)
      .frame(minWidth: 300, alignment: .leading)
    }
  }

  private func copy(_ link: URL) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(link.absoluteString, forType: .string)
    #else
      UIPasteboard.general.url = link
    #endif
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }
}

/// The jitsi-meet reaction palette, sharing its wire vocabulary so reactions
/// land on web participants exactly as their own do.
private struct ReactionsButton: View {
  let send: (String) -> Void
  @Binding var pinned: Bool

  @State private var showsPalette = false

  private static let reactions: [(name: String, emoji: String)] = [
    ("like", "👍"), ("clap", "👏"), ("laugh", "😀"), ("surprised", "😮"),
    ("boo", "🙁"), ("silence", "😶"), ("love", "💖"),
  ]

  var body: some View {
    ControlButton(title: "React", symbol: "face.smiling", isActive: showsPalette) {
      showsPalette.toggle()
    }
    .onChange(of: showsPalette) { _, open in pinned = open }
    .popover(isPresented: $showsPalette, arrowEdge: .top) {
      HStack(spacing: 6) {
        ForEach(Self.reactions, id: \.name) { reaction in
          Button {
            send(reaction.name)
          } label: {
            Text(reaction.emoji)
              .font(.system(size: 26))
              .frame(width: 40, height: 40)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(reaction.name)
        }
      }
      .padding(10)
    }
  }
}

private struct ControlButton: View {
  enum Role {
    case normal
    case destructive
  }

  let title: String
  let symbol: String
  var isActive = false
  var badge = 0
  var role: Role = .normal
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 42, height: 42)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .background(backgroundColor, in: .circle)
    .overlay(alignment: .topTrailing) {
      if badge > 0 {
        Text(badge > 99 ? "99+" : "\(badge)")
          .font(.caption2.bold())
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.red, in: .capsule)
          .offset(x: 4, y: -4)
      }
    }
    .help(title)
    .accessibilityLabel(title)
  }

  private var backgroundColor: Color {
    if role == .destructive { return .red }
    if isActive { return .white.opacity(0.32) }
    return .black.opacity(0.48)
  }
}
