import SwiftUI

#if os(macOS)
  import AppKit
#endif

struct MeetingView: View {
  let configuration: MeetingConfiguration
  @ObservedObject var conversation: ConversationSession
  let dismiss: () -> Void

  @StateObject private var controller = MeetingController()
  // The control bar tucks away when the pointer is elsewhere (macOS). An
  // open popover pins it so it never fades under its own palette.
  @State private var toolbarHovered = false
  @State private var toolbarPinned = false
  @State private var toolbarVisible = true
  @State private var toolbarHideTask: Task<Void, Never>?
  @State private var windowWidth: CGFloat = 0
  @State private var roomPasswordDraft = ""
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  /// Once the conference has been entered, later passes through the
  /// pre-join states are room switches, not first joins.
  @State private var hasJoinedOnce = false

  /// Whether the window is showing the first view's join form (the initial
  /// pre-join hold) rather than the conference.
  private var showsJoinForm: Bool {
    Self.preJoinStates.contains(controller.connectionState) && !hasJoinedOnce
  }

  private var isLayoutPreview: Bool {
    #if DEBUG
      MeetingLayoutPreviewMode.current != nil
    #else
      false
    #endif
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      // The conference is black; the initial join hold keeps the first
      // view's system background until actually in.
      Group {
        if showsJoinForm {
          Rectangle().fill(.background)
        } else {
          Color.black
        }
      }
      .ignoresSafeArea(.container)

      // On macOS the surface manages safe areas itself: the stage ignores
      // them (video runs under the titlebar), while the floating sidebar
      // must start below the toolbar.
      meetingSurface

      // The whole pre-join journey stays on the first view's join form —
      // anything the join still needs (host sign-in, lobby wait, meeting
      // password) expands below the Join button, and the video surface
      // only shows once actually in the conference. One view carries every
      // state change, so typed credentials and context survive.
      if Self.preJoinStates.contains(controller.connectionState) {
        if hasJoinedOnce {
          // A mid-meeting rejoin (a breakout-room switch) passes through
          // the same states, but the meeting is conceptually still on —
          // showing the join form again would be jarring.
          RoomSwitchCard()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
          PreJoinView(
            configuration: configuration,
            controller: controller,
            cancel: dismiss
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
      }

    }
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { windowWidth = geometry.size.width }
          .onChange(of: geometry.size.width) { _, width in windowWidth = width }
      }
    }
    .background(showsJoinForm ? AnyShapeStyle(.background) : AnyShapeStyle(.black))
    // The Mac's stage is the whole window with panels floating over it, so
    // the captions are placed here, clear of them. On iOS the stage is the
    // split view's detail column and the captions belong inside it, or they
    // slide under the participants column.
    #if os(macOS)
      .overlay(alignment: .bottom) {
        if controller.connectionState == .joined {
          CaptionOverlay(feed: conversation.captionFeed)
          .padding(.leading, controller.sidebarInset + 16)
          .padding(.trailing, chatInset + 16)
          .padding(.bottom, captionBottomInset)
          .animation(.snappy, value: controller.sidebarInset)
          .animation(.snappy, value: chatInset)
        }
      }
    #endif
    // Chat and the conversation share the trailing column on a Mac and on a
    // wide iPad, and on a phone they would be two sheets fighting over the
    // same screen. Opening one closes the other everywhere.
    .onChange(of: controller.isChatOpen) { _, open in if open { conversation.isOpen = false } }
    .onChange(of: controller.isAudioMuted) { _, muted in conversation.setLocalMuted(muted) }
    .alert(
      "Meeting Error",
      isPresented: Binding(
        get: { controller.errorMessage != nil },
        set: { if !$0 { controller.errorMessage = nil } }
      )
    ) {
      if controller.connectionState == .failed {
        Button("Back") { dismiss() }
      } else {
        Button("OK", role: .cancel) {}
      }
    } message: {
      Text(controller.errorMessage ?? "Unknown error")
    }
    .onChange(of: controller.connectionState) { _, state in
      if state == .joined {
        // Only the first join: a breakout-room switch passes back through
        // this state, and must not restart a transcription somebody has
        // since stopped.
        if !hasJoinedOnce, !isLayoutPreview, AppSettings.shared.transcribeOnJoin {
          conversation.startAutomatically()
        }
        hasJoinedOnce = true
      }
      if state == .ended {
        dismiss()
      }
    }
    // System surfaces (menu bar, Siri, CallKit) reach the meeting through
    // the hub; Handoff advertises the meeting link so another device can
    // pick the call up.
    .onAppear {
      guard !isLayoutPreview else { return }
      MeetingHub.shared.noteMeetingStarted(configuration, controller: controller)
    }
    .onDisappear {
      guard !isLayoutPreview else { return }
      MeetingHub.shared.noteMeetingEnded(controller: controller)
    }
    .userActivity(
      MeetingHub.meetingActivityType,
      isActive: controller.connectionState == .joined && !isLayoutPreview
    ) { activity in
      activity.title = "Meeting: \(configuration.normalizedRoom)"
      activity.webpageURL = configuration.meetingLink
      activity.isEligibleForHandoff = true
    }
    #if os(iOS)
      // The meeting is a system call while joined: call-priority audio,
      // system mute, arbitration with phone calls.
      .onChange(of: controller.connectionState) { _, state in
        guard !isLayoutPreview else { return }
        switch state {
        case .joined:
          CallSessionManager.shared.begin(room: configuration.normalizedRoom)
        case .ended, .failed:
          CallSessionManager.shared.end()
        default:
          break
        }
      }
      .onChange(of: controller.isAudioMuted) { _, muted in
        guard !isLayoutPreview else { return }
        CallSessionManager.shared.setMuted(muted)
      }
      .onDisappear {
        guard !isLayoutPreview else { return }
        CallSessionManager.shared.end()
      }
    #endif
    .sheet(isPresented: $controller.showsPollsPane) {
      PollsPanel(controller: controller)
    }
    .sheet(isPresented: $controller.showsSpeakerStats) {
      SpeakerStatsPanel(controller: controller)
    }
    .alert("Set Meeting Password", isPresented: $controller.showsRoomPasswordPrompt) {
      TextField("Password", text: $roomPasswordDraft)
      Button("Set") {
        let password = roomPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.isEmpty { controller.setRoomPassword(password) }
        roomPasswordDraft = ""
      }
      Button("Cancel", role: .cancel) { roomPasswordDraft = "" }
    } message: {
      Text("New participants will need this password to join.")
    }
    #if os(iOS)
      .sheet(isPresented: $controller.showsSettingsPane) {
        NavigationStack {
          SettingsView()
        }
        .presentationDetents([.medium, .large])
      }
    #endif
  }

  /// The room the bar may occupy: the window minus whatever the sidebar
  /// and the chat panel cover. Buttons overflow into the More menu when it
  /// runs short.
  private var toolbarAvailableWidth: CGFloat {
    guard windowWidth > 0 else { return .infinity }
    return max(0, windowWidth - controller.sidebarInset - chatInset - 32)
  }

  /// How far the captions sit above the bottom edge, clear of the floating
  /// control bar.
  private var captionBottomInset: CGFloat { 86 }

  /// Nothing, now that the trailing panels are an inspector column: it takes
  /// the width out of the stage itself, so the captions and the control bar
  /// are already centered on what is left. Kept as a name rather than
  /// threaded out of three call sites.
  private var chatInset: CGFloat { 0 }

  @ViewBuilder
  private var meetingToolbar: some View {
    #if os(macOS)
      // Only the bar's own footprint is hover-sensitive: the outer wrapper
      // keeps the exact bounds hit-testable (and so hoverable) even while
      // the bar inside is invisible and ignoring clicks.
      ZStack {
        MeetingControlBar(
          controller: controller,
          conversation: conversation,
          notesOpen: conversation.isOpen,
          popoverPinned: $toolbarPinned,
          availableWidth: toolbarAvailableWidth
        )
        .opacity(toolbarVisible ? 1 : 0)
        .allowsHitTesting(toolbarVisible)
        .animation(.easeOut(duration: 0.15), value: toolbarVisible)
      }
      .contentShape(Rectangle())
      .onHover { inside in
        toolbarHovered = inside
        updateToolbarVisibility()
      }
      // Center the bar over the visible stage, not the whole window.
      .frame(maxWidth: .infinity)
      .padding(.leading, controller.sidebarInset + 16)
      .padding(.trailing, chatInset + 16)
      .padding(.bottom, 14)
      .animation(.snappy, value: controller.sidebarInset)
      .animation(.snappy, value: controller.isChatOpen)
      .onChange(of: toolbarPinned) { _, _ in updateToolbarVisibility() }
      .onChange(of: controller.isChatOpen) { _, open in
        // The bar sits right over the chat's input; get out of the way at
        // once instead of waiting for the grace period.
        if open {
          toolbarHideTask?.cancel()
          toolbarVisible = false
        }
      }
      .onAppear { updateToolbarVisibility() }
    #else
      // Measure the actual navigation column, including when iPad shows
      // both columns. The inset reserves space for the controls and scrolling.
      GeometryReader { geometry in
        MeetingControlBar(
          controller: controller,
          conversation: conversation,
          notesOpen: conversation.isOpen,
          popoverPinned: $toolbarPinned,
          availableWidth: geometry.size.width
        )
        .frame(maxWidth: .infinity)
      }
      .frame(height: 62)
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
    #endif
  }

  #if os(macOS)
    private func updateToolbarVisibility() {
      toolbarHideTask?.cancel()
      // A layout preview is for looking at the controls; they stay put.
      if toolbarHovered || toolbarPinned || isLayoutPreview {
        toolbarVisible = true
        return
      }
      // A short grace so a slip off the edge doesn't flicker the bar away;
      // on appear this doubles as a brief "here are the controls" showing.
      toolbarHideTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(0.6))
        guard !Task.isCancelled, !toolbarHovered, !toolbarPinned else { return }
        toolbarVisible = false
      }
    }
  #endif

  private var meetingSurface: some View {
    #if os(macOS)
      NativeMeetingSurface(
        configuration: configuration, controller: controller, conversation: conversation
      ) {
        meetingToolbar
      }
    #else
      NativeMeetingSurface(
        configuration: configuration, controller: controller, conversation: conversation
      ) {
        meetingToolbar
      }
    #endif
  }
}

#if DEBUG
  /// Local layout fixtures exercise the real meeting view without a network
  /// connection, capture devices, CallKit, or credentials leaving the process.
  enum MeetingLayoutPreviewMode: String {
    case access, password, meeting, chat, notes, lobby

    static var current: Self? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "--layout-preview"), index + 1 < arguments.count
      else { return nil }
      return Self(rawValue: arguments[index + 1])
    }
  }
#endif

/// The shared chrome for every pre-join card: a dark HUD over the black
/// stage. Forcing the dark scheme is what makes these readable — with the
/// system in light mode, the material rendered light grey over black and
/// every secondary label washed out.
private struct MeetingCardChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(30)
      .frame(maxWidth: 430)
      .background(.regularMaterial, in: .rect(cornerRadius: 24))
      .overlay {
        RoundedRectangle(cornerRadius: 24)
          .strokeBorder(.white.opacity(0.14))
      }
      .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
      .padding(24)
      .environment(\.colorScheme, .dark)
  }
}

extension View {
  fileprivate func meetingCardChrome() -> some View {
    modifier(MeetingCardChrome())
  }
}

extension MeetingView {
  fileprivate static let preJoinStates: [MeetingController.ConnectionState] = [
    .connecting, .waitingInLobby, .passwordRequired, .accessRequired, .waitingForHost,
  ]
}

/// The hold shown when the meeting itself continues but the room is
/// changing underneath it (a breakout-room switch): the same pre-join
/// states pass by, but re-showing the join form mid-meeting would read
/// as being thrown out.
private struct RoomSwitchCard: View {
  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("Switching rooms…")
        .foregroundStyle(.secondary)
    }
    .meetingCardChrome()
  }
}

/// The whole pre-join journey rendered as the first view's join form:
/// the same labeled fields (frozen) and Join button, with everything the
/// join still needs — host sign-in, the lobby wait, the meeting password —
/// expanding below the button. Credentials and expansion survive every
/// state change because the view itself does.
private struct PreJoinView: View {
  let configuration: MeetingConfiguration
  @ObservedObject var controller: MeetingController
  let cancel: () -> Void

  private enum Field {
    case username
    case password
    case meetingPassword
  }

  @State private var username = ""
  @State private var password = ""
  @State private var meetingPassword = ""
  @State private var submittedCredentials = false
  /// Set once the join has asked for a credential, so a submit that puts the
  /// state back to `.connecting` does not make the form disappear.
  @State private var credentialsRevealed = false
  @FocusState private var focusedField: Field?

  private var state: MeetingController.ConnectionState {
    controller.connectionState
  }

  var body: some View {
    ConnectionFormContainer { proxy in
      VStack(spacing: 24) {
        Spacer()

        Image(systemName: "video.fill")
          .font(.system(size: 52, weight: .semibold))
          .foregroundStyle(.tint)

        VStack(spacing: 6) {
          Text("Sangam")
            .font(.largeTitle.bold())
          Text("Join a Jitsi meeting")
            .foregroundStyle(.secondary)
        }

        // The same labeled form the user just filled in, frozen while the
        // join runs; Back returns to editing it.
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
          GridRow {
            fieldLabel("Server:")
            frozenField(configuration.serverURL.absoluteString)
          }
          GridRow {
            fieldLabel("Room:")
            frozenField(configuration.normalizedRoom)
          }
          GridRow {
            fieldLabel("Name:")
            frozenField(configuration.displayName)
          }
        }
        .frame(maxWidth: 420)

        // The Join button's slot: joining is underway, so it cancels now.
        Button(action: cancel) {
          Text("Cancel")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)
        .frame(maxWidth: 420)

        expansion
          .frame(maxWidth: 420)

        Spacer()

        // What the scroll chases when the fields appear or the keyboard
        // comes up; the Log in button sits just above it.
        Color.clear
          .frame(height: 1)
          .id(Self.bottomAnchor)
      }
      .onChange(of: showsCredentialFields) { _, shown in
        guard shown else { return }
        scrollToBottom(proxy)
      }
      .onChange(of: focusedField) { _, field in
        guard field != nil else { return }
        scrollToBottom(proxy)
      }
    }
    .animation(.snappy, value: state)
    .onAppear { adapt(to: state) }
    .onChange(of: state) { _, newState in adapt(to: newState) }
  }

  private static let bottomAnchor = "prejoin-bottom"

  /// Brings the foot of the form — the Log in button and what follows it —
  /// above the keyboard. The inset arrives a beat after the focus does, so
  /// scrolling immediately would leave the button back underneath it.
  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      withAnimation(.snappy) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
    }
  }

  /// Whatever the join still needs, below the Join button.
  @ViewBuilder
  private var expansion: some View {
    VStack(spacing: 18) {
      // Both unlock paths, offered together: a meeting password, or an
      // admin sign-in. One Log in button submits whichever is filled.
      if showsCredentialFields {
        VStack(spacing: 14) {
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
              fieldLabel("Meeting password:")
              SecureField("", text: $meetingPassword)
                .accessibilityLabel("Meeting password")
                .focused($focusedField, equals: .meetingPassword)
                .submitLabel(.join)
                .onSubmit(submitMeetingPassword)
            }
            GridRow {
              Text("or")
                .foregroundStyle(.secondary)
                .gridCellColumns(2)
                .frame(maxWidth: .infinity)
            }
            GridRow {
              fieldLabel("Admin user:")
              TextField("", text: $username)
                .accessibilityLabel("Admin user")
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                  .textInputAutocapitalization(.never)
                #endif
                .focused($focusedField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
            }
            GridRow {
              fieldLabel("Admin password:")
              SecureField("", text: $password)
                .accessibilityLabel("Admin password")
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(submitAdminCredentials)
            }
          }
          .textFieldStyle(.roundedBorder)

          Button(action: submit) {
            Text("Log in")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!canSubmit || state == .connecting)

          if state == .accessRequired {
            Button("Wait for a host instead") { controller.waitForHost() }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
          }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }

      if let message = controller.accessMessage {
        Label(message, systemImage: "exclamationmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      // Where the join stands, at the foot of the form: under the Log in
      // button when there is one, and on its own when the join needs
      // nothing from the user.
      if let status = statusText {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text(status)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.trailing)
  }

  /// A field's value in the first view's rounded-border clothing, without
  /// being editable mid-join.
  private func frozenField(_ value: String) -> some View {
    TextField("", text: .constant(value))
      .textFieldStyle(.roundedBorder)
      .disabled(true)
  }

  /// The credential fields show whenever they could unblock the join —
  /// waiting in the lobby, waiting for a host, or when the server demands
  /// one of them outright.
  private var showsCredentialFields: Bool {
    switch state {
    case .waitingInLobby, .waitingForHost, .accessRequired, .passwordRequired:
      return true
    case .connecting:
      // Submitting does not take the form away. The attempt can come back
      // refused, and the fields it was typed into should still be there
      // when it does rather than being handed back a second time.
      return credentialsRevealed
    default:
      return false
    }
  }

  private var trimmedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    !meetingPassword.isEmpty || (!trimmedUsername.isEmpty && !password.isEmpty)
  }

  private var statusText: String? {
    switch state {
    case .connecting:
      return submittedCredentials ? "Signing in…" : "Joining…"
    case .waitingInLobby:
      return controller.lobbyWaitsForHost
        ? "Waiting for a host to arrive — you’ll join automatically."
        : "Waiting to be admitted — the host has been asked to let you in."
    case .waitingForHost:
      return "Waiting for a host to start the meeting…"
    default:
      return nil
    }
  }

  private func adapt(to state: MeetingController.ConnectionState) {
    switch state {
    case .waitingInLobby, .waitingForHost, .accessRequired, .passwordRequired:
      credentialsRevealed = true
    default:
      break
    }
    switch state {
    case .accessRequired:
      submittedCredentials = false
      focus(.username)
    case .passwordRequired:
      focus(.meetingPassword)
    default:
      break
    }
  }

  /// macOS applies focus only once the window is key; set it, then check
  /// again shortly after.
  private func focus(_ field: Field) {
    focusedField = field
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(200))
      if focusedField == nil { focusedField = field }
    }
  }

  /// Submits whichever unlock path is filled in. Admin credentials win
  /// when both are: signing in also joins, with the stronger role.
  private func submit() {
    if !trimmedUsername.isEmpty, !password.isEmpty {
      submitAdminCredentials()
    } else {
      submitMeetingPassword()
    }
  }

  private func submitAdminCredentials() {
    guard state != .connecting, !trimmedUsername.isEmpty, !password.isEmpty else { return }
    focusedField = nil
    submittedCredentials = true
    controller.authenticate(username: trimmedUsername, password: password)
  }

  private func submitMeetingPassword() {
    guard state != .connecting, !meetingPassword.isEmpty else { return }
    focusedField = nil
    controller.joinWithMeetingPassword(meetingPassword)
  }
}
