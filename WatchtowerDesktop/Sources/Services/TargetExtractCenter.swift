import Foundation

/// App-wide, single-slot registry for the "Extract with AI" target-extraction
/// call. The extraction subprocess call can take up to the CLI's extract
/// timeout; routing it through this AppState-held center (instead of
/// view-local `@State` on `CreateTargetSheet`) means the result is never lost
/// if the presenting sheet is closed before the call finishes — `start()`'s
/// `Task` is rooted here, not in the view.
@MainActor
@Observable
final class TargetExtractCenter {
    /// True while a `start()` call is in flight. Only one extraction can run
    /// at a time app-wide; a second `start()` call while this is true is a
    /// no-op (single-slot guard).
    var isRunning = false
    /// The text of the in-flight (or most recently started) extraction, so a
    /// caller can tell whether a running extraction is its own or someone
    /// else's.
    var draftText = ""
    /// Set on successful, non-empty extraction. Cleared by `clearPending()`
    /// once a consumer has presented it.
    var pendingResult: TargetExtractResult?
    /// Set on CLI failure or an empty extraction result. Cleared by
    /// `clearPending()` once a consumer has surfaced it.
    var pendingError: String?

    private let notificationService: NotificationService

    init(notificationService: NotificationService = .shared) {
        self.notificationService = notificationService
    }

    /// Runs the extraction. Guards against overlapping calls (single-slot);
    /// a call made while one is already running returns immediately without
    /// touching `draftText`/`pendingResult`/`pendingError`.
    func start(text: String, sourceRef: String = "", runner: CLIRunnerProtocol) async {
        guard !isRunning else { return }
        isRunning = true
        draftText = text
        pendingResult = nil
        pendingError = nil

        do {
            let result = try await TargetExtractService(runner: runner)
                .extract(text: text, sourceRef: sourceRef)
            if result.extracted.isEmpty {
                pendingError = "AI returned no extracted targets"
                notificationService.sendTargetExtractFailedNotification(reason: pendingError!)
            } else {
                pendingResult = result
                notificationService.sendTargetExtractReadyNotification(count: result.extracted.count)
            }
        } catch {
            pendingError = "Extract failed: \(error.localizedDescription)"
            notificationService.sendTargetExtractFailedNotification(reason: pendingError!)
        }

        isRunning = false
    }

    /// Clears any pending result/error once a consumer has presented it.
    func clearPending() {
        pendingResult = nil
        pendingError = nil
    }
}
