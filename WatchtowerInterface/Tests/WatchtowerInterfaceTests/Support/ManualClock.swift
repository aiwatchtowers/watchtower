import Foundation

/// A clock whose time moves only when a test calls `advance(by:)`, so
/// timing tests never wait on wall-clock time. A sleeper whose deadline the
/// advance reaches is resumed (earliest first); a cancelled sleeper is
/// dropped at once. `waitForSleepers` lets a test wait until the code under
/// test has gone back to sleep before it moves time again.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
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
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    /// How many tasks sleep on this clock now.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
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
    func advance(by duration: Duration) {
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
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if sleepers.count == count {
                lock.unlock()
                continuation.resume()
                return
            }
            countWaiters.append((count, continuation))
            lock.unlock()
        }
    }

    /// Removes and returns the waiters whose count is met (lock held).
    private func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
        let met = countWaiters.filter { $0.count == sleepers.count }
        countWaiters.removeAll { $0.count == sleepers.count }
        return met.map(\.continuation)
    }
}
