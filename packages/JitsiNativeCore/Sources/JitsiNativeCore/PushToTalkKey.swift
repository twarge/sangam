import Foundation

/// A key that works the microphone the way Zoom's space bar does, and then
/// some: held while muted, it lets you speak until you let go; a quick tap
/// mutes or unmutes for good. Held while unmuted it is the cough button,
/// muting only until you let go.
///
/// The microphone flips the moment the key goes down, whichever the press
/// turns out to be, so push-to-talk never clips the first syllable. Only the
/// release decides whether the flip stands: a press shorter than
/// `holdThreshold` is a tap and keeps it, a longer one is a hold and puts the
/// microphone back.
///
/// The threshold errs short. A tap taken for a hold only undoes itself, and
/// the next tap is quicker; a short hold taken for a tap would leave the
/// microphone open after you meant to stop talking.
public struct PushToTalkKey: Equatable, Sendable {
  /// The longest press that still counts as a tap, in seconds.
  public static let holdThreshold: TimeInterval = 0.3

  private struct Press: Equatable, Sendable {
    let wasMuted: Bool
    let time: TimeInterval
  }

  private var press: Press?

  public init() {}

  /// Whether a press is under way: its key-up, and any key repeats, are
  /// still to come.
  public var isPressed: Bool { press != nil }

  /// The key went down at `time` (seconds on any steady clock) with the
  /// microphone `muted`. Returns the muted state to set — always the
  /// opposite — or nil when a press is already under way.
  public mutating func keyDown(muted: Bool, at time: TimeInterval) -> Bool? {
    guard press == nil else { return nil }
    press = Press(wasMuted: muted, time: time)
    return !muted
  }

  /// The key came up at `time`. Returns the muted state to set, or nil to
  /// leave the microphone as it is: a tap keeps the press's flip, a hold
  /// undoes it.
  public mutating func keyUp(muted: Bool, at time: TimeInterval) -> Bool? {
    guard let press else { return nil }
    self.press = nil
    if time - press.time < Self.holdThreshold { return nil }
    return restoring(press, muted: muted)
  }

  /// The press ended with no key-up to see — focus went to another window
  /// or app, which gets the release instead. Taken as a hold, so a key held
  /// to talk never leaves the microphone open behind it.
  public mutating func cancel(muted: Bool) -> Bool? {
    guard let press else { return nil }
    self.press = nil
    return restoring(press, muted: muted)
  }

  /// Back to how the press found the microphone, unless it is already there:
  /// a click on the button mid-press, or an unmute the meeting refused, has
  /// put it back first.
  private func restoring(_ press: Press, muted: Bool) -> Bool? {
    muted == press.wasMuted ? nil : press.wasMuted
  }
}
