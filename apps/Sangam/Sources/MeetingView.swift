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

      // One card carries the whole pre-join journey — joining, waiting in
      // the lobby, host sign-in, meeting password — so typed credentials
      // and context survive every state change instead of swapping views.
      if Self.preJoinStates.contains(controller.connectionState) {
        PreJoinCard(
          configuration: configuration,
          controller: controller,
          cancel: dismiss
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
      // Leaving any pre-join hold is navigation, not an action on the card.
      if Self.preJoinStates.contains(controller.connectionState) {
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
      MeetingHub.shared.noteMeetingEnded(controller: controller)
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

  private var meetingSurface: some View {
    NativeMeetingSurface(configuration: configuration, controller: controller)
  }
}

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

/// The whole pre-join journey on one card: joining, waiting in the lobby,
/// host sign-in, and the meeting password. Credentials and expansion
/// survive every state change because the card itself does; status renders
/// beneath the sign-in information rather than replacing it.
private struct PreJoinCard: View {
  let configuration: MeetingConfiguration
  @ObservedObject var controller: MeetingController
  let cancel: () -> Void

  private enum Expansion {
    case none
    case hostLogin
    case meetingPassword
  }

  private enum Field {
    case username
    case password
    case meetingPassword
  }

  @State private var expanded: Expansion = .none
  @State private var username = ""
  @State private var password = ""
  @State private var meetingPassword = ""
  @State private var submittedCredentials = false
  @FocusState private var focusedField: Field?

  private var state: MeetingController.ConnectionState {
    controller.connectionState
  }

  var body: some View {
    VStack(spacing: 18) {
      // Where we are headed, and the way back to editing it.
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(configuration.normalizedRoom)
            .font(.title3.bold())
          Text(configuration.serverURL.host ?? configuration.serverURL.absoluteString)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Button("Edit", action: cancel)
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
      }

      Divider()

      if showsHostLogin {
        VStack(spacing: 10) {
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
                || password.isEmpty || state == .connecting
            )
            .frame(maxWidth: .infinity)
          if state == .accessRequired {
            Button("Wait for a host instead") { controller.waitForHost() }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
          }
        }
        .textFieldStyle(.roundedBorder)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      } else if expanded == .meetingPassword {
        VStack(spacing: 10) {
          SecureField("Meeting password", text: $meetingPassword)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .meetingPassword)
            .onSubmit(submitMeetingPassword)
          Button("Join with password", action: submitMeetingPassword)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(meetingPassword.isEmpty || state == .connecting)
            .frame(maxWidth: .infinity)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      } else if offersExpansions {
        HStack(spacing: 10) {
          Button("Enter meeting password") { expanded = .meetingPassword }
          Button("Host sign in") { expanded = .hostLogin }
        }
        .buttonStyle(.bordered)
      }

      if let message = controller.accessMessage {
        Label(message, systemImage: "exclamationmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let status = statusText {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text(status)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      // Cancelling the join tears down whatever the bootstrap opened.
      Button("Cancel", role: .cancel, action: cancel)
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
    }
    .meetingCardChrome()
    .animation(.snappy, value: expanded)
    .animation(.snappy, value: state)
    .onAppear { adapt(to: state) }
    .onChange(of: state) { _, newState in adapt(to: newState) }
  }

  /// The sign-in fields stay open once used — status appears below them —
  /// and open themselves when the server demands credentials.
  private var showsHostLogin: Bool {
    expanded == .hostLogin || state == .accessRequired
  }

  private var offersExpansions: Bool {
    state == .waitingInLobby || state == .waitingForHost
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
    case .accessRequired:
      submittedCredentials = false
      expanded = .hostLogin
      focus(.username)
    case .passwordRequired:
      expanded = .meetingPassword
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

  private func submitCredentials() {
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty, !password.isEmpty else { return }
    submittedCredentials = true
    controller.authenticate(username: normalizedUsername, password: password)
  }

  private func submitMeetingPassword() {
    guard !meetingPassword.isEmpty else { return }
    controller.joinWithMeetingPassword(meetingPassword)
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
        .strokeBorder(.white.opacity(0.14))
    }
    .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
    .environment(\.colorScheme, .dark)
  }
}
