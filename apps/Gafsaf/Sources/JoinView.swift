import SwiftUI

struct JoinView: View {
  @Binding var serverURL: String
  @Binding var room: String
  @Binding var displayName: String
  var join: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "video.fill")
        .font(.system(size: 52, weight: .semibold))
        .foregroundStyle(.tint)

      VStack(spacing: 6) {
        Text("Gafsaf")
          .font(.largeTitle.bold())
        Text("Join a Jitsi meeting")
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 12) {
        TextField("Room name", text: $room)
          .textFieldStyle(.roundedBorder)
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
  }
}
