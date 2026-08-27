import SwiftUI

struct MeetingView: View {
  let configuration: MeetingConfiguration
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

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black
        .ignoresSafeArea()

      // On macOS the surface manages safe areas itself: the stage ignores
      // them (video runs under the titlebar), while the floating sidebar
      // must start below the toolbar.
      meetingSurface
        #if os(iOS)
          .ignoresSafeArea()
        #endif

      if controller.connectionState == .connecting {
        VStack(spacing: 14) {
          ProgressView("Joining…")
          // Leaving the meeting view cancels the in-flight join and tears
          // down whatever the bootstrap already opened.
          Button("Cancel", role: .cancel, action: dismiss)
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if controller.connectionState == .accessRequired
        || controller.connectionState == .waitingForHost
      {
        MeetingAccessCard(
          isWaiting: controller.connectionState == .waitingForHost,
          message: controller.accessMessage,
          authenticate: controller.authenticate,
          waitForHost: controller.waitForHost,
          useAccount: controller.cancelWaiting,
          leave: dismiss
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }

      if controller.connectionState == .waitingInLobby {
        LobbyWaitingCard(
          waitsForHost: controller.lobbyWaitsForHost,
          authenticate: controller.authenticate,
          joinWithPassword: controller.joinWithMeetingPassword
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }

      if controller.connectionState == .passwordRequired {
        MeetingPasswordCard(
          message: controller.accessMessage,
          join: controller.joinWithMeetingPassword
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }

      if controller.connectionState == .joined {
        meetingToolbar
      }
    }
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { windowWidth = geometry.size.width }
          .onChange(of: geometry.size.width) { _, width in windowWidth = width }
      }
    }
    .overlay(alignment: .topLeading) {
      // Leaving the waiting room is navigation, not an action on the card.
      if controller.connectionState == .waitingInLobby
        || controller.connectionState == .passwordRequired
      {
        Button(action: dismiss) {
          Label("Back", systemImage: "chevron.backward")
            .font(.body.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.white.opacity(0.1), in: .capsule)
        .padding(16)
        .keyboardShortcut(.cancelAction)
      }
    }
    .overlay(alignment: .top) {
      if controller.connectionState == .joined, !controller.lobbyRequests.isEmpty {
        LobbyRequestsPanel(
          requests: controller.lobbyRequests,
          admit: controller.admitLobbyParticipant,
          deny: controller.denyLobbyParticipant
        )
        .padding(.top, 18)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: controller.lobbyRequests)
    .background(.black)
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
      if state == .ended {
        dismiss()
      }
    }
    // System surfaces (menu bar, Siri, CallKit) reach the meeting through
    // the hub; Handoff advertises the meeting link so another device can
    // pick the call up.
    .onAppear {
      MeetingHub.shared.noteMeetingStarted(configuration, controller: controller)
    }
    .onDisappear {
      MeetingHub.shared.noteMeetingEnded()
    }
    .userActivity(
      MeetingHub.meetingActivityType,
      isActive: controller.connectionState == .joined
    ) { activity in
      activity.title = "Meeting: \(configuration.normalizedRoom)"
      activity.webpageURL = configuration.meetingLink
      activity.isEligibleForHandoff = true
    }
    #if os(iOS)
      // The meeting is a system call while joined: call-priority audio,
      // system mute, arbitration with phone calls.
      .onChange(of: controller.connectionState) { _, state in
        switch state {
        case .joined:
          CallSessionManager.shared.begin(room: configuration.normalizedRoom)
          MeetingActivityController.shared.begin(room: configuration.normalizedRoom)
        case .ended, .failed:
          CallSessionManager.shared.end()
          MeetingActivityController.shared.end()
        default:
          break
        }
      }
      .onChange(of: controller.isAudioMuted) { _, muted in
        CallSessionManager.shared.setMuted(muted)
        MeetingActivityController.shared.update(muted: muted)
      }
      .onDisappear {
        CallSessionManager.shared.end()
        MeetingActivityController.shared.end()
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

  private var chatInset: CGFloat {
    controller.isChatOpen ? 312 : 0
  }

  @ViewBuilder
  private var meetingToolbar: some View {
    #if os(macOS)
      // Only the bar's own footprint is hover-sensitive: the outer wrapper
      // keeps the exact bounds hit-testable (and so hoverable) even while
      // the bar inside is invisible and ignoring clicks.
      ZStack {
        MeetingControlBar(
          controller: controller,
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
      // iOS has no pointer to hover with; the bar stays put.
      MeetingControlBar(
        controller: controller,
        popoverPinned: $toolbarPinned,
        availableWidth: toolbarAvailableWidth
      )
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
    #endif
  }

  #if os(macOS)
    private func updateToolbarVisibility() {
      toolbarHideTask?.cancel()
      if toolbarHovered || toolbarPinned {
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

  @ViewBuilder
  private var meetingSurface: some View {
    #if os(iOS)
      if NativeTransportMode.isEnabled {
        NativeMeetingSurface(configuration: configuration, controller: controller)
      } else {
        PlatformMeetingSurface(configuration: configuration, controller: controller)
      }
    #else
      NativeMeetingSurface(configuration: configuration, controller: controller)
    #endif
  }
}

private struct MeetingAccessCard: View {
  let isWaiting: Bool
  let message: String?
  let authenticate: (String, String) -> Void
  let waitForHost: () -> Void
  let useAccount: () -> Void
  let leave: () -> Void

  @State private var username = ""
  @State private var password = ""
  @FocusState private var focusedField: Field?

  private enum Field {
    case username
    case password
  }

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: isWaiting ? "person.2.wave.2.fill" : "lock.shield.fill")
        .font(.system(size: 35, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 68, height: 68)
        .background(.tint.opacity(0.14), in: .circle)

      VStack(spacing: 7) {
        Text(isWaiting ? "Waiting for a host" : "This meeting needs a host")
          .font(.title2.bold())
        Text(
          isWaiting
            ? "You’ll join automatically when an authorized host starts the meeting."
            : "Sign in with a conference account, or wait for a host to start the room."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }

      if isWaiting {
        ProgressView()
          .controlSize(.large)
          .padding(.vertical, 8)

        Button("Sign in instead", action: useAccount)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .frame(maxWidth: .infinity)
      } else {
        VStack(spacing: 12) {
          TextField("Username", text: $username)
            .textContentType(.username)
            .focused($focusedField, equals: .username)
            .onSubmit { focusedField = .password }
          SecureField("Password", text: $password)
            .textContentType(.password)
            .focused($focusedField, equals: .password)
            .onSubmit(submitCredentials)
        }
        .textFieldStyle(.roundedBorder)

        if let message {
          Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Button("Sign in and join", action: submitCredentials)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(
            username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || password.isEmpty
          )
          .frame(maxWidth: .infinity)

        Button("Wait for a host", action: waitForHost)
          .buttonStyle(.bordered)
          .controlSize(.large)
          .frame(maxWidth: .infinity)
      }

      Button("Leave meeting", role: .cancel, action: leave)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
    .padding(30)
    .frame(maxWidth: 430)
    .background(.regularMaterial, in: .rect(cornerRadius: 24))
    .overlay {
      RoundedRectangle(cornerRadius: 24)
        .strokeBorder(.white.opacity(0.12))
    }
    .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
    .padding(24)
    .animation(.snappy, value: isWaiting)
    .defaultFocus($focusedField, .username)
    .onAppear {
      // The card is also re-presented after a refused password, when it must
      // reclaim focus itself; `defaultFocus` only covers the first time.
      if !isWaiting { focusUsernameField() }
    }
    .onChange(of: isWaiting) { _, waiting in
      if !waiting { focusUsernameField() }
    }
  }

  /// macOS applies focus only once the window is key, and `onAppear` usually
  /// fires before that — so set it, then check again shortly after.
  private func focusUsernameField() {
    focusedField = .username
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(200))
      if focusedField == nil { focusedField = .username }
    }
  }

  private func submitCredentials() {
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty, !password.isEmpty else { return }
    authenticate(normalizedUsername, password)
  }
}

/// Asks for the meeting's password after the room refused a join without
/// one. Leaving is the Back button in the window's corner.
private struct MeetingPasswordCard: View {
  let message: String?
  let join: (String) -> Void

  @State private var password = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "key.fill")
        .font(.system(size: 35, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 68, height: 68)
        .background(.tint.opacity(0.14), in: .circle)

      VStack(spacing: 7) {
        Text("This meeting has a password")
          .font(.title2.bold())
        Text("Ask the host for the meeting password to join.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      SecureField("Meeting password", text: $password)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit(submit)

      if let message {
        Label(message, systemImage: "exclamationmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Button("Join Meeting", action: submit)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(password.isEmpty)
        .frame(maxWidth: .infinity)
    }
    .padding(30)
    .frame(maxWidth: 430)
    .background(.regularMaterial, in: .rect(cornerRadius: 24))
    .overlay {
      RoundedRectangle(cornerRadius: 24)
        .strokeBorder(.white.opacity(0.12))
    }
    .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
    .padding(24)
    .onAppear {
      focused = true
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(200))
        if !focused { focused = true }
      }
    }
  }

  private func submit() {
    guard !password.isEmpty else { return }
    join(password)
  }
}

/// Shown while the meeting's lobby holds us. Admission arrives on its own;
/// an administrator can instead sign in as a host, and anyone who knows the
/// meeting password can join with it directly. Leaving is the Back button
/// in the window's corner, not a card action.
private struct LobbyWaitingCard: View {
  let waitsForHost: Bool
  let authenticate: (String, String) -> Void
  let joinWithPassword: (String) -> Void

  @State private var expanded: Expansion = .none
  @State private var username = ""
  @State private var password = ""
  @State private var meetingPassword = ""
  @FocusState private var focusedField: Field?

  private enum Expansion {
    case none
    case login
    case meetingPassword
  }

  private enum Field {
    case username
    case password
    case meetingPassword
  }

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "person.crop.circle.badge.clock")
        .font(.system(size: 35, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 68, height: 68)
        .background(.tint.opacity(0.14), in: .circle)

      VStack(spacing: 7) {
        Text("Waiting to be admitted…")
          .font(.title2.bold())
        Text(
          waitsForHost
            ? "This meeting has a waiting room. You’ll join automatically once a host arrives."
            : "This meeting has a waiting room. You’ll join as soon as the host admits you."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }

      ProgressView()
        .controlSize(.large)
        .padding(.vertical, 4)

      switch expanded {
      case .login:
        VStack(spacing: 12) {
          TextField("Username", text: $username)
            .textContentType(.username)
            .focused($focusedField, equals: .username)
            .onSubmit { focusedField = .password }
          SecureField("Password", text: $password)
            .textContentType(.password)
            .focused($focusedField, equals: .password)
            .onSubmit(submitCredentials)
          Button("Sign in and join", action: submitCredentials)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
              username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || password.isEmpty
            )
            .frame(maxWidth: .infinity)
        }
        .textFieldStyle(.roundedBorder)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      case .meetingPassword:
        VStack(spacing: 12) {
          SecureField("Meeting password", text: $meetingPassword)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .meetingPassword)
            .onSubmit(submitMeetingPassword)
          Button("Join with password", action: submitMeetingPassword)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(meetingPassword.isEmpty)
            .frame(maxWidth: .infinity)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      case .none:
        HStack(spacing: 10) {
          Button("Enter meeting password") {
            expanded = .meetingPassword
          }
          .buttonStyle(.bordered)
          Button("Administrator login") {
            expanded = .login
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding(30)
    .frame(maxWidth: 430)
    .background(.regularMaterial, in: .rect(cornerRadius: 24))
    .overlay {
      RoundedRectangle(cornerRadius: 24)
        .strokeBorder(.white.opacity(0.12))
    }
    .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
    .padding(24)
    .animation(.snappy, value: expanded)
    .onChange(of: expanded) { _, expansion in
      switch expansion {
      case .login: focus(.username)
      case .meetingPassword: focus(.meetingPassword)
      case .none: break
      }
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

  private func submitCredentials() {
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty, !password.isEmpty else { return }
    authenticate(normalizedUsername, password)
  }

  private func submitMeetingPassword() {
    guard !meetingPassword.isEmpty else { return }
    joinWithPassword(meetingPassword)
  }
}

/// Hosts see who is knocking and let them in, or not, one at a time.
private struct LobbyRequestsPanel: View {
  let requests: [MeetingController.LobbyRequest]
  let admit: (String) -> Void
  let deny: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(
        requests.count == 1
          ? "Someone is waiting to join"
          : "\(requests.count) people are waiting to join",
        systemImage: "person.crop.circle.badge.clock"
      )
      .font(.headline)

      ForEach(requests) { request in
        HStack(spacing: 10) {
          Text(request.displayName)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 12)
          Button("Deny") { deny(request.id) }
            .buttonStyle(.bordered)
          Button("Admit") { admit(request.id) }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: 440)
    .background(.regularMaterial, in: .rect(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(.white.opacity(0.12))
    }
    .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
  }
}
