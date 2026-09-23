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
  let controller: MeetingController
  /// Both objects are `@Observable`, so the bar redraws only for the
  /// properties its body reads. That matters for the More menu: UIKit
  /// reloads an open menu on every rebuild, collapsing submenus and dropping
  /// the tap on its way. The session changes on every partial transcription
  /// result, so the bar reads nothing from it here; the one thing it shows
  /// is passed in as a value.
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
      // Reaching for the controls means the message is finished, so the
      // keyboard goes away on touch-down, before any popover presents. (It
      // began as a workaround: a SwiftUI Menu would not present at all while
      // a text field held first responder, and swallowed the tap.)
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
///
/// A system menu on the Mac; a popover on iOS. A UIKit menu rebuilt while
/// open resets itself — submenus collapse, the list jumps back, the tap on
/// its way is lost — and during a call something kept rebuilding it. A
/// popover is an ordinary view that updates in place, and it has the room
/// for the settings pickers that ran a phone menu off the top of the screen.
private struct MoreMenu: View {
  let controller: MeetingController
  /// Only acted on, never read in the body — see `MeetingControlBar.conversation`.
  let conversation: ConversationSession
  let notesOpen: Bool
  @ObservedObject private var settings = AppSettings.shared
  var overflow: [MeetingControlBar.OverflowControl] = []

  #if os(iOS)
    @State private var showsPopover = false
    /// The chosen item's action, held until the popover has gone: a sheet or
    /// system picker presented while it is still dismissing never appears.
    @State private var pendingAction: (() -> Void)?
  #endif

  var body: some View {
    #if os(iOS)
      Button {
        showsPopover.toggle()
      } label: {
        label
      }
      .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
        List {
          items
        }
        .frame(minWidth: 320, idealWidth: 340, minHeight: 420, idealHeight: 560)
        .presentationCompactAdaptation(.popover)
        .onDisappear {
          let action = pendingAction
          pendingAction = nil
          action?()
        }
      }
      .buttonStyle(.plain)
      .modifier(MoreButtonChrome())
    #else
      Menu {
        items
      } label: {
        label
      }
      .menuIndicator(.hidden)
      .buttonStyle(.plain)
      .modifier(MoreButtonChrome())
    #endif
  }

  private var label: some View {
    // White on the symbol, not the button: set on the button it would carry
    // into the popover's list and leave its rows white on white.
    Image(systemName: "ellipsis")
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 42, height: 42)
      .contentShape(.circle)
      .overlay(alignment: .topTrailing) {
        if overflow.contains(.chat), controller.unreadChatCount > 0 {
          Circle().fill(.red).frame(width: 9, height: 9).offset(x: 1, y: -1)
        }
      }
  }

  /// Runs an item's action the way its container expects: at once from a
  /// menu, which closes itself; after the popover has closed on iOS.
  private func perform(_ action: @escaping () -> Void) {
    #if os(iOS)
      pendingAction = action
      showsPopover = false
    #else
      action()
    #endif
  }

  @ViewBuilder private var items: some View {
    if !overflow.isEmpty {
      Section {
        ForEach(overflow, id: \.self) { control in
          overflowEntry(for: control)
        }
      }
    }
    // The settings live here for reach, and identically in the Settings
    // window (⌘, on macOS) or sheet (iOS) — both edit the same stored
    // preferences.
    settingsSection
    Section {
      if controller.pipAvailable {
        Button {
          perform { controller.togglePictureInPicture() }
        } label: {
          Label(
            controller.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture",
            systemImage: "pip")
        }
      }
      Button {
        perform { controller.showsPollsPane = true }
      } label: {
        Label(
          controller.polls.isEmpty ? "Polls…" : "Polls (\(controller.polls.count))…",
          systemImage: "chart.bar.xaxis")
      }
      Button {
        perform { controller.showsSpeakerStats = true }
      } label: {
        Label("Speaker Stats…", systemImage: "waveform")
      }
    }
    if !controller.breakoutRooms.isEmpty || controller.isModerator {
      Section {
        Menu {
          ForEach(controller.breakoutRooms) { room in
            if controller.isModerator, !room.isMainRoom {
              Menu("\(room.name) (\(room.participantCount))") {
                Button("Join") { perform { controller.joinBreakoutRoom(room.id) } }
                Button("Remove", role: .destructive) {
                  perform { controller.removeBreakoutRoom(room.id) }
                }
              }
            } else {
              Button("\(room.name) (\(room.participantCount))") {
                perform { controller.joinBreakoutRoom(room.id) }
              }
            }
          }
          if controller.isModerator {
            if !controller.breakoutRooms.isEmpty { Divider() }
            Button("Add Breakout Room") { perform { controller.createBreakoutRoom() } }
          }
        } label: {
          Label("Breakout Rooms", systemImage: "square.split.2x1")
        }
      }
    }
    Section {
      #if os(iOS)
        // Apple's ML noise suppression (Voice Isolation) is a system
        // microphone mode: only the user can switch it, from the picker
        // this opens. It applies here because iOS capture runs through
        // Apple's voice-processing unit.
        Text("Microphone: \(Self.microphoneModeName)")
        Button("Noise Suppression (Mic Mode)…") {
          perform { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
        }
      #else
        // macOS offers microphone modes only to apps capturing through
        // Apple's voice-processing unit; this WebRTC build captures via
        // the HAL, so the system picker would show nothing for Sangam.
        // WebRTC's own suppression chain is always on instead.
        Text("Noise Suppression: On (WebRTC)")
      #endif
    }
    if controller.isModerator {
      Section("Security") {
        Toggle(
          "Waiting Room",
          isOn: Binding(
            get: { controller.lobbyOn },
            set: { controller.setLobbyEnabled($0) }
          )
        )
        if controller.roomHasPassword {
          Button("Remove Meeting Password") {
            perform { controller.setRoomPassword(nil) }
          }
        } else {
          Button("Set Meeting Password…") {
            perform { controller.showsRoomPasswordPrompt = true }
          }
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
  }

  /// The preferences that also live in the Settings window, inline for
  /// reach.
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
        Button("All Settings…") { perform { controller.showsSettingsPane = true } }
      #endif
    }
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
        perform { controller.toggleScreenSharing() }
      } label: {
        Label(
          controller.isScreenSharing ? "Stop Sharing" : "Share Screen",
          systemImage: "rectangle.on.rectangle")
      }
    case .raiseHand:
      Button {
        perform { controller.toggleHandRaised() }
      } label: {
        Label(
          controller.isHandRaised ? "Lower Hand" : "Raise Hand",
          systemImage: "hand.raised")
      }
    case .reactions:
      #if os(iOS)
        // A row of the reactions themselves: one tap, as on the palette.
        HStack {
          ForEach(meetingReactions, id: \.name) { reaction in
            Button {
              perform { controller.sendReaction(reaction.name) }
            } label: {
              Text(reaction.emoji)
                .font(.system(size: 24))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(reaction.name)
          }
        }
      #else
        Menu {
          ForEach(meetingReactions, id: \.name) { reaction in
            Button("\(reaction.emoji) \(reaction.name.capitalized)") {
              controller.sendReaction(reaction.name)
            }
          }
        } label: {
          Label("React", systemImage: "face.smiling")
        }
      #endif
    case .chat:
      Button {
        perform { controller.toggleChat() }
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
        perform { controller.toggleLayout() }
      } label: {
        Label(
          controller.usesTileGrid ? "Speaker View" : "Grid View",
          systemImage: controller.usesTileGrid
            ? "person.crop.rectangle" : "square.grid.2x2")
      }
    case .notes:
      Button {
        perform {
          controller.isChatOpen = false
          conversation.toggleSidebar()
        }
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
          perform { copyMeetingLink(link) }
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

/// The More button's circle, shared by the menu and the popover button.
private struct MoreButtonChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(.black.opacity(0.48), in: .circle)
      .fixedSize()
      .help("More options")
      .accessibilityLabel("More options")
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
