import Foundation

/// `TargetExtractCenter`'s lifecycle: starting/cancelling/retrying/dismissing
/// an extraction. Split into its own file so `TargetExtractCenter.swift`
/// stays a thin state/init shell; the CLI-driving run loop itself lives in
/// `TargetExtractRunLoop.swift` (also split out — combined with these four
/// methods it re-tripped the god-file gate on its own).
extension TargetExtractCenter {
    /// Starts an extraction in the background. No-op while one is already
    /// running (single-slot guard) — the runner is not even invoked.
    func start(text: String, sourceRef: String = "", runner: CLIRunnerProtocol) {
        guard phase != .extracting else { return }
        lastText = text
        lastSourceRef = sourceRef
        lastRunner = runner
        result = nil
        lastRawError = nil
        phase = .extracting
        task = Task { [weak self] in
            await self?.run(text: text, sourceRef: sourceRef, runner: runner)
        }
    }

    /// Cancels the in-flight extraction (terminating the CLI subprocess via
    /// `ProcessCLIRunner`'s cancellation handler) and returns to idle.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        result = nil
    }

    /// Re-runs the last failed extraction with the remembered text + runner.
    func retry() {
        guard case .failed = phase, let runner = lastRunner else { return }
        start(text: lastText, sourceRef: lastSourceRef, runner: runner)
    }

    /// Clears a terminal state (`.ready`/`.empty`/`.failed`) back to idle —
    /// called once a consumer has presented the result or the user dismisses
    /// the capsule. Also cancels defensively: if ever called while a run is
    /// still in flight, an un-cancelled task could later overwrite a newer
    /// phase.
    func dismiss() {
        task?.cancel()
        task = nil
        phase = .idle
        result = nil
    }
}
