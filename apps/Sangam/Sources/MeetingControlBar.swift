import SwiftUI

struct MeetingControlBar: View {
  @ObservedObject var controller: MeetingController

  var body: some View {
    HStack(spacing: 10) {
      ControlButton(
        title: controller.isAudioMuted ? "Unmute" : "Mute",
        symbol: controller.isAudioMuted ? "mic.slash.fill" : "mic.fill",
        isActive: controller.isAudioMuted,
        action: controller.toggleAudio
      )

      ControlButton(
        title: controller.isVideoMuted ? "Start Video" : "Stop Video",
        symbol: controller.isVideoMuted ? "video.slash.fill" : "video.fill",
        isActive: controller.isVideoMuted,
        action: controller.toggleVideo
      )

      #if os(iOS)
        ControlButton(
          title: "Flip",
          symbol: "arrow.triangle.2.circlepath.camera.fill",
          action: controller.switchCamera
        )
      #endif

      ControlButton(
        title: controller.isScreenSharing ? "Stop Sharing" : "Share",
        symbol: controller.isScreenSharing ? "rectangle.slash.fill" : "rectangle.on.rectangle",
        isActive: controller.isScreenSharing,
        action: controller.toggleScreenSharing
      )

      ControlButton(
        title: controller.isHandRaised ? "Lower Hand" : "Raise Hand",
        symbol: "hand.raised.fill",
        isActive: controller.isHandRaised,
        action: controller.toggleHandRaised
      )

      ReactionsButton(send: controller.sendReaction)

      ControlButton(
        title: controller.isChatOpen ? "Hide Chat" : "Chat",
        symbol: "bubble.left.and.bubble.right.fill",
        isActive: controller.isChatOpen,
        badge: controller.unreadChatCount,
        action: controller.toggleChat
      )

      ControlButton(
        title: controller.usesTileGrid ? "Speaker View" : "Grid View",
        symbol: controller.usesTileGrid
          ? "person.crop.rectangle.fill" : "square.grid.2x2.fill",
        action: controller.toggleLayout
      )

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

/// The jitsi-meet reaction palette, sharing its wire vocabulary so reactions
/// land on web participants exactly as their own do.
private struct ReactionsButton: View {
  let send: (String) -> Void

  @State private var showsPalette = false

  private static let reactions: [(name: String, emoji: String)] = [
    ("like", "👍"), ("clap", "👏"), ("laugh", "😀"), ("surprised", "😮"),
    ("boo", "🙁"), ("silence", "😶"), ("love", "💖"),
  ]

  var body: some View {
    ControlButton(title: "React", symbol: "face.smiling", isActive: showsPalette) {
      showsPalette.toggle()
    }
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
