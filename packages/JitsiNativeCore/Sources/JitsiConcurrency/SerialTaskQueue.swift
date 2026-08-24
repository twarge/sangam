import Foundation

/// Runs submitted operations one at a time, in submission order.
///
/// Actor isolation alone does not provide this. An actor guarantees that no two
/// of its methods run *simultaneously*, but it releases its executor at every
/// `await`, so a method that suspends part-way through a multi-step sequence
/// lets another call into the same actor start and interleave with it. That is
/// fatal for stateful protocols such as WebRTC's offer/answer exchange, where a
/// second `setRemoteDescription` arriving between the first one and its
/// `createAnswer` corrupts the session.
///
/// An operation submitted here observes and mutates shared state without any
/// other queued operation running in between, because each submission awaits
/// its predecessor before it begins.
///
/// Operations are run in unstructured tasks, so cancelling the caller does not
/// cancel work that has already started. That is deliberate: abandoning a
/// half-applied SDP negotiation is worse than letting it finish.
public actor SerialTaskQueue {
  private var tail: Task<Void, Never>?

  public init() {}

  /// Submits `operation` and returns its result once every previously
  /// submitted operation has finished.
  ///
  /// A failing operation does not break the queue; the next one still runs.
  @discardableResult
  public func run<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let predecessor = tail
    let operationTask = Task {
      await predecessor?.value
      return try await operation()
    }
    tail = Task { _ = try? await operationTask.value }
    return try await operationTask.value
  }

  /// Waits for every operation submitted so far to finish.
  public func drain() async {
    await tail?.value
  }
}
