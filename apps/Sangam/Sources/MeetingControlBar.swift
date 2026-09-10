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
  /// Held, not observed. The session republishes on every partial
  /// transcription result and on the caption ticker, and the bar shows none
  /// of that — observing it rebuilt the More menu mid-sentence, which UIKit
  /// reloads, dropping the tap that was on its way. The one thing the bar
  /// does show is passed in as a value.
  let conversation: ConversationSession
  let notesOpen: Bool
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
    case notes
    case layout
    case invite
  }

  /// Which optional controls keep their own button. Ordered by how much
  /// they are worth keeping inline; the rest go to the More menu.
  private var inlineControls: Set<OverflowControl> {
    var keepOrder: [OverflowControl] = [
      .screenShare, .chat, .raiseHand, .reactions, .layout, .invite,
    ]
    keepOrder.insert(.notes, at: 1)
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

  private var notesButtonTitle: String {
    #if os(macOS)
      notesOpen ? "Hide Notes" : "Notes"
    #else
      notesOpen ? "Hide Transcript" : "Transcript"
    #endif
  }

  /// jitsi-meet's bare-key shortcuts (M, V, D, R, C, W). Disabled while the
  /// chat panel is open so typing a message never toggles the microphone.
  private func shortcut(_ key: Character) -> KeyboardShortcut? {
    #if os(macOS)
      if notesOpen { return nil }
    #endif
    return controller.isChatOpen ? nil : KeyboardShortcut(KeyEquivalent(key), modifiers: [])
  }

  var body: some View {
    let inline = inlineControls
    HStack(spacing: 10) {
      ControlButton(
        title: controller.isAudioMuted ? "Unmute" : "Mute",
        symbol: controller.isAudioMuted ? "mic.slash.fill" : "mic.fill",
        isActive: controller.isAudioMuted,
        // Muted there is no level worth drawing, and the slashed symbol says
        // the only thing that matters.
        meter: controller.isAudioMuted ? nil : controller.microphoneMeter,
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

      if inline.contains(.notes) {
        ControlButton(
          // The Mac opens the editable document; iOS slides the transcript
          // up over the stage.
          title: notesButtonTitle,
          symbol: "note.text",
          isActive: notesOpen
        ) {
          controller.isChatOpen = false
          conversation.toggleSidebar()
        }
        .help("Conversation notes and transcription")
        .keyboardShortcut("n", modifiers: [.command, .option])
      }

      if inline.contains(.invite) {
        InviteButton(link: controller.meetingLink, pinned: $popoverPinned)
      }

      MoreMenu(
        controller: controller, conversation: conversation, notesOpen: notesOpen,
        overflow: overflowControls)

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
    #if os(iOS)
      // A SwiftUI Menu refuses to present while a text field holds first
      // responder — the tap on More is swallowed whole, leaving the console
      // with a keyboard-snapshot warning and a timed-out system gesture
      // gate. Reaching for the controls means the message is finished, so
      // the keyboard goes away on touch-down, before the menu presents.
      .simultaneousGesture(
        DragGesture(minimumDistance: 0).onChanged { _ in dismissKeyboard() }
      )
    #endif
  }

  #if os(iOS)
    private func dismissKeyboard() {
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
  #endif
}

/// The junk drawer: overflowed toolbar controls first, then the settings
/// that never earn their own button (quality, moderation).
private struct MoreMenu: View {
  @ObservedObject var controller: MeetingController
  /// Held, not observed — see `MeetingControlBar.conversation`.
  let conversation: ConversationSession
  let notesOpen: Bool
  @ObservedObject private var settings = AppSettings.shared
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  var overflow: [MeetingControlBar.OverflowControl] = []

  /// The preferences that also live in the Settings window, inline for
  /// reach where the menu has the room for them.
  @ViewBuilder private var settingsSection: some View {
    Section("Settings") {
      Picker("Incoming Video Quality", selection: $settings.receiveQuality) {
        ForEach(SettingsView.qualities, id: \.height) { quality in
          Text(quality.label).tag(quality.height)
        }
      }
      Toggle("Blur My Background", isOn: $settings.backgroundBlur)
      Toggle("Transcribe From the Start", isOn: $settings.transcribeOnJoin)
      Toggle("Show Captions", isOn: $settings.showsCaptions)
      // Only the participants column still has a choice: chat and the
      // conversation are an inspector now, and an inspector always pushes.
      Picker("Participants Sidebar", selection: $settings.panelsPushStage) {
        Text("Float Over Video").tag(false)
        Text("Push Video Aside").tag(true)
      }
      #if os(macOS)
        SettingsLink {
          Text("All Settings…")
        }
      #else
        Button("All Settings…") { controller.showsSettingsPane = true }
      #endif
    }
  }

  /// Whether the settings are a single entry that opens the sheet instead
  /// of a section of pickers: a phone, where the menu has no room.
  private var compactSettings: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  var body: some View {
    Menu {
      if !overflow.isEmpty {
        ForEach(overflow, id: \.self) { control in
          overflowEntry(for: control)
        }
        Divider()
      }
      // The settings live here for reach, and identically in the Settings
      // window (⌘, on macOS) — both edit the same stored preferences. On a
      // phone they do not fit: each picker expands to a row per choice, and
      // the menu runs off the top of the screen taking the items above it
      // with it. There they are one entry that opens the settings sheet.
      if compactSettings {
        Button {
          controller.showsSettingsPane = true
        } label: {
          Label("Settings…", systemImage: "gearshape")
        }
      } else {
        settingsSection
      }
      Divider()
      Divider()
      if controller.pipAvailable {
        Button {
          controller.togglePictureInPicture()
        } label: {
          Label(
            controller.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture",
            systemImage: "pip")
        }
      }
      Button {
        controller.showsPollsPane = true
      } label: {
        Label(
          controller.polls.isEmpty ? "Polls…" : "Polls (\(controller.polls.count))…",
          systemImage: "chart.bar.xaxis")
      }
      Button {
        controller.showsSpeakerStats = true
      } label: {
        Label("Speaker Stats…", systemImage: "waveform")
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
      #if os(iOS)
        // Apple's ML noise suppression (Voice Isolation) is a system
        // microphone mode: only the user can switch it, from the picker
        // this opens. It applies here because iOS capture runs through
        // Apple's voice-processing unit.
        Text("Microphone: \(Self.microphoneModeName)")
        Button("Noise Suppression (Mic Mode)…") {
          AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        }
      #else
        // macOS offers microphone modes only to apps capturing through
        // Apple's voice-processing unit; this WebRTC build captures via
        // the HAL, so the system picker would show nothing for Sangam.
        // WebRTC's own suppression chain is always on instead.
        Text("Noise Suppression: On (WebRTC)")
      #endif
      if controller.isModerator {
        Divider()
        Section("Security") {
          Toggle(
            "Waiting Room",
            isOn: Binding(
              get: { controller.lobbyOn },
              set: { controller.setLobbyEnabled($0) }
            )
          )
          if controller.roomHasPassword {
            Button("Remove Meeting Password") { controller.setRoomPassword(nil) }
          } else {
            Button("Set Meeting Password…") { controller.showsRoomPasswordPrompt = true }
          }
          Toggle(
            "Require permission to speak",
            isOn: Binding(
              get: { controller.audioModerationOn },
              set: { controller.setAudioModeration($0) }
            )
          )
        }
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
    case .notes:
      Button {
        controller.isChatOpen = false
        conversation.toggleSidebar()
      } label: {
        #if os(macOS)
          Label(
            notesOpen ? "Hide Conversation Notes" : "Conversation Notes & Transcription",
            systemImage: "note.text")
        #else
          // iOS has the transcript, not the editable document behind it.
          Label(notesOpen ? "Hide Transcript" : "Transcript", systemImage: "text.quote")
        #endif
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
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

/// The microphone symbol with its body — the capsule the whole glyph is
/// built around — filling from the bottom in proportion to the level coming
/// in, so the button shows at a glance that the room can hear you.
///
/// The fill is masked by the symbol itself rather than drawn over it, so it
/// is the glyph's own ink that lights up, and the band it is confined to
/// covers the capsule alone: the cradle and stem below it never fill.
private struct MicrophoneMeterSymbol: View {
  /// Observed here and nowhere above: this is the only view that has to
  /// redraw ten times a second.
  @ObservedObject var meter: MicrophoneMeter

  /// Where the capsule ends inside the symbol's box, as a fraction of its
  /// height. `mic.fill` draws the body from the top down to about half way,
  /// then the cradle and the stem; measured against the rendered glyph so
  /// the fill stops before the tips of the cradle.
  private static let capsuleBottom = 0.52
  private static let size: CGFloat = 19

  var body: some View {
    let level = meter.level
    let symbol = Image(systemName: "mic.fill").resizable().scaledToFit()
    symbol
      .overlay {
        symbol
          .foregroundStyle(Color.accentColor)
          .mask(alignment: .top) {
            GeometryReader { geometry in
              let bottom = geometry.size.height * Self.capsuleBottom
              let filled = bottom * min(1, max(0, level))
              Rectangle()
                .frame(height: filled)
                .offset(y: bottom - filled)
            }
          }
      }
      .frame(width: Self.size, height: Self.size)
      // Ten readings a second glide into one another instead of stepping.
      .animation(.linear(duration: 0.1), value: level)
      .accessibilityHidden(true)
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
  /// When set, the symbol is drawn as a microphone whose body fills to the
  /// current level. The meter is passed as the object, not the number, so
  /// its ten readings a second stay inside `MicrophoneMeterSymbol` instead
  /// of rebuilding this button and everything alongside it.
  var meter: MicrophoneMeter?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        if let meter {
          MicrophoneMeterSymbol(meter: meter)
        } else {
          Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
        }
      }
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
