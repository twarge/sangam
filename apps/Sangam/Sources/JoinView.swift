import SwiftUI

struct JoinView: View {
  @Binding var serverURL: String
  @Binding var room: String
  @Binding var displayName: String
  var join: () -> Void
  /// Joins a meeting picked from the Recent list.
  var joinRecent: (RecentMeeting) -> Void

  @ObservedObject private var hub = MeetingHub.shared

  private enum Field {
    case room
  }

  @FocusState private var focusedField: Field?

  var body: some View {
    ConnectionFormContainer { _ in
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

        // A labeled two-column form: server first, then room, then name,
        // with the labels trailing-aligned against their fields.
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
          GridRow {
            fieldLabel("Server:")
            TextField("Jitsi server", text: $serverURL)
              .textFieldStyle(.roundedBorder)
              // A full meeting link pasted here splits the other way: the
              // room moves down and the server keeps just the origin. A
              // plain origin (no room path) is left exactly as typed.
              .onChange(of: serverURL) { _, text in
                splitMeetingLink(text) { serverURL = $0 }
              }
              #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
              #endif
          }
          GridRow {
            fieldLabel("Room:")
            TextField("Room name or meeting link", text: $room)
              .textFieldStyle(.roundedBorder)
              .focused($focusedField, equals: .room)
              .onSubmit(join)
              // A pasted meeting link splits into its parts: the server
              // fills in above and the room field keeps just the room.
              .onChange(of: room) { _, text in
                guard text.contains("/") else { return }
                splitMeetingLink(text) { room = $0 }
              }
              .autocorrectionDisabled()
              #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
              #endif
          }
          GridRow {
            fieldLabel("Name:")
            TextField("Display name", text: $displayName)
              .textFieldStyle(.roundedBorder)
              .onSubmit(join)
          }
        }
        .frame(maxWidth: 420)

        // A server the join can't use says so here rather than leaving the
        // button to do nothing.
        if let serverProblem {
          Label(serverProblem, systemImage: "exclamationmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: 420, alignment: .leading)
        }

        Button(action: join) {
          Text("Join Meeting")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(
          room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || serverProblem != nil
        )
        .frame(maxWidth: 420)

        if !hub.recentMeetings.isEmpty {
          RecentMeetingsList(
            meetings: Array(hub.recentMeetings.prefix(5)),
            join: joinRecent
          )
          .frame(maxWidth: 420)
        }

        // Where a meeting can live: the public server, or one of your own.
        Text(
          "Anyone can host meetings on [meet.jit.si](https://meet.jit.si), or [set up their own Jitsi server](https://jitsi.github.io/handbook/docs/devops-guide/) to host private conferences securely."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

        Spacer()
      }
    }
    .defaultFocus($focusedField, .room)
    .onAppear(perform: focusRoomField)
  }

  /// Why the server field can't be joined, or nil when it can.
  private var serverProblem: String? {
    guard MeetingConfiguration.serverURL(from: serverURL) == nil else { return nil }
    let text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "Enter the Jitsi server, like meet.jit.si." }
    if text.lowercased().hasPrefix("http://") {
      return "Sangam connects over HTTPS only. Use https:// for this server."
    }
    return "That isn't a server address. Enter one like meet.jit.si."
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.trailing)
  }

  /// Splits a pasted meeting link into the form's fields. A link carrying
  /// a `?jwt=` token is a complete instruction — the form has nowhere to
  /// hold the token, so it joins directly instead of dropping it.
  private func splitMeetingLink(_ text: String, resetField: (String) -> Void) {
    let candidate = text.contains("://") ? text : "https://" + text
    guard
      let url = URL(string: candidate),
      let parsed = MeetingHub.configuration(from: url)
    else { return }
    if parsed.token != nil {
      resetField("")
      MeetingHub.shared.pendingJoin = parsed
      return
    }
    serverURL = parsed.serverURL.absoluteString
    room = parsed.room
  }

  /// macOS applies focus only once the window is key, and `onAppear` usually
  /// fires before that — so set it, then check again shortly after.
  private func focusRoomField() {
    focusedField = .room
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(200))
      if focusedField == nil { focusedField = .room }
    }
  }
}

/// The meetings joined lately, under the Join button: a click fills in the
/// form and joins. A key marks a meeting that will sign itself in or enter
/// its password from the Keychain.
private struct RecentMeetingsList: View {
  let meetings: [RecentMeeting]
  let join: (RecentMeeting) -> Void

  private struct Saved: Equatable {
    var signIn = false
    var meetingPassword = false
  }

  /// What the Keychain holds for each meeting — read when the list changes,
  /// not on every keystroke in the form above.
  @State private var saved: [RecentMeeting.ID: Saved] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recent")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)

      VStack(spacing: 0) {
        ForEach(meetings) { meeting in
          RecentMeetingRow(
            meeting: meeting,
            savedSignIn: saved[meeting.id]?.signIn ?? false,
            savedMeetingPassword: saved[meeting.id]?.meetingPassword ?? false,
            join: { join(meeting) }
          )
          .contextMenu { menu(for: meeting) }
          if meeting.id != meetings.last?.id {
            Divider().padding(.leading, 42)
          }
        }
      }
      .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .task(id: meetings) { refresh() }
  }

  @ViewBuilder
  private func menu(for meeting: RecentMeeting) -> some View {
    Button("Join", systemImage: "video") { join(meeting) }
    if let server = meeting.serverURL {
      if saved[meeting.id]?.meetingPassword == true {
        Button("Forget Meeting Password", systemImage: "key.slash") {
          SavedCredentials.forgetMeetingPassword(server: server, room: meeting.room)
          refresh()
        }
      }
      if saved[meeting.id]?.signIn == true {
        Button("Forget Sign-in for \(meeting.serverName)", systemImage: "person.badge.key") {
          SavedCredentials.forgetAdminSignIn(for: server)
          refresh()
        }
      }
    }
    Divider()
    Button("Remove from Recent", systemImage: "trash", role: .destructive) {
      MeetingHub.shared.forgetRecentMeeting(meeting)
    }
  }

  private func refresh() {
    saved = Dictionary(
      meetings.compactMap { meeting in
        meeting.serverURL.map { server in
          (
            meeting.id,
            Saved(
              signIn: SavedCredentials.hasAdminSignIn(for: server),
              meetingPassword: SavedCredentials.hasMeetingPassword(
                server: server, room: meeting.room))
          )
        }
      },
      uniquingKeysWith: { first, _ in first })
  }
}

private struct RecentMeetingRow: View {
  let meeting: RecentMeeting
  let savedSignIn: Bool
  let savedMeetingPassword: Bool
  let join: () -> Void

  @State private var hovered = false

  var body: some View {
    Button(action: join) {
      HStack(spacing: 10) {
        Image(systemName: "clock.arrow.circlepath")
          .foregroundStyle(.secondary)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 1) {
          Text(meeting.room)
            .lineLimit(1)
          Text(meeting.serverName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if let savedNote {
          Image(systemName: "key.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(savedNote)
            .accessibilityLabel(savedNote)
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .background(hovered ? Color.primary.opacity(0.06) : .clear)
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help("Join \(meeting.room) on \(meeting.serverName)")
    .accessibilityElement(children: .combine)
    .accessibilityHint("Joins this meeting")
  }

  /// What the key stands for, when there is one.
  private var savedNote: String? {
    switch (savedSignIn, savedMeetingPassword) {
    case (true, true): "Signs in and enters the meeting password with saved passwords"
    case (true, false): "Signs in with the saved account for \(meeting.serverName)"
    case (false, true): "Enters the saved meeting password"
    case (false, false): nil
    }
  }
}

/// Keep the form centered when it fits and scrollable when the keyboard,
/// a short window, or larger text reduces the available space.
struct ConnectionFormContainer<Content: View>: View {
  /// The proxy is handed to the content so a form that grows — the join's
  /// unlock fields — can bring its own bottom back into view above the
  /// keyboard. Forms that never grow ignore it.
  @ViewBuilder var content: (ScrollViewProxy) -> Content

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          content(proxy)
            .padding(32)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(iOS)
          .scrollDismissesKeyboard(.interactively)
        #endif
      }
    }
  }
}
