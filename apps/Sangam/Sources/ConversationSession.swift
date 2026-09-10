#if os(macOS) || os(iOS)
  import Combine
  import JitsiConference
  import JitsiMeetingNotes
  import UniformTypeIdentifiers

  #if os(macOS)
    import AppKit
  #endif

  @MainActor
  final class ConversationSession: ObservableObject {
    @Published private(set) var document = ConversationDocument(title: "Conversation")
    @Published var isOpen = false
    @Published private(set) var hasDocument = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinishing = false
    @Published private(set) var meetingActive = false
    @Published private(set) var status = "Transcription is off."
    @Published private(set) var transcriptionNotice = ""
    @Published private(set) var summaryStatus = ""
    /// The last line or two of speech, for the captions over the video. It
    /// empties itself once the room goes quiet.
    ///
    /// The lines live on their own object rather than being published here.
    /// A caption on screen runs a 200 ms ticker to age it out, and published
    /// on the session every one of those ticks invalidated each view
    /// observing it — the control bar and its More menu included, and UIKit
    /// reloads an open menu on every rebuild, resetting its scroll and
    /// swallowing taps. Only the overlay watches this.
    let captionFeed = CaptionFeed()

    /// The caption lines, apart from the session so their ticker redraws the
    /// overlay and nothing else.
    @MainActor
    final class CaptionFeed: ObservableObject {
      @Published fileprivate(set) var lines: [ConversationDocument.CaptionLine] = []
    }
    @Published var localeIdentifier = Locale.current.identifier
    @Published var sidebarWidth: CGFloat = 400
    let undoManager = UndoManager()
    #if os(macOS)
      weak var window: NSWindow?
    #endif
    private var roster: [ConversationDocument.Participant] = []
    private var streams: [String: RemoteAudioStream] = [:]
    private var localMuted = false
    private var origin = ProcessInfo.processInfo.systemUptime
    private var transcriber: AnyObject?
    private var summarizer: AnyObject?
    private var preparation: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryID = UUID()
    private var summaryTimer: Task<Void, Never>?
    private var editRefresh: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var captionTimer: Task<Void, Never>?
    #if DEBUG
      private var captionPreview: Task<Void, Never>?
    #endif
    private var epoch = UUID()
    private var lastSummaryRevision: UInt64?
    private var resolving = false
    private var savedURL: URL?
    /// Whether this platform writes summaries. Both do: the generator always
    /// compiled on either, and iOS now has a notes surface to show a summary
    /// in. Generating one on device mid-call costs battery, which is the
    /// accepted price of the phone carrying the same document as the Mac.
    private static let summarizes = true
    #if os(macOS)
      private static let versionRequirement =
        "On-device transcription requires macOS 26 or later. You can still write notes."
    #else
      private static let versionRequirement =
        "On-device transcription requires iOS 26 or later. You can still write notes."
    #endif

    /// Whether this document's transcription started itself rather than
    /// being asked for, and has not been opened, edited or saved since. Such
    /// a document is nobody's work in progress, so it leaves without asking.
    private var startedAutomatically = false
    private var composing = false
    private var deferredUpdates: [@MainActor () -> Void] = []

    func setComposing(_ value: Bool) {
      composing = value
      guard !value else { return }
      let updates = deferredUpdates
      deferredUpdates.removeAll()
      for update in updates { update() }
    }

    private func automatically(_ update: @escaping @MainActor () -> Void) {
      if composing { deferredUpdates.append(update) } else { update() }
    }

    func configure(_ configuration: MeetingConfiguration) {
      meetingActive = true
      document = ConversationDocument(title: configuration.normalizedRoom)
      roster = [
        .init(
          id: "local", name: configuration.displayName.isEmpty ? "You" : configuration.displayName)
      ]
      origin = ProcessInfo.processInfo.systemUptime
      streams = [:]
      hasDocument = false
      isOpen = false
      savedURL = nil
      lastSummaryRevision = nil
      summarizer = nil
      undoManager.removeAllActions()
      status = "Transcription is off."
      summaryStatus = ""
      transcriptionNotice = ""
      startedAutomatically = false
      summaryTimer?.cancel()
      summaryTimer = nil
      clearCaptions()
    }

    func open() {
      beginDocument()
      isOpen = true
      // Once it has been read, the document is the reader's, however it
      // started.
      startedAutomatically = false
    }

    /// The document exists as soon as anything is being recorded into it,
    /// whether or not its sidebar is on screen.
    private func beginDocument() {
      hasDocument = true
      document.updateParticipants(roster)
      startSummaryTimer()
    }

    /// The summary revises itself on a timer for as long as the document is
    /// alive: while speech arrives, and afterwards while it is corrected.
    /// Nothing has to ask for it. Ticks are cheap — a revision that has
    /// already been summarized returns immediately, and one generation at a
    /// time is in flight.
    private func startSummaryTimer() {
      guard Self.summarizes, summaryTimer == nil else { return }
      summaryTimer = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
          self?.refreshSummary()
        }
      }
    }

    func toggleSidebar() {
      if isOpen { isOpen = false } else { open() }
    }

    func updateParticipants(_ participants: [RemoteParticipant]) {
      roster =
        roster.filter { $0.id == "local" }
        + participants.map {
          .init(id: $0.id, name: $0.displayName)
        }
      if hasDocument {
        let current = roster
        automatically { [weak self] in self?.document.updateParticipants(current) }
      }
    }

    func updateAudio(_ stream: RemoteAudioStream) {
      streams[stream.id] = stream
      synchronizeStreams()
    }

    func removeAudio(_ id: String) {
      streams.removeValue(forKey: id)
      synchronizeStreams()
    }

    func removeAllAudio() {
      streams.removeAll()
      synchronizeStreams()
    }

    private func synchronizeStreams() {
      if #available(macOS 26, iOS 26, *), let transcriber = transcriber as? AppleMeetingTranscriber
      {
        let current = Array(streams.values)
        Task { await transcriber.setRemoteStreams(current) }
      }
    }

    func setLocalMuted(_ muted: Bool) {
      guard localMuted != muted else { return }
      localMuted = muted
      if #available(macOS 26, iOS 26, *), let transcriber = transcriber as? AppleMeetingTranscriber
      {
        Task { await transcriber.setLocalMuted(muted) }
      }
    }

    /// Starts transcribing because the preference says calls transcribe
    /// themselves, rather than because someone pressed Transcribe. It stays
    /// out of the way — the notes sidebar is not put in front of anyone —
    /// and does nothing where on-device transcription is unavailable, so an
    /// automatic start never leaves an empty document behind to save.
    func startAutomatically() {
      guard #available(macOS 26, iOS 26, *), meetingActive, !hasDocument else { return }
      startedAutomatically = true
      start(revealingNotes: false)
    }

    func start(revealingNotes: Bool = true) {
      guard meetingActive, !isPreparing, !isRecording, !isFinishing else { return }
      if revealingNotes { open() } else { beginDocument() }
      guard #available(macOS 26, iOS 26, *) else {
        status = Self.versionRequirement
        return
      }
      epoch = UUID()
      let currentEpoch = epoch
      isPreparing = true
      transcriptionNotice = ""
      status = "Preparing on-device transcription and downloading the language if needed…"
      preparation = Task { [weak self] in
        guard let self else { return }
        do {
          let locale = try await AppleMeetingTranscriber.prepare(
            locale: Locale(identifier: localeIdentifier))
          guard !Task.isCancelled, self.epoch == currentEpoch, meetingActive else { return }
          let transcriber = AppleMeetingTranscriber(locale: locale, origin: origin) {
            [weak self] result in
            guard let self, self.epoch == currentEpoch else { return }
            self.automatically { [weak self] in
              guard let self, self.epoch == currentEpoch else { return }
              self.document.recognize(
                streamID: result.streamID, participantID: result.participantID,
                start: result.start, end: result.end, text: result.text, isFinal: result.isFinal)
              self.refreshCaptions()
            }
          } report: { [weak self] message in
            guard let self, self.epoch == currentEpoch else { return }
            self.transcriptionNotice = message
          }
          self.transcriber = transcriber
          isPreparing = false
          isRecording = true
          status = "Transcribing on this device."
          await transcriber.setRemoteStreams(Array(streams.values))
          guard self.epoch == currentEpoch, isRecording else { return }
          await transcriber.setLocalMuted(localMuted)
        } catch {
          guard self.epoch == currentEpoch else { return }
          isPreparing = false
          status = error.localizedDescription
        }
      }
    }

    func stop() {
      guard isRecording || isPreparing else { return }
      preparation?.cancel()
      preparation = nil
      isPreparing = false
      isRecording = false
      isFinishing = true
      let service = transcriber
      let finishingEpoch = epoch
      transcriber = nil
      status = "Finishing transcription…"
      finishTask = Task { [weak self] in
        if #available(macOS 26, iOS 26, *), let service = service as? AppleMeetingTranscriber {
          await service.finish()
        }
        guard let self, epoch == finishingEpoch else { return }
        isFinishing = false
        status = "Transcription stopped."
        refreshSummary()
      }
    }

    func endMeeting() {
      meetingActive = false
      stop()
      streams.removeAll()
      #if os(macOS)
        // The Mac reviews the document after the call; iOS has no review
        // screen to open into, and a sheet appearing as the meeting closes
        // would only flash.
        if hasDocument { isOpen = true }
      #endif
      // A transcription that started itself and heard nothing — a call
      // nobody spoke on, or one where preparing the language failed —
      // leaves nothing worth reviewing. Drop it once any final results are
      // in, rather than ending every such call on the notes screen with an
      // empty transcript to save. A document somebody actually opened is
      // theirs to keep, empty or not.
      let finishing = finishTask
      Task { [weak self] in
        await finishing?.value
        guard let self, hasDocument, !meetingActive, startedAutomatically,
          document.turns.isEmpty, document.notes.isEmpty
        else { return }
        discard()
      }
    }

    /// Recomputes the caption lines against the conversation clock. The
    /// ticker runs only while something is on screen to age out — new speech
    /// republishes the document on its own — so a quiet meeting costs
    /// nothing.
    private func refreshCaptions() {
      // Captions are for hearing the room, not yourself: your own words are
      // in the transcript, but reading them back over the video is noise.
      let updated = document.captions(
        at: ProcessInfo.processInfo.systemUptime - origin, excludingSpeaker: "local")
      if updated != captionFeed.lines { captionFeed.lines = updated }
      if updated.isEmpty {
        captionTimer?.cancel()
        captionTimer = nil
      } else if captionTimer == nil {
        captionTimer = Task { [weak self] in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            refreshCaptions()
          }
        }
      }
    }

    private func clearCaptions() {
      captionTimer?.cancel()
      captionTimer = nil
      captionFeed.lines = []
    }

    func edit(_ field: ConversationDocument.Field, text: String) {
      guard let previous = document.value(for: field), previous != text else { return }
      startedAutomatically = false
      undoManager.registerUndo(withTarget: self) { target in target.edit(field, text: previous) }
      undoManager.setActionName("Edit Conversation")
      document.edit(field, text: text)
      // An in-flight response is discarded by content revision if the user
      // edits its source. Debounce edits so corrections after hangup also
      // refresh the summary without generating once per keystroke.
      editRefresh?.cancel()
      editRefresh = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        self?.refreshSummary()
      }
    }

    func refreshSummary() {
      guard Self.summarizes else { return }
      guard #available(macOS 26, iOS 26, *), hasDocument, summaryTask == nil,
        lastSummaryRevision != document.contentRevision
      else { return }
      guard document.turns.contains(where: { $0.isFinal && !$0.text.isEmpty }) else { return }
      if summarizer == nil { summarizer = ConversationSummarizer() }
      guard let summarizer = summarizer as? ConversationSummarizer else { return }
      let snapshot = document
      let currentEpoch = epoch
      summaryID = UUID()
      let requestID = summaryID
      summaryStatus = "Updating summary…"
      summaryTask = Task { [weak self] in
        defer { if self?.summaryID == requestID { self?.summaryTask = nil } }
        do {
          let output = try await summarizer.summarize(snapshot)
          guard !Task.isCancelled, let self, epoch == currentEpoch, summaryID == requestID else {
            return
          }
          automatically { [weak self] in
            guard let self, self.epoch == currentEpoch, self.summaryID == requestID else { return }
            let applied = self.document.applySummary(
              title: output.title, summary: output.markdown, basedOn: snapshot)
            if applied { self.lastSummaryRevision = snapshot.contentRevision }
            if applied && self.document.contentRevision == snapshot.contentRevision {
              self.summaryStatus = "Summary updated."
            } else {
              self.summaryStatus = "Summary will refresh with the latest changes."
              // After hangup there is no timer; retry once current work exits.
              if !self.isRecording {
                Task { [weak self] in
                  await Task.yield()
                  self?.refreshSummary()
                }
              }
            }
          }
        } catch is CancellationError {} catch {
          if let self, epoch == currentEpoch, summaryID == requestID {
            summaryStatus = error.localizedDescription
          }
        }
      }
    }

    // Exporting and the unsaved-changes gate are AppKit: a save panel, an
    // alert on the window, and the window itself. iOS runs this session for
    // captions and has no notes surface to save from, so neither is called
    // there; both want an iOS presentation of their own when it does.
    #if os(macOS)
      @discardableResult
      func save() async -> Bool {
        startedAutomatically = false
        if let savedURL { return write(to: savedURL) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Conversation.md"
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window {
          response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
          }
        } else {
          response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return false }
        if write(to: url) {
          savedURL = url
          return true
        }
        return false
      }

      private func write(to url: URL) -> Bool {
        let snapshot = document
        do {
          try Data(snapshot.markdown.utf8).write(to: url, options: .atomic)
          document.markSaved(revision: snapshot.revision)
          return true
        } catch {
          status = "Could not save: \(error.localizedDescription)"
          return false
        }
      }

      /// Every destructive navigation path, window close and application quit
      /// uses this same gate. Hanging up merely leaves a reviewable document.
      func resolveUnsaved() async -> Bool {
        guard !resolving else { return false }
        resolving = true
        setComposing(false)
        defer { resolving = false }
        // A transcription that started itself and was never opened is not work
        // anybody has done: asking to save it would put a dialog at the end of
        // every call. It is offered on the review screen instead, where the
        // transcript is visible and Save is a click away.
        guard hasDocument, !startedAutomatically,
          document.isDirty || isRecording || isPreparing || isFinishing
        else {
          freezeSummary()
          return true
        }
        let alert = NSAlert()
        alert.messageText = "Save this conversation?"
        alert.informativeText =
          "Your transcript and notes have unsaved changes. Discard permanently removes the unsaved information."
        alert.addButton(withTitle: "Save Markdown…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        let response: NSApplication.ModalResponse
        if let window {
          response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
          }
        } else {
          response = alert.runModal()
        }
        if response == .alertFirstButtonReturn {
          let resumeOnCancel = isRecording || isPreparing
          stop()
          await finishTask?.value
          // Give the final summary time to finish before exporting. Cancellation
          // of a late response also invalidates its document revision token.
          let deadline = ContinuousClock.now.advanced(by: .seconds(15))
          let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.freezeSummary()
          }
          while ContinuousClock.now < deadline {
            refreshSummary()
            guard let currentSummary = summaryTask else { break }
            await currentSummary.value
            if lastSummaryRevision == document.contentRevision
              || !summaryStatus.hasPrefix("Summary will refresh")
            {
              break
            }
          }
          timeout.cancel()
          freezeSummary()
          if await save() { return true }
          if resumeOnCancel, meetingActive { start() }
        } else if response == .alertSecondButtonReturn {
          discard()
          return true
        }
        return false
      }
    #endif

    private func freezeSummary() {
      editRefresh?.cancel()
      editRefresh = nil
      summaryID = UUID()
      summaryTask?.cancel()
      summaryTask = nil
    }

    func discard() {
      epoch = UUID()
      summaryID = UUID()
      composing = false
      deferredUpdates.removeAll()
      let service = transcriber
      transcriber = nil
      isPreparing = false
      isRecording = false
      isFinishing = false
      finishTask?.cancel()
      finishTask = nil
      if #available(macOS 26, iOS 26, *), let service = service as? AppleMeetingTranscriber {
        Task { await service.cancel() }
      }
      preparation?.cancel()
      summaryTask?.cancel()
      summaryTimer?.cancel()
      editRefresh?.cancel()
      clearCaptions()
      preparation = nil
      summaryTask = nil
      summaryTimer = nil
      editRefresh = nil
      document = ConversationDocument(title: "Conversation")
      hasDocument = false
      isOpen = false
      startedAutomatically = false
      savedURL = nil
      summarizer = nil
      lastSummaryRevision = nil
      transcriptionNotice = ""
      undoManager.removeAllActions()
    }

    #if DEBUG
      #if os(macOS)
        @available(macOS 26, iOS 26, *)
        static func runSpeechSelfTest(_ first: URL, _ second: URL) async -> Bool {
          let session = ConversationSession()
          await session.loadAudioPreview(first, second)
          await session.summaryTask?.value
          var proposal = ConversationDocument(title: "Proposal test")
          proposal.updateParticipants([.init(id: "alex", name: "Alex")])
          proposal.recognize(
            streamID: "proposal", participantID: "alex", start: 0, end: 1,
            text: "We should review the release schedule today.", isFinal: true)
          let proposalOutput = try? await ConversationSummarizer().summarize(proposal)
          let proposalsExcluded =
            proposalOutput?.markdown.contains("No explicit actions identified yet.") == true
          let actions = session.document.summary.components(separatedBy: "\n").filter {
            $0.hasPrefix("- [ ]")
          }
          let commitmentsRetained =
            actions.count == 2 && actions.contains { $0.contains("Alex") }
            && actions.contains { $0.contains("Sam") }
          let output =
            session.document.markdown + "\nSTATUS: " + session.status + "\nNOTICE: "
            + session.transcriptionNotice
            + "\nSUMMARY: " + session.summaryStatus + "\nPROPOSALS EXCLUDED: \(proposalsExcluded)"
            + "\nCOMMITMENTS RETAINED: \(commitmentsRetained)\n"
          FileHandle.standardOutput.write(Data(output.utf8))
          return proposalsExcluded && commitmentsRetained && session.transcriptionNotice.isEmpty
            && session.document.turns.count >= 4
            && session.document.turns.allSatisfy(\.isFinal)
            && session.document.summary != "Summary will appear as the conversation develops."
        }

        @available(macOS 26, iOS 26, *)
        func loadAudioPreview(_ first: URL, _ second: URL) async {
          hasDocument = true
          isOpen = true
          meetingActive = false
          document = ConversationDocument(title: "Conversation — sample speech")
          document.updateParticipants([
            .init(id: "alex", name: "Alex"), .init(id: "sam", name: "Sam"),
          ])
          status = "Transcribing generated sample speech; the microphone is off."
          let result: @MainActor @Sendable (AppleMeetingTranscriber.Result) -> Void = {
            [weak self] result in
            self?.automatically { [weak self] in
              self?.document.recognize(
                streamID: result.streamID, participantID: result.participantID,
                start: result.start, end: result.end, text: result.text, isFinal: result.isFinal)
            }
          }
          let report: @MainActor @Sendable (String) -> Void = { [weak self] message in
            self?.transcriptionNotice = message
            FileHandle.standardError.write(Data((message + "\n").utf8))
          }
          do {
            async let a: Void = AppleMeetingTranscriber.transcribeFixture(
              first, participantID: "alex", offset: 0, result: result, report: report)
            async let b: Void = AppleMeetingTranscriber.transcribeFixture(
              second, participantID: "sam", offset: 2, result: result, report: report)
            _ = try await (a, b)
            status = "Sample transcription complete; the microphone is off."
            refreshSummary()
          } catch { status = "Sample transcription failed: \(error.localizedDescription)" }
        }
      #endif

      /// Feeds the caption overlay a rolling fixture conversation so the
      /// layout preview shows captions without a call: lines arrive, scroll
      /// up and fade out on the same clock a meeting uses.
      func loadCaptionPreview() {
        beginDocument()
        // The fixture stands in for a call transcribing itself in the
        // background, down to leaving without a save prompt.
        startedAutomatically = true
        document.updateParticipants([
          .init(id: "alex", name: "Alex"), .init(id: "sam", name: "Sam"),
        ])
        let script = [
          ("alex", "We should review the release schedule today."),
          ("sam", "I’ll check the remaining dependencies and send the list tomorrow."),
          ("alex", "That works — let’s confirm the localization pass as well."),
          ("sam", "Agreed. I’ll write it up in the notes."),
        ]
        captionPreview?.cancel()
        captionPreview = Task { [weak self] in
          var index = 0
          while !Task.isCancelled {
            guard let self else { return }
            let spoken = script[index % script.count]
            let elapsed = ProcessInfo.processInfo.systemUptime - origin
            document.recognize(
              streamID: "preview-\(index)", participantID: spoken.0,
              start: elapsed, end: elapsed + 2, text: spoken.1, isFinal: true)
            refreshCaptions()
            index += 1
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
          }
        }
      }

      func loadPreview() {
        hasDocument = true
        isOpen = true
        meetingActive = false
        document = ConversationDocument(title: "Conversation — release planning")
        document.updateParticipants([
          .init(id: "alex", name: "Alex"), .init(id: "sam", name: "Sam"),
        ])
        document.recognize(
          streamID: "alex-1", participantID: "alex", start: 1, end: 3,
          text: "We should review the release schedule today.", isFinal: true)
        document.recognize(
          streamID: "sam-1", participantID: "sam", start: 2.5, end: 5,
          text: "I’ll check the remaining dependencies and send the updated list tomorrow.",
          isFinal: true)
        document.recognize(
          streamID: "alex-1", participantID: "alex", start: 6, end: 8,
          text: "Let’s also make sure the documentation", isFinal: false)
        document.applySummary(
          title: document.title,
          summary:
            "Alex and Sam reviewed the upcoming release. Dependency checks remain open.\n\n- [ ] Sam: send the updated dependency list tomorrow.",
          basedOn: document.contentRevision)
        document.edit(.notes, text: "Check accessibility before the release.\n")
        status = "Preview — no audio is being recorded."
      }
    #endif
  }
#endif
