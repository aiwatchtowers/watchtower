import Foundation

/// Abstraction over the two target-extraction completion notifications, so
/// `TargetExtractCenter` can be unit-tested without touching the real
/// `UNUserNotificationCenter` (which has no app-bundle context under
/// `swift test` and crashes if invoked there).
protocol TargetExtractNotifying {
    func sendTargetExtractReadyNotification(count: Int)
    func sendTargetExtractFailedNotification(reason: String)
}

extension NotificationService: TargetExtractNotifying {}

/// App-wide, single-slot registry for the "Extract with AI" target-extraction
/// call. It owns its own cancellable `Task`, so the extraction — and its result
/// — survives the presenting `CreateTargetSheet` being dismissed and any
/// navigation away (the "начал → ушёл → вернулся" contract shared with
/// `MeetingRecorderCenter`). The global `ExtractIndicatorView` capsule reflects
/// `phase` from every screen; there is no wall-clock timeout — the only early
/// stop is `cancel()`, which terminates the CLI subprocess.
@MainActor
@Observable
final class TargetExtractCenter {
    enum Phase: Equatable {
        case idle
        case extracting
        case ready(count: Int)
        case empty
        case failed(message: String, canRetry: Bool)
    }

    private(set) var phase: Phase = .idle
    /// The extracted proposal, set alongside `.ready`. Read by the capsule /
    /// sheet to present `ExtractPreviewSheet`; cleared by `dismiss()`.
    private(set) var result: TargetExtractResult?
    /// Raw CLI stderr behind the friendly `.failed` message, surfaced under the
    /// capsule's "Show details" disclosure. Nil unless the last run failed.
    private(set) var lastRawError: String?

    /// The in-flight extraction. Internal (not private) so tests can await it.
    var task: Task<Void, Never>?

    // Remembered inputs so `retry()` can re-run the same call.
    private var lastText = ""
    private var lastSourceRef = ""
    private var lastRunner: CLIRunnerProtocol?

    private let notificationService: TargetExtractNotifying

    init(notificationService: TargetExtractNotifying = NotificationService.shared) {
        self.notificationService = notificationService
    }

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
        // Also cancel defensively: if ever called while a run is still in
        // flight, an un-cancelled task could later overwrite a newer phase.
        task?.cancel()
        task = nil
        phase = .idle
        result = nil
    }

    private func run(text: String, sourceRef: String, runner: CLIRunnerProtocol) async {
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

    private static func rawText(for error: Error) -> String {
        if let cliError = error as? CLIRunnerError { return cliError.errorDescription ?? "\(error)" }
        return error.localizedDescription
    }

    /// Maps a raw CLI failure into a human-readable message + whether Retry
    /// makes sense. Never surfaces the raw Go error chain directly (that lives
    /// behind the capsule's "Show details").
    static func friendlyMessage(for raw: String) -> (text: String, canRetry: Bool) {
        let lower = raw.lowercased()
        if lower.contains("deadline exceeded") || lower.contains("timed out") || lower.contains("timeout") {
            return ("Extraction took too long. Try again.", true)
        }
        if lower.contains("install claude code") || (lower.contains("claude") && lower.contains("not found")) {
            return ("Claude Code isn't installed. Install it and try again.", false)
        }
        if lower.contains("not found") {
            return ("Watchtower CLI not found in PATH.", false)
        }
        if lower.contains("network") || lower.contains("connection") || lower.contains("unreachable") {
            return ("Network issue — check your connection and retry.", true)
        }
        if lower.contains("overloaded") || lower.contains("rate limit") {
            return ("AI is busy right now. Try again in a moment.", true)
        }
        return ("Couldn't extract targets. Try again.", true)
    }
}
