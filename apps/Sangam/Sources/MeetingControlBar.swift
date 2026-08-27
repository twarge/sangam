import AVFoundation
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The jitsi-meet reaction vocabulary, shared by the palette popover and the
/// overflow menu so reactions land on web participants exactly as their own.
private let meetingReactions: [(name: String, emoji: String)] = [
  ("like", "👍"), ("clap", "👏"), ("laugh", "😀"), ("surprised", "😮"),
  ("boo", "🙁"), ("silence", "😶"), ("love", "💖"),
]

private func copyMeetingLink(_ link: URL) {
  #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(link.absoluteString, forType: .string)
  #else
    UIPasteboard.general.url = link
  #endif
}

struct MeetingControlBar: View {
  @ObservedObject var controller: MeetingController
  /// True while one of the bar's popovers is open, so an auto-hiding host
  /// can keep the bar on screen underneath it.
  @Binding var popoverPinned: Bool
  /// Width the bar may occupy. When it runs short — a narrow window, or the
  /// sidebar and chat panel encroaching — optional controls retreat into
  /// the More menu until only microphone, camera, More, and Leave remain.
  var availableWidth: CGFloat = .infinity

  enum OverflowControl: CaseIterable {
    case screenShare
    case raiseHand
    case reactions
    case chat
    case layout
    case invite
  }

  /// Which optional controls keep their own button. Ordered by how much
  /// they are worth keeping inline; the rest go to the More menu.
  private var inlineControls: Set<OverflowControl> {
    let keepOrder: [OverflowControl] = [
      .screenShare, .chat, .raiseHand, .reactions, .layout, .invite,
    ]
    guard availableWidth.isFinite else { return Set(keepOrder) }
    // Microphone, camera (+ flip on iOS), More, and Leave always stay.
    #if os(iOS)
      let essentialSlots = 5.0
    #else
      let essentialSlots = 4.0
    #endif
    let slot = 52.0
    let fitting = Int(((availableWidth - 20 - essentialSlots * slot) / slot).rounded(.down))
    return Set(keepOrder.prefix(max(0, fitting)))
  }

  private var overflowControls: [OverflowControl] {
    let inline = inlineControls
    return OverflowControl.allCases.filter { !inline.contains($0) }
  }

  /// jitsi-meet's bare-key shortcuts (M, V, D, R, C, W). Disabled while the
  /// chat panel is open so typing a message never toggles the microphone.
  private func shortcut(_ key: Character) -> KeyboardShortcut? {
    controller.isChatOpen ? nil : KeyboardShortcut(KeyEquivalent(key), modifiers: [])
  }

  var body: some View {
    let inline = inlineControls
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

      if inline.contains(.screenShare) {
        ControlButton(
          title: controller.isScreenSharing ? "Stop Sharing" : "Share",
          symbol: controller.isScreenSharing
            ? "rectangle.slash.fill" : "rectangle.on.rectangle",
          isActive: controller.isScreenSharing,
          action: controller.toggleScreenSharing
        )
        .keyboardShortcut(shortcut("d"))
      }

      if inline.contains(.raiseHand) {
        ControlButton(
          title: controller.isHandRaised ? "Lower Hand" : "Raise Hand",
          symbol: "hand.raised.fill",
          isActive: controller.isHandRaised,
          action: controller.toggleHandRaised
        )
        .keyboardShortcut(shortcut("r"))
      }

      if inline.contains(.reactions) {
        ReactionsButton(send: controller.sendReaction, pinned: $popoverPinned)
      }

      if inline.contains(.chat) {
        ControlButton(
          title: controller.isChatOpen ? "Hide Chat" : "Chat",
          symbol: "bubble.left.and.bubble.right.fill",
          isActive: controller.isChatOpen,
          badge: controller.unreadChatCount,
          action: controller.toggleChat
        )
        .keyboardShortcut(shortcut("c"))
      }

      if inline.contains(.layout) {
        ControlButton(
          title: controller.usesTileGrid ? "Speaker View" : "Grid View",
          symbol: controller.usesTileGrid
            ? "person.crop.rectangle.fill" : "square.grid.2x2.fill",
          action: controller.toggleLayout
        )
        .keyboardShortcut(shortcut("w"))
      }

      if inline.contains(.invite) {
        InviteButton(link: controller.meetingLink, pinned: $popoverPinned)
      }

      MoreMenu(controller: controller, overflow: overflowControls)

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
    .animation(.snappy, value: inline)
  }
}

/// The junk drawer: overflowed toolbar controls first, then the settings
/// that never earn their own button (quality, moderation).
private struct MoreMenu: View {
  @ObservedObject var controller: MeetingController
  var overflow: [MeetingControlBar.OverflowControl] = []

  private static let qualities: [(label: String, height: Int)] = [
    ("Low (180p)", 180), ("Standard (360p)", 360),
    ("High (720p)", 720), ("Full HD (1080p)", 1080),
  ]

  var body: some View {
    Menu {
      if !overflow.isEmpty {
        ForEach(overflow, id: \.self) { control in
          overflowEntry(for: control)
        }
        Divider()
      }
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
      Divider()
      Toggle(
        "Blur My Background",
        isOn: Binding(
          get: { controller.backgroundBlurOn },
          set: { controller.setBackgroundBlur($0) }
        )
      )
      if controller.pipAvailable {
        Button {
          controller.togglePictureInPicture()
        } label: {
          Label(
            controller.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture",
            systemImage: "pip")
        }
      }
      if !controller.breakoutRooms.isEmpty || controller.isModerator {
        Divider()
        Menu {
          ForEach(controller.breakoutRooms) { room in
            if controller.isModerator, !room.isMainRoom {
              Menu("\(room.name) (\(room.participantCount))") {
                Button("Join") { controller.joinBreakoutRoom(room.id) }
                Button("Remove", role: .destructive) {
                  controller.removeBreakoutRoom(room.id)
                }
              }
            } else {
              Button("\(room.name) (\(room.participantCount))") {
                controller.joinBreakoutRoom(room.id)
              }
            }
          }
          if controller.isModerator {
            if !controller.breakoutRooms.isEmpty { Divider() }
            Button("Add Breakout Room") { controller.createBreakoutRoom() }
          }
        } label: {
          Label("Breakout Rooms", systemImage: "square.split.2x1")
        }
      }
      Divider()
      // Apple's ML noise suppression (Voice Isolation) is a system
      // microphone mode: only the user can switch it, from the picker this
      // opens. The label shows what is active right now.
      Text("Microphone: \(Self.microphoneModeName)")
      Button("Noise Suppression (Mic Mode)…") {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
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
        .overlay(alignment: .topTrailing) {
          if overflow.contains(.chat), controller.unreadChatCount > 0 {
            Circle().fill(.red).frame(width: 9, height: 9).offset(x: 1, y: -1)
          }
        }
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .background(.black.opacity(0.48), in: .circle)
    .fixedSize()
    .help("More options")
    .accessibilityLabel("More options")
  }

  /// Menus rebuild their content on every open, so reading the live mode
  /// here keeps the label current without observation.
  private static var microphoneModeName: String {
    switch AVCaptureDevice.activeMicrophoneMode {
    case .voiceIsolation: "Voice Isolation"
    case .wideSpectrum: "Wide Spectrum"
    case .standard: "Standard"
    @unknown default: "Standard"
    }
  }

  @ViewBuilder
  private func overflowEntry(for control: MeetingControlBar.OverflowControl) -> some View {
    switch control {
    case .screenShare:
      Button {
        controller.toggleScreenSharing()
      } label: {
        Label(
          controller.isScreenSharing ? "Stop Sharing" : "Share Screen",
          systemImage: "rectangle.on.rectangle")
      }
    case .raiseHand:
      Button {
        controller.toggleHandRaised()
      } label: {
        Label(
          controller.isHandRaised ? "Lower Hand" : "Raise Hand",
          systemImage: "hand.raised")
      }
    case .reactions:
      Menu {
        ForEach(meetingReactions, id: \.name) { reaction in
          Button("\(reaction.emoji) \(reaction.name.capitalized)") {
            controller.sendReaction(reaction.name)
          }
        }
      } label: {
        Label("React", systemImage: "face.smiling")
      }
    case .chat:
      Button {
        controller.toggleChat()
      } label: {
        Label(
          controller.isChatOpen
            ? "Hide Chat"
            : controller.unreadChatCount > 0
              ? "Show Chat (\(controller.unreadChatCount))" : "Show Chat",
          systemImage: "bubble.left.and.bubble.right")
      }
    case .layout:
      Button {
        controller.toggleLayout()
      } label: {
        Label(
          controller.usesTileGrid ? "Speaker View" : "Grid View",
          systemImage: controller.usesTileGrid
            ? "person.crop.rectangle" : "square.grid.2x2")
      }
    case .invite:
      if let link = controller.meetingLink {
        Button {
          copyMeetingLink(link)
        } label: {
          Label("Copy Invite Link", systemImage: "person.badge.plus")
        }
        ShareLink(item: link) {
          Label("Share Invite…", systemImage: "square.and.arrow.up")
        }
      }
    }
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
              copyMeetingLink(link)
              copied = true
              Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
              }
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
}

/// The reaction palette popover behind the toolbar's React button.
private struct ReactionsButton: View {
  let send: (String) -> Void
  @Binding var pinned: Bool

  @State private var showsPalette = false

  var body: some View {
    ControlButton(title: "React", symbol: "face.smiling", isActive: showsPalette) {
      showsPalette.toggle()
    }
    .onChange(of: showsPalette) { _, open in pinned = open }
    .popover(isPresented: $showsPalette, arrowEdge: .top) {
      HStack(spacing: 6) {
        ForEach(meetingReactions, id: \.name) { reaction in
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
