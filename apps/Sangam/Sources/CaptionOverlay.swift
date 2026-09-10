#if os(macOS) || os(iOS)
  import JitsiMeetingNotes
  import SwiftUI

  /// The closed captions over the video: the last line or two of what is
  /// being transcribed, newest at the bottom. New speech pushes the block up
  /// and the lines fade out a few seconds after they were spoken, so the
  /// captions clear themselves whenever the room goes quiet.
  ///
  /// The lines come from the conversation document, which means they follow
  /// corrections made in the notes sidebar and disappear along with a turn
  /// somebody deleted.
  struct CaptionOverlay: View {
    @ObservedObject var feed: ConversationSession.CaptionFeed
    @ObservedObject private var settings = AppSettings.shared
    /// A phone has room for a line or two of ordinary text; a Mac window or
    /// an iPad can carry the larger size comfortably.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
      let lines = settings.showsCaptions ? feed.lines : []
      VStack(alignment: .leading, spacing: 4) {
        ForEach(lines) { line in
          CaptionLineView(line: line, compact: horizontalSizeClass == .compact)
            .transition(
              .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                // A line pushed out by newer speech leaves upwards, and
                // quickly: the line below is gliding into the space it is
                // vacating, and a slow crossfade would print one over the
                // other.
                removal: .move(edge: .top).combined(with: .opacity)
                  .animation(.easeOut(duration: 0.14))
              ))
        }
      }
      .frame(maxWidth: 720, alignment: .leading)
      // Captions are for reading, never for clicking: taps belong to the
      // tile underneath, which pins it.
      .allowsHitTesting(false)
      .animation(.smooth(duration: 0.25), value: lines.map(\.id))
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Live captions")
    }
  }

  private struct CaptionLineView: View {
    let line: ConversationDocument.CaptionLine
    let compact: Bool

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 8) {
        Text(line.speaker)
          .font((compact ? Font.caption : .callout).weight(.semibold))
          .foregroundStyle(.white.opacity(0.6))
        Text(line.text)
          .font((compact ? Font.subheadline : .title3).weight(.medium))
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, compact ? 10 : 14)
      .padding(.vertical, compact ? 6 : 8)
      .background(.black.opacity(0.62), in: .rect(cornerRadius: 10))
      .opacity(line.opacity)
      .animation(.easeOut(duration: 0.25), value: line.opacity)
    }
  }
#endif
