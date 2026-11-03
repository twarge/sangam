#if os(macOS)
  import AppKit
  import JitsiNativeCore
  import SwiftUI

  /// The space bar as the microphone's key, in the window this sits in: a
  /// tap mutes or unmutes, a hold talks — or, unmuted, coughs — until you let
  /// go. `PushToTalkKey` tells the two apart.
  ///
  /// It takes the key only in a joined meeting, while its window is key with
  /// no sheet up, and while nothing is being typed: a text field and the
  /// notes editor keep their spaces. When it takes the key it swallows it, so
  /// a focused button is not pressed by the same space.
  struct SpacebarMicrophone: NSViewRepresentable {
    let controller: MeetingController?

    func makeNSView(context: Context) -> Host {
      let host = Host()
      host.controller = controller
      return host
    }

    func updateNSView(_ host: Host, context: Context) {
      host.controller = controller
    }

    final class Host: NSView {
      /// kVK_Space: the key's place on the keyboard, whatever the layout.
      private static let spaceKeyCode: UInt16 = 49

      var controller: MeetingController? {
        didSet { if controller !== oldValue { cancelPress(on: oldValue) } }
      }
      private var key = PushToTalkKey()
      private var monitor: Any?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(
          self, name: NSWindow.didResignKeyNotification, object: nil)
        cancelPress(on: controller)
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
          [weak self] event in
          self?.handle(event) == true ? nil : event
        }
        // The key-up goes wherever focus went — another window, another
        // app — so a press under way ends with the focus.
        NotificationCenter.default.addObserver(
          self, selector: #selector(windowDidResignKey),
          name: NSWindow.didResignKeyNotification, object: window)
      }

      @objc private func windowDidResignKey() {
        cancelPress(on: controller)
      }

      /// Whether the event was the space bar's, and taken.
      private func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.spaceKeyCode else { return false }
        if event.type == .keyUp {
          guard key.isPressed else { return false }
          let muted = key.keyUp(muted: controller?.isAudioMuted ?? false, at: event.timestamp)
          if let muted { controller?.setAudioMuted(muted) }
          return true
        }
        // A held key repeats; the repeats are the press's own.
        if key.isPressed { return true }
        guard !event.isARepeat, takesSpace(event), let controller,
          controller.connectionState == .joined
        else { return false }
        if let muted = key.keyDown(muted: controller.isAudioMuted, at: event.timestamp) {
          controller.setAudioMuted(muted)
        }
        return true
      }

      /// Whether a space typed now is the microphone's rather than the
      /// window's.
      private func takesSpace(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow,
          window.attachedSheet == nil
        else { return false }
        // Typing: a text field's editor and the notes are both NSText.
        if window.firstResponder is NSText { return false }
        // Modified spaces are the system's and the menus'.
        return event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
      }

      /// Ends a press whose key-up will never arrive here, putting the
      /// microphone back as a hold would.
      private func cancelPress(on controller: MeetingController?) {
        let muted = key.cancel(muted: controller?.isAudioMuted ?? false)
        if let muted { controller?.setAudioMuted(muted) }
      }
    }
  }
#endif
