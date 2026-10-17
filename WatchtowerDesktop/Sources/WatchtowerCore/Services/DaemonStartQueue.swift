import Foundation
import Observation

/// The one queue every daemon start, stop-then-start and restart the app
/// makes runs on: items run one after the other, never overlapping (an
/// overlap reads as a failed start, or leaves two daemons). Items carry no
/// timeout of their own: every CLI call inside one is bounded where it runs
/// (`DaemonManager.cliCallTimeout`, the child stopped and reaped before the
/// call returns), and the pid waits have their own bounds, so an item always
/// ends. `failure` is what the app-wide daemon banner shows. An item must
/// never enqueue onto the queue and await it (it would wait for itself).
@MainActor
@Observable
package final class DaemonStartQueue {
    package static let shared = DaemonStartQueue()

    /// A start or restart's failure, for the banner; nil = nothing to say.
    /// Only a successful start or restart (or the owner's Dismiss) clears it.
    package var failure: String?
    /// The last item enqueued, finished or not; awaiting it waits for the queue.
    @ObservationIgnored package private(set) var tail: Task<Void, Never>?

    package init() {}

    /// Runs `operation` after every earlier item.
    @discardableResult
    package func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// `restart` as one item: a success clears `failure`, an error is thrown.
    package func restart(_ restart: @escaping @Sendable () async throws -> Void) async throws {
        let result = await enqueue { () -> Result<Void, any Error> in
            do {
                try await restart()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .success = result { failure = nil }
        try result.get()
    }

    /// The background restart after an account or grant change: a failure
    /// is logged and stays on the daemon banner.
    package func restartLogging(_ restart: @escaping @Sendable () async throws -> Void) async {
        do {
            try await self.restart(restart)
        } catch {
            NSLog("DaemonManager: restart failed: %@", error.localizedDescription)
            failure = "The background sync did not restart: \(error.localizedDescription)"
        }
    }
}

extension DaemonManager {
    /// `restart()` on the shared queue for code with no `AppState` at hand
    /// (account view models, Google sign-in), the failure logged and kept on
    /// the banner. `AppState` uses the same queue.
    package static func restartLoggingQueued() async {
        await DaemonStartQueue.shared.restartLogging { try await restart() }
    }
}
