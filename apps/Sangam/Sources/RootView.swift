import SwiftUI

struct RootView: View {
  @AppStorage("serverURL") private var serverURL = MeetingConfiguration.defaultServerURL
    .absoluteString
  @AppStorage("displayName") private var displayName = ""
  @AppStorage("room") private var room = ""
  @State private var activeMeeting: MeetingConfiguration?
  @ObservedObject private var hub = MeetingHub.shared
  /// Transcription lives here so it outlives the meeting view: on the Mac it
  /// is also the notes document, and on iOS it is what the captions read.
  @StateObject private var conversation = ConversationSession()

  var body: some View {
    Group {
      if let activeMeeting {
        // A different meeting is a different view tree: joining a link while
        // already in a room tears the old meeting down cleanly.
        MeetingView(configuration: activeMeeting, conversation: conversation) {
          conversation.endMeeting()
          self.activeMeeting = nil
        }
        .id(activeMeeting)
      } else {
        #if os(macOS)
          if conversation.hasDocument {
            VStack(spacing: 0) {
              HStack {
                Text("Conversation notes").font(.headline)
                Spacer()
                Button("Done") {
                  Task {
                    if await conversation.resolveUnsaved() { conversation.discard() }
                  }
                }
              }
              .padding()
              ConversationSidebar(session: conversation, allowsHiding: false)
            }
          } else {
            joinForm
          }
        #else
          joinForm
        #endif
      }
    }
    #if os(macOS)
      .background(ConversationWindowGuard(session: conversation))
        #if DEBUG
          .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if #available(macOS 26, *),
              let index = arguments.firstIndex(of: "--conversation-audio-preview"),
              index + 2 < arguments.count, !conversation.hasDocument
            {
              Task {
                await conversation.loadAudioPreview(
                  URL(fileURLWithPath: arguments[index + 1]),
                  URL(fileURLWithPath: arguments[index + 2]))
              }
            } else if arguments.contains("--conversation-preview"), !conversation.hasDocument {
              conversation.loadPreview()
            }
          }
        #endif
    #endif
    #if os(macOS)
      .frame(minWidth: 320, minHeight: 400)
    #endif
    #if DEBUG
      .onAppear {
        guard MeetingLayoutPreviewMode.current != nil, activeMeeting == nil else { return }
        let configuration = MeetingConfiguration(
          serverURL: URL(string: "https://example.invalid")!,
          room: "Layout Preview", displayName: "Taylor")
        conversation.configure(configuration)
        // Nothing is transcribed in a preview, so the captions get a
        // scripted conversation to follow instead.
        conversation.loadCaptionPreview()
        activeMeeting = configuration
      }
    #endif
    .navigationTitle(activeMeeting?.normalizedRoom ?? "Sangam")
    .onOpenURL { url in MeetingHub.shared.requestJoin(url: url) }
    .onContinueUserActivity(MeetingHub.meetingActivityType) { activity in
      if let url = activity.webpageURL { MeetingHub.shared.requestJoin(url: url) }
    }
    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { MeetingHub.shared.requestJoin(url: url) }
    }
    .onReceive(hub.$pendingJoin) { pending in
      guard let pending else { return }
      hub.pendingJoin = nil
      #if os(macOS)
        Task {
          guard await conversation.resolveUnsaved() else { return }
          conversation.discard()
          conversation.configure(pending)
          activeMeeting = pending
          room = pending.room
          serverURL = pending.serverURL.absoluteString
        }
      #else
        activeMeeting = pending
        room = pending.room
        serverURL = pending.serverURL.absoluteString
      #endif
    }
  }

  private var joinForm: some View {
    JoinView(
      serverURL: $serverURL,
      room: $room,
      displayName: $displayName,
      join: join
    )
  }

  private func join() {
    guard
      let server = URL(string: serverURL),
      let scheme = server.scheme?.lowercased(),
      scheme == "https" || (scheme == "http" && server.host == "localhost")
    else { return }

    let normalizedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRoom.isEmpty else { return }

    let configuration = MeetingConfiguration(
      serverURL: server,
      room: normalizedRoom,
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    conversation.configure(configuration)
    activeMeeting = configuration
  }
}
