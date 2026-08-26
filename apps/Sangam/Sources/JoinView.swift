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
        TextField("Room name", text: $room)
          .textFieldStyle(.roundedBorder)
          .focused($focusedField, equals: .room)
          .onSubmit(join)
        TextField("Display name", text: $displayName)
          .textFieldStyle(.roundedBorder)
          .onSubmit(join)
        TextField("Jitsi server", text: $serverURL)
          .textFieldStyle(.roundedBorder)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
          #endif
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
