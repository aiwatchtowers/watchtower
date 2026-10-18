import Foundation
import os

/// The wait between two passes of a hub CLI runner (the git refresher and
/// both session report runners; board #842, owner decision ask #337: on the
/// event, else once per 15–30 s). `signal()` — a session state change, a
/// phone request — ends the wait at once; a signal sent while no wait runs
/// (during a pass) ends the next wait at once, so no event is lost. With no
/// signal a wait lasts its full duration, and a cancelled task's wait ends.
final class HubRunnerWake: Sendable {
    typealias Sleep = @Sendable (Duration) async -> Void

    private struct State {
        /// A signal no wait has taken yet.
        var signalled = false
        /// The wait in progress, if any.
        var activeID: Int?
        /// The active wait ended before it parked (its timer, a signal or a
        /// cancel came first).
        var endedEarly = false
        var waiter: CheckedContinuation<Void, Never>?
        var nextID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sleep: Sleep

    /// - Parameter sleep: the timed part of a wait (a test clock in tests).
    init(sleep: @escaping Sleep = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Ends the wait in progress, or the next one.
    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard state.activeID != nil else {
                state.signalled = true
                return nil
            }
            return Self.end(&state)
        }
        waiter?.resume()
    }

    /// Returns on a signal, after `duration`, or when the task is cancelled.
    func wait(upTo duration: Duration) async {
        let id = state.withLock { state -> Int? in
            if state.signalled {
                state.signalled = false
                return nil
            }
            state.nextID += 1
            state.activeID = state.nextID
            state.endedEarly = false
            return state.nextID
        }
        guard let id else { return }
        let sleep = self.sleep
        let timer = Task { [weak self] in
            await sleep(duration)
            self?.end(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = state.withLock { state -> Bool in
                    guard state.activeID == id, !state.endedEarly else {
                        if state.activeID == id { state.activeID = nil }
                        return false
                    }
                    state.waiter = continuation
                    return true
                }
                if !parked { continuation.resume() }
            }
        } onCancel: {
            end(id)
        }
        timer.cancel()
    }

    /// How long a runner waits after a pass: until `due` (a deferred
    /// request's earliest run; past means at once), never longer than
    /// `idle`; `idle` with nothing deferred.
    static func duration(
        until due: ContinuousClock.Instant?, now: ContinuousClock.Instant, idle: Duration
    ) -> Duration {
        guard let due else { return idle }
        return min(max(due - now, .zero), idle)
    }

    private func end(_ id: Int) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard state.activeID == id else { return nil }
            return Self.end(&state)
        }
        waiter?.resume()
    }

    /// Ends the active wait: takes its parked continuation, or marks it
    /// ended for the park still to come.
    private static func end(_ state: inout State) -> CheckedContinuation<Void, Never>? {
        guard let waiter = state.waiter else {
            state.endedEarly = true
            return nil
        }
        state.waiter = nil
        state.activeID = nil
        return waiter
    }
}
