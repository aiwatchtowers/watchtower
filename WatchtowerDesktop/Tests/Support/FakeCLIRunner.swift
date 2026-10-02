import Foundation
import WatchtowerCore

/// Shared test double for `CLIRunnerProtocol`. Accumulates every invocation
/// so assertions can cover sequences of calls, not just the latest.
///
/// `@unchecked Sendable`: `run(args:)` is a nonisolated protocol requirement
/// invoked off whatever executor happens to run it, while `blockUntilCancelled`
/// is armed from the test's MainActor context beforehand — `lock` is what
/// actually protects the recorded invocations and the mutable
/// cancellation-gate state below (a test's `waitUntil` polls `invocations`
/// from the main actor while `run` appends from another executor); the
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
    /// Every call's arguments, in order. A locked snapshot — safe to read
    /// while `run` is still being called concurrently.
    package var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    /// What each `--text-file` held when its call ran (`nil` when the file
    /// was unreadable) — the file is gone once the call returns.
    package var textFileContents: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTextFiles
    }

    private let lock = NSLock()
    private var recordedInvocations: [[String]] = []
    private var recordedTextFiles: [String?] = []
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var cancelled = false

    package init(stdout: Data = Data(), error: Error? = nil) {
        self.stdoutData = stdout
        self.shouldThrow = error
    }

    package func run(args: [String]) async throws -> Data {
        record(args)
        if blockUntilCancelled {
            await waitForCancellation()
            if !returnDataOnCancelInsteadOfThrowing {
                throw CancellationError()
            }
        }
        if let shouldThrow { throw shouldThrow }
        return stdoutData
    }

    private func record(_ args: [String]) {
        var textFile: String??
        if let flag = args.firstIndex(of: "--text-file"), args.indices.contains(flag + 1) {
            textFile = .some(try? String(contentsOfFile: args[flag + 1], encoding: .utf8))
        }
        lock.lock()
        recordedInvocations.append(args)
        if let textFile { recordedTextFiles.append(textFile) }
        lock.unlock()
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
