import Foundation
import Observation

/// Waits until `condition` holds, re-checking it on every change of the observable state it reads
/// (`withObservationTracking`). No deadline: the wait ends on the event, never on a clock, and a wait that
/// never ends is a hang the lane watchdog reports. `condition` must read the `@Observable` state it waits
/// on; a condition that reads only plain state (a fake's counter, a row in the database) is never
/// re-checked — such a wait needs the fake's own signal instead.
@MainActor
public func untilObserved(_ condition: @escaping @MainActor () -> Bool) async {
    let once = ResumeOnce()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        once.continuation = continuation
        recheck(condition, once)
    }
}

@MainActor
private func recheck(_ condition: @escaping @MainActor () -> Bool, _ once: ResumeOnce) {
    guard once.continuation != nil else { return }
    let met = withObservationTracking(condition) {
        Task { @MainActor in recheck(condition, once) }
    }
    if met { once.resume() }
}

@MainActor
private final class ResumeOnce {
    var continuation: CheckedContinuation<Void, Never>?

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// Waits until `condition` holds, re-checking it once per main-actor turn (`Task.yield`): every job already
/// queued on the main actor runs between two checks. No clock and no deadline — a wait that never ends is a
/// hang the lane watchdog reports. The fallback for conditions over plain state nobody signals (a row in the
/// database, a file); prefer `untilObserved` for `@Observable` state and a fake's own signal
/// (`StateSignal`) for its counters.
@MainActor
public func untilTurn(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}

/// Lets a test wait for plain state a fake keeps under its own lock (a call count, a held call). The fake
/// calls `changed()` after every mutation, OUTSIDE its own lock; `until` checks the condition under the
/// signal's lock, so a change between the check and the registration is never missed. No clock.
public final class StateSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(condition: @Sendable () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    /// Returns once `condition` holds.
    public func until(_ condition: @escaping @Sendable () -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if condition() {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((condition, continuation))
                lock.unlock()
            }
        }
    }

    /// Re-checks every waiter; call after each change of the state they wait on.
    public func changed() {
        lock.lock()
        var met: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            guard waiter.condition() else { return false }
            met.append(waiter.continuation)
            return true
        }
        lock.unlock()
        met.forEach { $0.resume() }
    }
}
