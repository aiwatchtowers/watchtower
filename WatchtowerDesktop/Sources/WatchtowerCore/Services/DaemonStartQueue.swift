import Foundation
import Observation

/// The one queue every daemon start, stop-then-start and restart the app
/// makes runs on: items run one after the other, so two never overlap (an
/// overlap reads as a failed start, or leaves two daemons). Each item has
/// `itemTimeout`: a hung CLI call fails visibly (`failure`) and the queue
/// moves on, the item left running in the background. `failure` is what the
/// app-wide daemon banner shows. An item must never enqueue onto its own
/// queue and await it (it would wait for itself until the timeout).
@MainActor
@Observable
package final class DaemonStartQueue {
    package static let shared = DaemonStartQueue()

    /// A start or restart's failure, for the banner; nil = nothing to say.
    package var failure: String?
    @ObservationIgnored package var itemTimeout: Duration
    /// The last item enqueued, finished or not; awaiting it waits for the queue.
    @ObservationIgnored package private(set) var tail: Task<Void, Never>?

    package init(itemTimeout: Duration = .seconds(90)) {
        self.itemTimeout = itemTimeout
    }

    package static let timedOutText = "Starting or restarting the background sync did not finish in time."

    /// Runs `operation` after every earlier item; nil when it hit the timeout.
    @discardableResult
    package func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> Task<T?, Never> {
        let previous = tail
        let timeout = itemTimeout
        let task = Task { @MainActor [weak self] () -> T? in
            await previous?.value
            let value = await Self.run(operation, timeout: timeout)
            if value == nil { self?.failure = Self.timedOutText }
            return value
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// `operation` or nil after `timeout`, whichever comes first; a late
    /// operation keeps running, unobserved.
    private static func run<T: Sendable>(
        _ operation: @escaping @MainActor () async -> T, timeout: Duration
    ) async -> T? {
        let gate = ResumeOnce<T>()
        return await withCheckedContinuation { continuation in
            gate.continuation = continuation
            let timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume(nil)
            }
            Task { @MainActor in
                let value = await operation()
                timer.cancel()
                gate.resume(value)
            }
        }
    }
}

@MainActor
private final class ResumeOnce<T: Sendable> {
    var continuation: CheckedContinuation<T?, Never>?

    func resume(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

extension DaemonManager {
    /// `restart()` on the shared queue; a timeout throws `.timedOut`.
    package static func restartQueued() async throws {
        let result = await DaemonStartQueue.shared.enqueue { () -> Result<Void, any Error> in
            do {
                try await restart()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        try (result ?? .failure(DaemonRestartError.timedOut)).get()
    }

    /// The background restart after an account or grant change, on the
    /// shared queue: a failure is logged and shown on the daemon banner.
    package static func restartLoggingQueued() async {
        do {
            try await restartQueued()
        } catch {
            NSLog("DaemonManager: restart failed: %@", error.localizedDescription)
            DaemonStartQueue.shared.failure = "The background sync did not restart: \(error.localizedDescription)"
        }
    }
}
