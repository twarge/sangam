import Testing

@testable import JitsiNativeCore

@Test
func tapWhileMutedUnmutesForGood() {
  var key = PushToTalkKey()
  #expect(key.keyDown(muted: true, at: 10) == false)
  #expect(key.keyUp(muted: false, at: 10.1) == nil)
  #expect(!key.isPressed)
}

@Test
func tapWhileUnmutedMutesForGood() {
  var key = PushToTalkKey()
  #expect(key.keyDown(muted: false, at: 10) == true)
  #expect(key.keyUp(muted: true, at: 10.1) == nil)
}

@Test
func holdWhileMutedTalksUntilRelease() {
  var key = PushToTalkKey()
  #expect(key.keyDown(muted: true, at: 10) == false)
  #expect(key.keyUp(muted: false, at: 12) == true)
}

@Test
func holdWhileUnmutedMutesUntilRelease() {
  var key = PushToTalkKey()
  #expect(key.keyDown(muted: false, at: 10) == true)
  #expect(key.keyUp(muted: true, at: 12) == false)
}

@Test
func thresholdItselfIsAHold() {
  var key = PushToTalkKey()
  _ = key.keyDown(muted: true, at: 10)
  #expect(key.keyUp(muted: false, at: 10 + PushToTalkKey.holdThreshold) == true)
}

@Test
func secondKeyDownDuringAPressIsIgnored() {
  var key = PushToTalkKey()
  _ = key.keyDown(muted: true, at: 10)
  #expect(key.keyDown(muted: false, at: 10.5) == nil)
  // The hold is still timed from the first key-down.
  #expect(key.keyUp(muted: false, at: 11) == true)
}

@Test
func keyUpWithoutAPressDoesNothing() {
  var key = PushToTalkKey()
  #expect(key.keyUp(muted: true, at: 10) == nil)
  #expect(key.cancel(muted: true) == nil)
}

@Test
func cancelledPressPutsTheMicrophoneBack() {
  var key = PushToTalkKey()
  _ = key.keyDown(muted: true, at: 10)
  // Focus left before the key came up, however briefly it was held.
  #expect(key.cancel(muted: false) == true)
  #expect(!key.isPressed)
}

@Test
func holdLeavesAMicrophoneSomethingElseRestored() {
  var key = PushToTalkKey()
  _ = key.keyDown(muted: true, at: 10)
  // The meeting refused the unmute, or the button was clicked mid-hold.
  #expect(key.keyUp(muted: true, at: 12) == nil)
}
