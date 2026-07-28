import Foundation

/// `TargetExtractCenter`'s lifecycle: starting/cancelling/retrying/dismissing
/// an extraction, and the CLI-driving run loop itself. Split into its own
/// file so `TargetExtractCenter.swift` stays a thin state/init shell.
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

    func run(text: String, sourceRef: String, runner: CLIRunnerProtocol) async {
        do {
            let extracted = try await TargetExtractService(runner: runner)
                .extract(text: text, sourceRef: sourceRef)
            if Task.isCancelled { return }
            if extracted.extracted.isEmpty {
                phase = .empty
                notificationService.sendTargetExtractFailedNotification(reason: "No targets found in this text")
            } else {
                result = extracted
                phase = .ready(count: extracted.extracted.count)
                notificationService.sendTargetExtractReadyNotification(count: extracted.extracted.count)
            }
        } catch is CancellationError {
            // Cancelled by the user: `cancel()` already reset phase to .idle.
            return
        } catch {
            if Task.isCancelled { return }
            let raw = Self.rawText(for: error)
            lastRawError = raw
            let friendly = Self.friendlyMessage(for: raw)
            phase = .failed(message: friendly.text, canRetry: friendly.canRetry)
            notificationService.sendTargetExtractFailedNotification(reason: friendly.text)
        }
    }
}
