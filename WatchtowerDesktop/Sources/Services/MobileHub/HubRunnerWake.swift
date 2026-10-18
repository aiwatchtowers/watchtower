import Foundation
import os

/// The wait between two passes of a hub CLI runner (the git refresher and
/// both session report runners; board #842, owner decision ask #337: on the
/// event, else once per 15–30 s). `signal()` — a session state change, a
/// phone request — ends the wait; a signal sent while no wait runs (during a
/// pass) ends the next wait, so no event is lost. A signalled wait still
/// lasts `minimumGap` from its start (the end of the last pass), so a burst
/// of events — a working agent's state stamp changes every second — costs
/// one pass per `minimumGap`, no more than the old 5 s poll, and an event is
/// never later than under that poll. With no signal a wait lasts its full
/// duration, and a cancelled task's wait ends.
///
/// One waiter at a time (one runner loop); a wait that finds another one
/// parked ends that one first, so a loop left over from a restart never
/// hangs.
final class HubRunnerWake: Sendable {
    typealias Sleep = @Sendable (Duration) async -> Void

    /// The least time from the end of a pass to the next one a signal
    /// starts: the old poll interval.
    static let standardMinimumGap: Duration = .seconds(5)

    private struct State {
        /// A signal no wait has taken yet.
        var signalled = false
        /// The wait in progress, if any.
        var activeID: Int?
        /// How the active wait ended before it parked; nil while it has not.
        var endedEarly: Ending?
        var waiter: CheckedContinuation<Bool, Never>?
        var nextID = 0
    }

    private enum Ending {
        /// Its timer or a cancel.
        case timedOut
        case signalled
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sleep: Sleep
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let minimumGap: Duration

    /// - Parameters:
    ///   - sleep: the timed part of a wait (a test clock in tests).
    ///   - clock: the time `minimumGap` is measured on.
    init(
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        minimumGap: Duration = standardMinimumGap
    ) {
        self.sleep = sleep
        self.clock = clock
        self.minimumGap = minimumGap
    }

    /// Ends the wait in progress, or the next one.
    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.activeID != nil else {
                state.signalled = true
                return nil
            }
            return Self.end(&state, bySignal: true)
        }
        waiter?.resume(returning: true)
    }

    /// Returns after `duration`, on a signal (but no sooner than
    /// `minimumGap` after the call, capped at `duration`), or when the task
    /// is cancelled.
    func wait(upTo duration: Duration) async {
        guard !Task.isCancelled, duration > .zero else { return }
        let started = clock()
        guard await timedWait(duration) else { return }
        let rest = min(minimumGap, duration) - (clock() - started)
        guard rest > .zero, !Task.isCancelled else { return }
        await sleep(rest)
        // The pass that follows covers every signal sent during the gap (its
        // caller wrote its state first), so none of them starts another. A
        // cancelled loop runs no pass, so it leaves them for the next one.
        guard !Task.isCancelled else { return }
        state.withLock { $0.signalled = false }
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

    /// The wait proper. - Returns: whether a signal ended it.
    private func timedWait(_ duration: Duration) async -> Bool {
        let (id, displaced) = state.withLock { state -> (Int?, CheckedContinuation<Bool, Never>?) in
            if state.signalled {
                state.signalled = false
                return (nil, nil)
            }
            // A wait that a signal ended before it parked: this wait takes
            // the signal over (that one then ends as timed out).
            if state.activeID != nil, state.endedEarly == .signalled {
                state.activeID = nil
                return (nil, nil)
            }
            // A second waiter (a loop left over from a restart): end the
            // parked one rather than lose its continuation.
            let displaced = state.waiter
            state.waiter = nil
            state.nextID += 1
            state.activeID = state.nextID
            state.endedEarly = nil
            return (state.nextID, displaced)
        }
        displaced?.resume(returning: false)
        guard let id else { return true }
        let sleep = self.sleep
        let timer = Task { [weak self] in
            await sleep(duration)
            self?.end(id)
        }
        let bySignal = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let early = state.withLock { state -> Ending? in
                    guard state.activeID == id else { return .timedOut }
                    if let early = state.endedEarly {
                        state.activeID = nil
                        return early
                    }
                    state.waiter = continuation
                    return nil
                }
                if let early { continuation.resume(returning: early == .signalled) }
            }
        } onCancel: {
            end(id)
        }
        timer.cancel()
        return bySignal
    }

    /// Ends wait `id` if it is still the active one (its timer, a cancel).
    private func end(_ id: Int) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.activeID == id else { return nil }
            return Self.end(&state, bySignal: false)
        }
        waiter?.resume(returning: false)
    }

    /// Ends the active wait: takes its parked continuation, or records how
    /// it ended for the park still to come.
    private static func end(_ state: inout State, bySignal: Bool) -> CheckedContinuation<Bool, Never>? {
        guard let waiter = state.waiter else {
            if state.endedEarly == nil { state.endedEarly = bySignal ? .signalled : .timedOut }
            return nil
        }
        state.waiter = nil
        state.activeID = nil
        return waiter
    }
}
