import Foundation

/// The tower client's clock in the Desktop's tests (a copy of the
/// WatchtowerInterface tests' `ManualClock`, which this target cannot see).
/// A clock whose time moves only when a test calls `advance(by:)`, so
/// timing tests never wait on wall-clock time. A sleeper whose deadline the
/// advance reaches is resumed (earliest first); a cancelled sleeper is
/// dropped at once. `waitForSleepers` lets a test wait until the code under
/// test has gone back to sleep before it moves time again.
package final class TowerTestClock: Clock, @unchecked Sendable {
    package struct Instant: InstantProtocol {
        package var offset: Duration

        package func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        package func duration(to other: Self) -> Duration { other.offset - offset }
        package static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var nextID = 0
    private var waiters: [(ready: ([Sleeper]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    package init() {}

    package var now: Instant { lock.withLock { current } }
    package var minimumResolution: Duration { .zero }

    /// How many tasks sleep on this clock now.
    package var sleeperCount: Int { lock.withLock { sleepers.count } }

    package func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                let ready = takeSatisfiedWaiters()
                lock.unlock()
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let (sleeper, ready) = lock.withLock { () -> (Sleeper?, [CheckedContinuation<Void, Never>]) in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return (nil, []) }
                let sleeper = sleepers.remove(at: index)
                return (sleeper, takeSatisfiedWaiters())
            }
            sleeper?.continuation.resume(throwing: CancellationError())
            ready.forEach { $0.resume() }
        }
    }

    /// Moves time forward and resumes every sleeper the new time reaches.
    package func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers
            .filter { $0.deadline <= current }
            .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        sleepers.removeAll { $0.deadline <= current }
        let ready = takeSatisfiedWaiters()
        lock.unlock()
        due.forEach { $0.continuation.resume() }
        ready.forEach { $0.resume() }
    }

    /// Returns once exactly `count` tasks sleep on this clock.
    package func waitForSleepers(_ count: Int) async {
        await waitUntil { $0.count == count }
    }

    /// Returns once a task sleeps until `offset` (the code under test went
    /// back to sleep until its next step).
    package func waitForSleeper(at offset: Duration) async {
        await waitUntil { $0.contains { $0.deadline.offset == offset } }
    }

    private func waitUntil(_ ready: @escaping ([Sleeper]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if ready(sleepers) {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((ready, continuation))
            lock.unlock()
        }
    }

    /// Removes and returns the waiters whose condition holds (lock held).
    private func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
        let met = waiters.filter { $0.ready(sleepers) }
        waiters.removeAll { $0.ready(sleepers) }
        return met.map(\.continuation)
    }
}
