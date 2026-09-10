#if os(macOS)
  import AppKit
  import JitsiMeetingNotes
  import SwiftUI

  struct ConversationSidebar: View {
    @ObservedObject var session: ConversationSession
    var allowsHiding = true

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "note.text")
          Text("Conversation").font(.headline)
          if session.document.isDirty {
            Circle().fill(.secondary).frame(width: 6, height: 6)
              .accessibilityLabel("Unsaved changes")
          }
          Spacer()
          Button {
            Task { await session.save() }
          } label: {
            Image(systemName: "square.and.arrow.down")
          }
          .help("Save Markdown")
          .keyboardShortcut("s", modifiers: .command)
          if allowsHiding {
            Button {
              session.isOpen = false
            } label: {
              Image(systemName: "sidebar.right")
            }
            .help("Hide conversation")
          }
        }
        .buttonStyle(.borderless)
        .padding(14)

        HStack {
          if session.meetingActive {
            Button {
              if session.isRecording || session.isPreparing {
                session.stop()
              } else {
                session.start()
              }
            } label: {
              Label(
                session.isRecording || session.isPreparing ? "Stop" : "Transcribe",
                systemImage: session.isRecording ? "stop.circle.fill" : "waveform")
            }
            .disabled(session.isFinishing)
            Picker("Language", selection: $session.localeIdentifier) {
              ForEach(languageOptions, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .labelsHidden()
            .disabled(session.isRecording || session.isPreparing || session.isFinishing)
          } else {
            Label("Meeting ended", systemImage: "checkmark.circle")
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        Divider()
        ConversationEditor(session: session)
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Text(session.status)
          if !session.transcriptionNotice.isEmpty { Text(session.transcriptionNotice) }
          if !session.summaryStatus.isEmpty { Text(session.summaryStatus) }
          if session.isRecording {
            Text("Gray words are still settling. Completed turns are editable.")
          }
          if !session.isRecording && !session.isPreparing && session.meetingActive {
            Text("Transcription stays on this device. Let others know before starting.")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      .background(.background)
      .background(ConversationWindowGuard(session: session))
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

  private struct ConversationEditor: NSViewRepresentable {
    @ObservedObject var session: ConversationSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false
      let editor = ConversationTextView()
      editor.session = session
      editor.isRichText = false
      editor.isAutomaticQuoteSubstitutionEnabled = false
      editor.isAutomaticDashSubstitutionEnabled = false
      editor.isAutomaticTextReplacementEnabled = false
      editor.isAutomaticSpellingCorrectionEnabled = false
      editor.isContinuousSpellCheckingEnabled = true
      editor.allowsUndo = false
      editor.drawsBackground = false
      editor.isVerticallyResizable = true
      editor.isHorizontallyResizable = false
      editor.autoresizingMask = [.width]
      editor.textContainer?.widthTracksTextView = true
      editor.textContainer?.containerSize = NSSize(
        width: 0, height: CGFloat.greatestFiniteMagnitude)
      editor.textContainerInset = NSSize(width: 14, height: 14)
      editor.minSize = NSSize(width: 0, height: 0)
      editor.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      editor.delegate = context.coordinator
      editor.setAccessibilityLabel("Conversation Markdown editor")
      scroll.documentView = editor
      context.coordinator.apply(to: editor)
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      if let editor = scroll.documentView as? ConversationTextView {
        context.coordinator.apply(to: editor)
      }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
      let session: ConversationSession
      var rendering: ConversationDocument.Rendering
      private var pending: (ConversationDocument.Field, String)?
      private var applying = false
      private var currentRendering: ConversationDocument.Rendering {
        session.document.render(
          allowUnfinishedEdits: !session.isRecording && !session.isPreparing && !session.isFinishing
        )
      }
      init(session: ConversationSession) {
        self.session = session
        rendering = session.document.render()
      }

      func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
      ) -> Bool {
        guard !applying, let replacementString,
          let region = rendering.region(containing: affectedCharRange),
          let value = session.document.value(for: region.field)
        else { return false }
        if region.field == .title && replacementString.contains(where: \.isNewline) { return false }
        session.setComposing(true)
        let range = NSRange(
          location: affectedCharRange.location - region.range.location,
          length: affectedCharRange.length)
        pending = (
          region.field, (value as NSString).replacingCharacters(in: range, with: replacementString)
        )
        return true
      }

      /// A click that lands outside every field — the blank line under an
      /// empty Notes heading, a heading itself, the space below the last
      /// line — moves to the nearest field, so typing goes where the click
      /// looked like it would go. An empty field is one position wide, which
      /// leaves the Notes section all but impossible to click into: every
      /// keystroke beside that single position is silently refused.
      ///
      /// Only for the mouse. Arrowing out of a field is a deliberate move
      /// through the document, and pulling the caret back would trap it
      /// there.
      func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying, let editor = notification.object as? NSTextView,
          !editor.hasMarkedText(), editor.window?.firstResponder === editor,
          let event = NSApp.currentEvent,
          event.type == .leftMouseDown || event.type == .leftMouseUp
            || event.type == .leftMouseDragged
        else { return }
        let selection = editor.selectedRange()
        guard selection.length == 0, rendering.region(containing: selection) == nil,
          let nearest = rendering.nearestPosition(to: selection.location),
          nearest != selection.location
        else { return }
        editor.setSelectedRange(NSRange(location: nearest, length: 0))
      }

      func textDidChange(_ notification: Notification) {
        guard !applying, let editor = notification.object as? NSTextView else { return }
        if let pending {
          session.edit(pending.0, text: pending.1)
          self.pending = nil
        }
        // The next input event must use the new field offsets immediately,
        // before SwiftUI has had a chance to update the representable.
        rendering = currentRendering
        if !editor.hasMarkedText() { apply(to: editor) }
        session.setComposing(editor.hasMarkedText())
      }

      func apply(to editor: NSTextView) {
        // IME composition is one user transaction. Wait for it to commit before
        // touching the text storage, even when a recognition update arrives.
        guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        let updated = currentRendering
        let selection = editor.selectedRange()
        let anchor = rendering.region(containing: selection)
        let anchorOffset = anchor.map { selection.location - $0.range.location }
        let scroll = editor.enclosingScrollView
        let scrollOrigin = scroll?.contentView.bounds.origin ?? .zero
        let atBottom = (scroll?.contentView.bounds.maxY ?? 0) >= editor.bounds.height - 24
        let following =
          atBottom
          && (editor.window?.firstResponder !== editor
            || selection.location >= editor.string.utf16.count)
        applying = true
        storage.beginEditing()
        if editor.string != updated.text {
          // Apply a single minimal replacement, then restore selection by field
          // identity. Automatic edits never enter the user's semantic undo stack.
          let old = Array(editor.string.utf16)
          let new = Array(updated.text.utf16)
          var prefix = 0
          while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
          if prefix > 0, prefix < old.count, (0xDC00...0xDFFF).contains(old[prefix]) { prefix -= 1 }
          var suffix = 0
          while suffix < min(old.count, new.count) - prefix,
            old[old.count - suffix - 1] == new[new.count - suffix - 1]
          { suffix += 1 }
          if suffix > 0, (0xDC00...0xDFFF).contains(old[old.count - suffix]) { suffix -= 1 }
          let replacement = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
          storage.replaceCharacters(
            in: NSRange(location: prefix, length: old.count - prefix - suffix), with: replacement)
        }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(
          [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
          ], range: full)
        if let headings = try? NSRegularExpression(pattern: "(?m)^#{1,2} .+$") {
          for match in headings.matches(in: updated.text, range: full) {
            storage.addAttribute(
              .font, value: NSFont.systemFont(ofSize: 15, weight: .semibold), range: match.range)
          }
        }
        for range in updated.provisionalRanges {
          storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        storage.endEditing()
        if let anchor, let offset = anchorOffset,
          let region = updated.regions.first(where: { $0.field == anchor.field })
        {
          let location = region.range.location + min(offset, region.range.length)
          editor.setSelectedRange(
            NSRange(
              location: location, length: min(selection.length, NSMaxRange(region.range) - location)
            ))
        } else {
          editor.setSelectedRange(
            NSRange(location: min(selection.location, storage.length), length: 0))
        }
        editor.typingAttributes = [
          .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
          .foregroundColor: NSColor.labelColor,
        ]
        rendering = updated
        applying = false
        if following {
          editor.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        } else if let scroll {
          scroll.contentView.scroll(to: scrollOrigin)
          scroll.reflectScrolledClipView(scroll.contentView)
        }
      }
    }
  }

  private final class ConversationTextView: NSTextView {
    weak var session: ConversationSession?
    override var undoManager: UndoManager? { session?.undoManager }
    @objc func undo(_ sender: Any?) { session?.undoManager.undo() }
    @objc func redo(_ sender: Any?) { session?.undoManager.redo() }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
      if menuItem.action == #selector(undo(_:)) { return session?.undoManager.canUndo == true }
      if menuItem.action == #selector(redo(_:)) { return session?.undoManager.canRedo == true }
      return super.validateMenuItem(menuItem)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if event.modifierFlags.contains(.command),
        event.charactersIgnoringModifiers?.lowercased() == "z"
      {
        if event.modifierFlags.contains(.shift) { redo(nil) } else { undo(nil) }
        return true
      }
      return super.performKeyEquivalent(with: event)
    }
  }

  /// The root view installs this too, so a hidden sidebar still has the native
  /// dirty indicator and the same close protection.
  struct ConversationWindowGuard: NSViewRepresentable {
    @ObservedObject var session: ConversationSession
    func makeNSView(context: Context) -> Host {
      let view = Host()
      view.session = session
      return view
    }
    func updateNSView(_ view: Host, context: Context) {
      view.window?.isDocumentEdited = session.document.isDirty
    }
    final class Host: NSView {
      weak var session: ConversationSession?
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let session else { return }
        session.window = window
        ConversationWindowRegistry.shared.install(window: window, session: session)
      }
    }
  }

  @MainActor
  final class ConversationWindowRegistry {
    static let shared = ConversationWindowRegistry()
    private var delegates: [ObjectIdentifier: CloseDelegate] = [:]
    func install(window: NSWindow, session: ConversationSession) {
      let key = ObjectIdentifier(window)
      guard delegates[key] == nil else { return }
      let delegate = CloseDelegate(session: session, previous: window.delegate)
      delegates[key] = delegate
      window.delegate = delegate
    }
    func resolveAll() async -> Bool {
      for delegate in Array(delegates.values) {
        if let session = delegate.session, !(await session.resolveUnsaved()) { return false }
      }
      return true
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
      weak var session: ConversationSession?
      nonisolated(unsafe) weak var previous: NSWindowDelegate?
      private var allowed = false
      init(session: ConversationSession, previous: NSWindowDelegate?) {
        self.session = session
        self.previous = previous
      }
      func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowed, let session, session.hasDocument else {
          return previous?.windowShouldClose?(sender) ?? true
        }
        Task { [weak self, weak sender] in
          guard await session.resolveUnsaved(), let self, let sender else { return }
          allowed = true
          sender.performClose(nil)
          allowed = false
        }
        return false
      }
      func windowWillClose(_ notification: Notification) {
        session?.endMeeting()
        previous?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow {
          ConversationWindowRegistry.shared.delegates.removeValue(forKey: ObjectIdentifier(window))
        }
      }
      nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
      }
      nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
      }
    }
  }

  final class ConversationApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      Task {
        sender.reply(
          toApplicationShouldTerminate: await ConversationWindowRegistry.shared.resolveAll())
      }
      return .terminateLater
    }
  }
#endif
