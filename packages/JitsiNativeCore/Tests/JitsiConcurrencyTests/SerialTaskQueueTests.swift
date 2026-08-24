import Testing

@testable import JitsiConcurrency

/// Records how many operations were inside the queue at once. `begin` and `end`
/// bracket the body of a queued operation, so `maximumConcurrent` is the whole
/// point of the type under test.
private actor OverlapProbe {
  private(set) var maximumConcurrent = 0
  private(set) var completed: [Int] = []
  private var active = 0

  func begin() {
    active += 1
    maximumConcurrent = max(maximumConcurrent, active)
  }

  func end(_ id: Int) {
    active -= 1
    completed.append(id)
  }
}

private enum ProbeError: Error, Equatable {
  case expected
}

@Test
func runsOneOperationAtATimeUnderContention() async {
  let queue = SerialTaskQueue()
  let probe = OverlapProbe()

  await withTaskGroup(of: Void.self) { group in
    for id in 0..<12 {
      group.addTask {
        try? await queue.run {
          await probe.begin()
          // Suspend repeatedly: an actor would release its executor here and
          // let a second operation interleave.
          for _ in 0..<8 { await Task.yield() }
          await probe.end(id)
        }
      }
    }
  }

  #expect(await probe.maximumConcurrent == 1)
  #expect(await probe.completed.count == 12)
}

@Test
func operationSeesEveryEarlierMutation() async throws {
  let queue = SerialTaskQueue()
  let counter = Counter()

  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<50 {
      group.addTask {
        try? await queue.run {
          let observed = await counter.value
          await Task.yield()
          await counter.set(observed + 1)
        }
      }
    }
  }

  // Without serialization this read-modify-write loses updates.
  #expect(await counter.value == 50)
}

@Test
func returnsOperationResult() async throws {
  let queue = SerialTaskQueue()
  let value = try await queue.run { "answer-sdp" }
  #expect(value == "answer-sdp")
}

@Test
func propagatesOperationFailureToItsCallerOnly() async throws {
  let queue = SerialTaskQueue()

  await #expect(throws: ProbeError.expected) {
    try await queue.run { throw ProbeError.expected }
  }

  // A failed operation must not wedge the queue for everything behind it.
  #expect(try await queue.run { 7 } == 7)
}

@Test
func drainWaitsForSubmittedOperations() async throws {
  let queue = SerialTaskQueue()
  let counter = Counter()

  let submitted = Task {
    try? await queue.run {
      for _ in 0..<10 { await Task.yield() }
      await counter.set(1)
    }
  }
  await submitted.value
  await queue.drain()

  #expect(await counter.value == 1)
}

private actor Counter {
  private(set) var value = 0

  func set(_ newValue: Int) {
    value = newValue
  }
}
