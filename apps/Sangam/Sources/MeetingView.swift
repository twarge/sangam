import SwiftUI

struct MeetingView: View {
  let configuration: MeetingConfiguration
  let dismiss: () -> Void

  @StateObject private var controller = MeetingController()

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
        LobbyWaitingCard(waitsForHost: controller.lobbyWaitsForHost, leave: dismiss)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }

      if controller.connectionState == .joined {
        MeetingControlBar(controller: controller)
          .padding(.horizontal, 16)
          .padding(.bottom, 14)
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
  }

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

/// Shown while the meeting's lobby holds us. There is nothing to do but wait
/// or give up: admission arrives on its own.
private struct LobbyWaitingCard: View {
  let waitsForHost: Bool
  let leave: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "person.crop.circle.badge.clock")
        .font(.system(size: 35, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 68, height: 68)
        .background(.tint.opacity(0.14), in: .circle)

      VStack(spacing: 7) {
        Text("Waiting to be let in")
          .font(.title2.bold())
        Text(
          waitsForHost
            ? "This meeting has a lobby. You’ll join automatically once a host arrives."
            : "This meeting has a lobby. You’ll join as soon as the host admits you."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }

      ProgressView()
        .controlSize(.large)
        .padding(.vertical, 8)

      Button("Leave meeting", role: .cancel, action: leave)
        .buttonStyle(.bordered)
        .controlSize(.large)
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
