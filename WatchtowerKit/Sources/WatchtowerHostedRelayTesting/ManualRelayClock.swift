import Foundation
import os
import WatchtowerHostedRelay

/// Virtual time for the relay client's tests: `now()` moves only through
/// `advance(by:)`, and a `sleep` resumes once the clock reaches its deadline
/// (or throws `CancellationError` when its task is cancelled).
public final class ManualRelayClock: RelayClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    public func now() -> Date {
        state.withLock { $0.now }
    }

    /// The sleeps waiting for the clock to move.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Moves the clock and resumes every sleep whose deadline it reached.
    public func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.addingTimeInterval(Self.seconds(duration))
            let now = state.now
            let ready = state.sleepers.filter { $0.value.deadline <= now }
            for id in ready.keys { state.sleepers[id] = nil }
            return ready.sorted { $0.value.deadline < $1.value.deadline }.map(\.value)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Suspends until at least `count` sleeps are waiting, so a test can
    /// advance the clock knowing the code under test is asleep.
    public func waitForSleepers(_ count: Int) async {
        while sleeperCount < count {
            await Task.yield()
        }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id: Int = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = state.withLock { state in
                    let deadline = state.now.addingTimeInterval(Self.seconds(duration))
                    if deadline <= state.now { return true }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow { return continuation.resume() }
                // A cancel that ran before the sleeper was registered found nothing to resume.
                if Task.isCancelled, let missed = state.withLock({ $0.sleepers.removeValue(forKey: id) }) {
                    missed.continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let cancelled = state.withLock { $0.sleepers.removeValue(forKey: id) }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
