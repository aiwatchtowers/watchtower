import Foundation

/// A load (a model, typically one that may download first) that runs in the
/// background and that a caller waits for only so long (board #564): a
/// caller past its wait gets nil and goes on without the value while the
/// load keeps running, and a later caller picks the value up once it is
/// there. One attempt at a time; a loaded value is kept.
///
/// A failed attempt is not remembered: its failure goes to every caller
/// waiting on that attempt at the moment it fails; with nobody waiting it is
/// handed to `onUnobservedFailure` (logged) then and there, never thrown at a
/// later caller. The load then goes idle and the next caller starts a new
/// attempt — at most one per `retryAfterFailure`, so a run that keeps asking
/// while the network is down does not hammer it. A cancelled caller stops
/// waiting at once (`CancellationError`); the attempt itself, shared by
/// every caller, is never cancelled by one of them.
actor BackgroundLoad<Value: Sendable> {
    private enum WaitOutcome {
        case loaded(Value)
        case failed(Error)
        case timedOut
        case cancelled
    }

    private struct Waiter {
        let continuation: CheckedContinuation<WaitOutcome, Never>
        var timer: Task<Void, Never>?
    }

    private let load: @Sendable () async throws -> Value
    private let retryAfterFailure: Duration
    private let onUnobservedFailure: @Sendable (Error) -> Void
    private var value: Value?
    private var attemptRunning = false
    private var lastFailure: ContinuousClock.Instant?
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiter = 0

    /// Callers waiting on the running attempt (tests).
    var waitingCallers: Int { waiters.count }

    init(
        retryAfterFailure: Duration = .seconds(60),
        onUnobservedFailure: @escaping @Sendable (Error) -> Void,
        _ load: @escaping @Sendable () async throws -> Value
    ) {
        self.retryAfterFailure = retryAfterFailure
        self.onUnobservedFailure = onUnobservedFailure
        self.load = load
    }

    /// The value, starting an attempt when none runs (and the last failure
    /// is old enough); nil when there is none after `wait` (`.zero` = only
    /// if already loaded, nil = until the attempt finishes). Throws the
    /// attempt's failure to the callers waiting on it, and
    /// `CancellationError` when the caller is cancelled.
    func value(waitingUpTo wait: Duration?) async throws -> Value? {
        if let value { return value }
        try Task.checkCancellation()
        if !attemptRunning {
            if let lastFailure, ContinuousClock.now - lastFailure < retryAfterFailure { return nil }
            start()
        }
        if wait == .zero { return nil }
        switch await waitForAttempt(upTo: wait) {
        case let .loaded(loaded): return loaded
        case let .failed(error): throw error
        case .timedOut: return nil
        case .cancelled: throw CancellationError()
        }
    }

    private func start() {
        attemptRunning = true
        Task {
            do {
                finish(.success(try await load()))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        attemptRunning = false
        let pending = waiters.values
        waiters.removeAll()
        switch result {
        case let .success(loaded):
            value = loaded
            pending.forEach { end($0, .loaded(loaded)) }
        case let .failure(error):
            lastFailure = .now
            if pending.isEmpty { onUnobservedFailure(error) }
            pending.forEach { end($0, .failed(error)) }
        }
    }

    private func waitForAttempt(upTo wait: Duration?) async -> WaitOutcome {
        let id = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                var waiter = Waiter(continuation: continuation)
                if let wait {
                    waiter.timer = Task {
                        do {
                            try await Task.sleep(for: wait)
                        } catch {
                            return // the wait ended first
                        }
                        stopWaiting(id, .timedOut)
                    }
                }
                waiters[id] = waiter
            }
        } onCancel: {
            Task { await self.stopWaiting(id, .cancelled) }
        }
    }

    private func stopWaiting(_ id: Int, _ outcome: WaitOutcome) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        end(waiter, outcome)
    }

    private func end(_ waiter: Waiter, _ outcome: WaitOutcome) {
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: outcome)
    }
}
