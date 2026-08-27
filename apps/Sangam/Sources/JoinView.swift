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

      VStack(spacing: 12) {
        TextField("Room name or meeting link", text: $room)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: .room)
          .onSubmit(join)
          // A pasted meeting link splits into its parts: the server fills
          // in below and the room field keeps just the room.
          .onChange(of: room) { _, text in
            guard text.contains("/") else { return }
            splitMeetingLink(text) { room = $0 }
          }
        TextField("Jitsi server", text: $serverURL)
          .textFieldStyle(.roundedBorder)
          // A full meeting link pasted here splits the other way: the room
          // moves up and the server keeps just the origin. A plain origin
          // (no room path) is left exactly as typed.
          .onChange(of: serverURL) { _, text in
            splitMeetingLink(text) { serverURL = $0 }
          }
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
          #endif
        TextField("Display name", text: $displayName)
          .textFieldStyle(.roundedBorder)
          .onSubmit(join)
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
    .padding(32)
    .defaultFocus($focusedField, .room)
    .onAppear(perform: focusRoomField)
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
