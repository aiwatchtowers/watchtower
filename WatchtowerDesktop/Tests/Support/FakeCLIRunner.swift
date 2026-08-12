import Foundation
import WatchtowerCore

/// Shared test double for `CLIRunnerProtocol`. Accumulates every invocation
/// so assertions can cover sequences of calls, not just the latest.
///
/// `@unchecked Sendable`: `run(args:)` is a nonisolated protocol requirement
/// invoked off whatever executor happens to run it, while `blockUntilCancelled`
/// is armed from the test's MainActor context beforehand — `lock` is what
/// actually protects the mutable cancellation-gate state below; the
/// plain-`var` config flags are set once before any concurrent access starts.
package final class FakeCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let stdoutData: Data
    package var shouldThrow: Error?
    /// When true, `run` suspends until the awaiting Task is cancelled, then
    /// throws `CancellationError` — models a long extraction the user
    /// cancels. Deterministic: driven by `withTaskCancellationHandler` off a
    /// stored continuation (the `OneShotGate` idiom in
    /// MeetingRecorderQueueTests.swift), NOT `Task.sleep` — a CI flake
    /// showed `Task.sleep(nanoseconds: .max)`'s own cancellation-check
    /// latency is not a reliable enough race-free primitive for this.
    package var blockUntilCancelled = false
    /// When true (only meaningful alongside `blockUntilCancelled`), a
    /// cancellation resumes `run` normally instead of throwing, and it
    /// returns `stdoutData` as if the CLI simply finished — models the CLI
    /// completing at almost the same moment Cancel is pressed, so a caller
    /// can be tested against "cancelled AND the runner still handed back
    /// data" rather than only "cancelled AND the runner threw".
    package var returnDataOnCancelInsteadOfThrowing = false
    package private(set) var invocations: [[String]] = []

    private let lock = NSLock()
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var cancelled = false

    package init(stdout: Data = Data(), error: Error? = nil) {
        self.stdoutData = stdout
        self.shouldThrow = error
    }

    package func run(args: [String]) async throws -> Data {
        invocations.append(args)
        if blockUntilCancelled {
            await waitForCancellation()
            if !returnDataOnCancelInsteadOfThrowing {
                throw CancellationError()
            }
        }
        if let shouldThrow { throw shouldThrow }
        return stdoutData
    }

    /// Suspends until this instance is told a cancellation happened (via the
    /// enclosing Task's cancellation handler), with no dependency on timer
    /// latency: the handler always resumes the waiter, whether it fires
    /// before or after `cancelWaiter` is stored.
    private func waitForCancellation() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    cancelWaiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let waiting = cancelWaiter
            cancelWaiter = nil
            lock.unlock()
            waiting?.resume()
        }
    }
}
