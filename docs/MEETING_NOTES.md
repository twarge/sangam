# On-device meeting notes

On macOS, Notes in the bottom meeting controls opens an editable Markdown
sidebar; it moves into More when the controls have limited space. Calls
transcribe themselves from the first join, in the current language, under
**Transcribe from the start of a call** (Settings and the More menu, on by
default). That automatic start does not open the sidebar, and it does nothing
where on-device transcription is unavailable, so it never leaves an empty
document to save; a call that ends with no transcript and no notes discards
its document instead of offering it for review. A transcription nobody opened,
edited or saved also leaves without a save prompt — it is offered on the
review screen after the call, and closing or quitting from there discards it. **Transcribe** still starts and
stops transcription by hand, after choosing the spoken language, and a
transcription stopped by hand does not restart when a breakout-room switch
rejoins the conference.
Manual notes work on macOS 14 and later; Apple Speech and Foundation Models
require macOS 26 or later and available device/language assets. Transcription
does not require Apple Intelligence to be enabled; summarization does.

The document contains a conversation title, participants, a summary that
carries the action list, personal notes, and timestamp-ordered `Name:`
transcript turns. Every heading is followed by a blank line. Participants
come from Jitsi presence, including departed participants. The model never
supplies participant identities. Its title and summary update periodically
from finalized, corrected transcript text. A user edit to either field protects
it from subsequent model replacement. The Notes field is always user-owned.

## Platforms

Recognition, captions, the notes document and the summary all run on both
platforms.

Both transcribe the whole room, their own speaker included. Remote participants
are the recognizers the bridge feeds with decoded audio. The local microphone
cannot come the same way — WebRTC's local track implements no audio sink, which
`SGAudioTrackTap` enforces by rejecting any non-remote source — so it is tapped
with a second `AVAudioEngine` input alongside the call, on either platform.
Voice processing is switched on for that input only on macOS: iOS already holds
the session in `.voiceChat` for the call, so the input arrives echo-cancelled
by the system's own unit and a second one beside WebRTC's would collide with
it. The session is never reconfigured by the tap, and a microphone that will
not open is reported into the notes surface rather than thrown at the call.

iOS shows the document in a sheet — Transcript in the toolbar, the same state
that opens the Mac's sidebar — with the title, summary and notes editable as
three fields, the transcript beside them, and the Markdown offered through a
share sheet. What stays macOS-only is the shape of the editor, not the
document: the Mac renders the whole thing as Markdown in one NSTextView with
editable regions, which suits a pointer and a wide window rather than a touch
keyboard. The save/discard gate is macOS-only too, as is reviewing the document
after the call — on iOS the sheet lives inside the meeting.

On a phone both the chat and the transcript slide up from the bottom rather
than sitting beside the video: a 300pt panel leaves a phone's stage a sliver
and puts the message field under the keyboard. Both sheets carry the same dark
chrome as the rest of the call, since the captions and the control bar sit
directly behind them. A Mac and an iPad keep the side panel for chat.

The More menu drops its inline settings on a phone in favour of one entry that
opens the settings sheet. Each picker there expands to a row per choice, and
the menu grew tall enough to run off the top of the screen, taking whatever
was above it out of reach.

## Captions

The last line or two of transcription is captioned over the video, newest at
the bottom: new speech pushes the block up, and a line fades out five seconds
after the words on it were spoken, with one further second of fade, so the
captions clear themselves once the room goes quiet. Speech still in progress
keeps its line alive as words are added. Your own speech is left out — it is
in the transcript, but reading your own words back over the video is noise —
and the exclusion happens before the last lines are chosen, so talking over
yourself cannot push everyone else off the screen. Lines are derived from the
document, not from recognition directly, so they follow corrections and
disappear with a deleted turn; when more people overlap than there are lines, the most recent
speakers are shown, in the order they spoke. **Show captions over the video**
(Settings and the More menu, on by default) hides them without stopping
transcription. `Sangam --layout-preview meeting` scripts a conversation
through the overlay for visual checks without a call, and
`--layout-preview chat` opens the chat over it with a short exchange in place.
On the Mac the captions are placed over the window, clear of the floating
panels; on iOS they belong to the split view's detail column, or they slide
under the participants column on an iPad.

## Document lifetime and editing

The document belongs to the window's ConversationSession, independently of the
meeting's media model. Hangup stops capture and leaves the document for review.
Window close, app quit, Done, and replacing a meeting through a link all use
the same save/discard/cancel gate — except for a self-started transcription
nobody has opened, edited or saved, which those paths let go silently. Opening
the sidebar, editing any field, or saving makes a document the user's, and it
is gated from then on. Hiding the sidebar does not discard anything.
Saving exports plain UTF-8 `.md`; new text after that save marks it edited again.
The macOS titlebar's edited dot and the sidebar's unsaved indicator agree.

An internal ConversationDocument stores stable utterance IDs, audio time ranges,
original recognition, and optional user overrides. Recognition replaces time
ranges; it does not append every partial result. Completed turns stay editable
while new words arrive. Gray provisional text becomes editable when finalized
or after transcription stops: Apple may split or combine provisional ranges,
so accepting edits before then could lose or duplicate a correction. Corrections
and deletions to completed turns remain protected. The native text view protects structural headings and
speaker labels, applies incremental text changes, anchors selection by field,
preserves scroll position, and uses semantic undo so recognition cannot erase
a user's edit history. A click landing outside every field moves to the
nearest one: an empty field is a single position wide, so the blank line under
the Notes heading looks like somewhere to write and otherwise refuses every
keystroke. Only clicks are redirected — arrowing out of a field is deliberate,
and pulling the caret back would trap it. Automated updates wait during IME composition.

Documents and original recognition are memory-only until the user saves. Audio
uses bounded transient buffers and is not recorded to disk. This deliberately
does not provide crash or force-quit recovery. Discard removes the unsaved
document and cancels generation; it does not delete an already exported file.

## Audio path

```
Jitsi RTP source -> WebRTC remote track -> native per-track audio sink
  -> bounded PCM ring -> per-source SpeechAnalyzer -> timestamped turns
Apple voice-processed microphone capture (gated by call mute)
  -> separate SpeechAnalyzer -> local participant turns
finalized, corrected turns -> Foundation Models -> title/summary/actions
```

The pinned Jitsi WebRTC binary does not publicly expose PCM in its Objective-C
API. JitsiAudioBridge uses WebRTC's nativeAudioTrack accessor and the actual M124
C++ headers, with no hard-coded vtable offsets. Its audio callback only copies
into a fixed ring. Polling, allocation, format conversion, and inference happen
outside the callback. See the bridge README for header provenance. A real
WebRTC receiver test verifies attachment, idempotent detach, and attribution
after Jitsi remaps an audio SSRC. Revalidate the bridge when upgrading WebRTC.

Audio source maps now update ownership even for an existing receive slot. Each
ownership epoch gets a fresh recognition session. M124 does not expose packet
source metadata at its decoded-audio callback; a conservative one-second gap
at a known reassignment reduces the risk of assigning the transition to the new speaker.
Exact attribution at those boundaries still needs real-call verification.
For controlled deployments, the existing `SANGAM_SSRC_REWRITING=0` diagnostic
option permits comparison against stable per-source forwarding.

The local WebRTC source's AddSink is a no-op. The Mac implementation therefore
uses a separate AVAudioEngine input tap with Apple voice processing, respecting
call mute. It leaves outgoing WebRTC capture unchanged. Test this with speakers,
headsets, Voice Isolation and Bluetooth: the independent microphone path can
behave differently from WebRTC's outgoing echo cancellation.

Capture buffers are narrowed to their first channel before recognition. Voice
processing presents its output as a discrete multi-channel stream — seven
channels carrying the same processed audio on the development Mac — and
AVAudioConverter has no downmix for a discrete layout: it accepts the
conversion to the recognizer's mono format, returns the right number of
frames, and fills every one of them with silence. That silently cost the local
speaker their whole transcript, which was most visible alone in a room, where
the microphone is the only source. `--microphone-check` reports the capture
format, per-channel levels, and how much of a known signal survives the
conversion, so a dead capture is distinguishable from a dead recognizer. Shared room
microphones identify the room endpoint, not individual people in that room.

Only audio actually forwarded by the bridge can be transcribed. A conservative
limit of eight remote recognizers plus the local recognizer bounds resource use;
the sidebar reports when more streams cannot be transcribed. Lost buffers,
unsupported locales, model failures and source transitions appear as status
messages. Unfinalized text remains editable and exports with `[unfinished]`.

## Summarization

The on-device SystemLanguageModel is selected explicitly; there is no cloud
fallback. Small source chunks leave context room for instructions, schema and
output, including on OS 26's smaller model. Source-derived chunk summaries are
cached by content hash. Historical corrections invalidate the corresponding
cache. An overview hierarchy is rebuilt from those chunks, rather than growing
a session indefinitely. Actions remain a separate ledger with supporting source
quotations, so shortening an overview cannot silently remove earlier actions.
The summary revises itself on a thirty-second timer for as long as the
document exists — while speech arrives and afterwards while it is corrected —
so there is nothing to press. A tick whose revision has already been
summarized returns immediately, and one generation is in flight at a time.
Summaries can apply while new speech arrives, but corrections to their source
turns or speaker identities invalidate them. This keeps continuous speech from
indefinitely preventing summary updates. Edits also schedule a refresh after
hangup. Editing the generated title or summary makes that section user-owned.

The model classifies candidates as commitments, proposals, requests or other
before rewriting them; only commitments with source evidence become actions.
This is generated text: even that classification and a supporting quotation do
not prove an action was interpreted correctly. Users should review owners,
dates and decisions.
An unavailable model or a guardrail refusal leaves the last valid summary and
the full transcript intact.

## Verification

Run `make test-ci`, `make mac`, and `make ios` for native tests and platform
builds. The unit tests cover time ordering, partial-result replacement, user
corrections/deletions, participant retention, save races and stale summaries.

Debug builds provide five local validation routes without joining a meeting:

- `Sangam --conversation-preview` opens an editable fixture.
- `Sangam --layout-preview meeting` runs a scripted conversation through the
  caption overlay.
- `Sangam --microphone-check [seconds]` opens the microphone the way a call
  does and reports counts and levels, never what was said: input format and
  per-channel peaks with voice processing off and on, the format recognition
  wants, how much of a known signal survives conversion into it, and how many
  words came back. Run it from the built binary rather than `open`, so its
  output reaches the terminal. It exits non-zero when nothing was recognized.
- `Sangam --conversation-audio-preview /path/alex.aiff /path/sam.aiff` runs two
  generated speech files through the real conversion, Speech and summary paths.
  These fixtures do not open the microphone.
- `Sangam --conversation-self-test /path/alex.aiff /path/sam.aiff` prints the
  resulting Markdown and exits successfully only if there are at least four
  finalized turns, a populated summary, no speech errors, and a proposal-only
  example that produces no assigned action. It also requires an action for
  both Alex and Sam. Use two generated files with two sentences and one explicit
  commitment each. This exercises actual on-device models and
  catches timestamp/finalization errors that document-only tests cannot catch.

The development fixtures are reproducible with macOS `say`:

```sh
say -r 160 -o /tmp/alex.aiff 'We have not approved the launch date. I will send the revised schedule tomorrow.'
say -r 160 -o /tmp/sam.aiff 'I will check the dependency list this afternoon. The launch date is still undecided.'
```

Validation on the development Mac produced all four named turns from overlapping
generated streams and preserved the negative launch decision in the summary.
Audio time is represented by exact sample fractions: independently rounded
floating-point buffer boundaries can make Speech reject a stream as overlapping.
The save/cancel/discard paths and editing/undo were also exercised in the app.

Before release, exercise actual Jitsi calls with overlapping speech, source
remaps, joins/leaves, reconnects, mute/moderation, Bluetooth changes, long calls
and a busy eight-speaker session.
