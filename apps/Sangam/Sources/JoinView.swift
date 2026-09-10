import SwiftUI

struct JoinView: View {
  @Binding var serverURL: String
  @Binding var room: String
  @Binding var displayName: String
  var join: () -> Void

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
              #if os(iOS)
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
          }
          GridRow {
            fieldLabel("Name:")
            TextField("Display name", text: $displayName)
              .textFieldStyle(.roundedBorder)
              .onSubmit(join)
          }
        }
        .frame(maxWidth: 420)

        Button(action: join) {
          Text("Join Meeting")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .frame(maxWidth: 420)

        Spacer()
      }
    }
    .defaultFocus($focusedField, .room)
    .onAppear(perform: focusRoomField)
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
