#if os(iOS)
  import JitsiMeetingNotes
  import SwiftUI

  /// The conversation on iOS: the editable document — title, summary and
  /// notes — alongside the transcript, as a sheet that slides up over the
  /// stage.
  ///
  /// The document itself is the Mac's, unchanged: `ConversationDocument` is
  /// platform-neutral and `ConversationSession` drives it the same way on
  /// both. Only the editor differs. The Mac renders the whole document as
  /// Markdown in one NSTextView with editable regions; a phone gets the
  /// three fields as fields, which is the better shape for a touch keyboard
  /// and needs none of that text-storage machinery.
  ///
  /// The transcript carries the whole room, your own side included: the
  /// local microphone is tapped beside the call rather than through it.
  struct ConversationPane: View {
    @ObservedObject var session: ConversationSession
    /// A sidebar carries its own title row and sits on the system's own
    /// surface. As a sheet it fills the sheet, which supplies both.
    var isSidebar = false

    private enum Pane: Hashable { case notes, transcript }

    @State private var pane: Pane = .notes
    /// Drafts rather than bindings straight through to the document: the
    /// summarizer rewrites the summary mid-call, and writing that into a
    /// field somebody is typing in would move the cursor under them. The
    /// focused field is left alone until they leave it.
    @State private var title = ""
    @State private var summary = ""
    @State private var notes = ""
    @FocusState private var focused: ConversationDocument.Field?

    var body: some View {
      Group {
        if isSidebar {
          // A panel carries its own header. A nested NavigationStack hands
          // its toolbar to the meeting's own navigation bar, which spreads
          // the title and buttons across the whole stage instead of keeping
          // them in the column they belong to.
          VStack(spacing: 0) {
            panelHeader
            Divider()
            paneContent
          }
          .safeAreaInset(edge: .bottom) { footer }
        } else {
          NavigationStack {
            paneContent
              .navigationTitle("Conversation")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  ShareLink(item: session.document.markdown) {
                    Label("Share Markdown", systemImage: "square.and.arrow.up")
                  }
                }
                ToolbarItem(placement: .confirmationAction) {
                  // The same state opens both presentations, so closing is
                  // the same act whether this is a sheet or a panel.
                  Button("Done") { session.isOpen = false }
                }
              }
              .safeAreaInset(edge: .bottom) { footer }
          }
        }
      }
      // No forced scheme and no card. As a sidebar this sits in the
      // platform's own inspector column, which supplies the material and
      // takes it to the window edges; as a sheet the sheet supplies both.
      .onAppear { syncDrafts() }
      // The document changes under the editor whenever speech is recognized
      // or a summary lands; the revision is what says the content actually
      // moved rather than a turn merely settling.
      .onChange(of: session.document.contentRevision) { _, _ in syncDrafts() }
      .onChange(of: title) { _, text in session.edit(.title, text: text) }
      .onChange(of: summary) { _, text in session.edit(.summary, text: text) }
      .onChange(of: notes) { _, text in session.edit(.notes, text: text) }
    }

    private var paneContent: some View {
      VStack(spacing: 0) {
        Picker("View", selection: $pane) {
          Text("Notes").tag(Pane.notes)
          Text("Transcript").tag(Pane.transcript)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

        switch pane {
        case .notes: notesEditor
        case .transcript: transcript
        }
      }
    }

    /// The sidebar's own toolbar: what it is, and the two things you can do
    /// to it from here.
    private var panelHeader: some View {
      HStack(spacing: 12) {
        Text("Conversation")
          .font(.headline)
        Spacer(minLength: 8)
        ShareLink(item: session.document.markdown) {
          Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Share Markdown")
        Button {
          session.isOpen = false
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
      }
      .buttonStyle(.borderless)
      .font(.body.weight(.medium))
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }

    private func syncDrafts() {
      if focused != .title, let value = session.document.value(for: .title) { title = value }
      if focused != .summary, let value = session.document.value(for: .summary) { summary = value }
      if focused != .notes, let value = session.document.value(for: .notes) { notes = value }
    }

    private var notesEditor: some View {
      Form {
        Section("Title") {
          TextField("Conversation", text: $title, axis: .vertical)
            .focused($focused, equals: .title)
        }
        Section {
          TextEditor(text: $summary)
            .focused($focused, equals: .summary)
            .frame(minHeight: 120)
        } header: {
          Text("Summary")
        } footer: {
          if !session.summaryStatus.isEmpty { Text(session.summaryStatus) }
        }
        Section("Notes") {
          TextEditor(text: $notes)
            .focused($focused, equals: .notes)
            .frame(minHeight: 140)
        }
      }
      .scrollContentBackground(.hidden)
    }

    private var transcript: some View {
      Group {
        if session.document.turns.isEmpty {
          ContentUnavailableView(
            "Nothing transcribed yet",
            systemImage: "text.quote",
            description: Text(session.status)
          )
        } else {
          turns
        }
      }
    }

    private var turns: some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(session.document.turns) { turn in
              VStack(alignment: .leading, spacing: 3) {
                Text(session.document.name(for: turn.participantID))
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(.secondary)
                Text(turn.text)
                  .font(.callout)
                  .textSelection(.enabled)
                  // Gray while recognition is still settling on the words,
                  // the same signal the Mac's editor gives.
                  .foregroundStyle(turn.isFinal ? .primary : .secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(turn.id)
            }
          }
          .padding(16)
        }
        .onChange(of: session.document.turns.count) { _, _ in
          guard let last = session.document.turns.last else { return }
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
    }

    /// The transcription control and what the session has to say for itself,
    /// the same pair the Mac's sidebar carries under its editor.
    @ViewBuilder private var footer: some View {
      VStack(alignment: .leading, spacing: 8) {
        if session.meetingActive {
          HStack {
            let running = session.isRecording || session.isPreparing
            Button {
              if running { session.stop() } else { session.start() }
            } label: {
              Image(systemName: running ? "pause.fill" : "waveform")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.circle)
            .disabled(session.isFinishing)
            .accessibilityLabel(running ? "Pause transcription" : "Start transcription")
            Spacer(minLength: 0)
            Picker("Language", selection: $session.localeIdentifier) {
              ForEach(languageOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .labelsHidden()
            // A 300pt panel has no room for "English (United States)" on
            // three lines.
            .lineLimit(1)
            .disabled(session.isRecording || session.isPreparing || session.isFinishing)
          }
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(session.status)
          if !session.transcriptionNotice.isEmpty { Text(session.transcriptionNotice) }
          if !session.isRecording && !session.isPreparing && session.meetingActive {
            Text("Transcription stays on this device. Let others know before starting.")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.bar)
    }

    private var languageOptions: [(String, String)] {
      let defaults = [
        "en-US", "en-GB", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ja-JP", "ko-KR", "zh-CN",
        "hi-IN",
      ]
      let ids = Set(defaults + [session.localeIdentifier])
      return ids.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
        .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }
  }

  /// The conversation as a bottom sheet, for a window too narrow to give it
  /// a column of its own.
  struct TranscriptSheet: View {
    @ObservedObject var session: ConversationSession

    var body: some View {
      ConversationPane(session: session)
        .meetingSheetChrome()
    }
  }

  extension View {
    /// The chrome the meeting's bottom sheets share: opaque and dark like
    /// the rest of the call, because the captions and the control bar sit
    /// directly behind them and reading through those is no good.
    func meetingSheetChrome() -> some View {
      environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.12))
    }
  }
#endif
