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
/// call. `start()` is a plain `async` method with no internal `Task` of its
/// own — it is awaited directly from the button action's `Task { }` in
/// `CreateTargetSheet`. That caller-side `Task` is NOT tied to the sheet's
/// lifecycle (only the `.task { }` SwiftUI modifier is auto-cancelled on
/// view teardown; an imperatively-created `Task { }` inside a button action
/// is not), so it keeps running and mutating this AppState-held center's
/// state even after the presenting sheet is dismissed — that is what lets
/// the result survive the sheet being closed mid-extraction.
@MainActor
@Observable
final class TargetExtractCenter {
    /// True while a `start()` call is in flight. Only one extraction can run
    /// at a time app-wide; a second `start()` call while this is true is a
    /// no-op (single-slot guard).
    var isRunning = false
    /// The text of the in-flight (or most recently started) extraction.
    /// Not read by any production consumer today — `CreateTargetSheet` uses
    /// its own local ownership flag instead — but exercised by
    /// `TargetExtractCenterTests` to assert the single-slot guard leaves it
    /// untouched when a call is blocked.
    var draftText = ""
    /// Set on successful, non-empty extraction. Cleared by `clearPending()`
    /// once a consumer has presented it.
    var pendingResult: TargetExtractResult?
    /// Set on CLI failure or an empty extraction result. Cleared by
    /// `clearPending()` once a consumer has surfaced it.
    var pendingError: String?

    private let notificationService: TargetExtractNotifying

    init(notificationService: TargetExtractNotifying = NotificationService.shared) {
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
                let message = "AI returned no extracted targets"
                pendingError = message
                notificationService.sendTargetExtractFailedNotification(reason: message)
            } else {
                pendingResult = result
                notificationService.sendTargetExtractReadyNotification(count: result.extracted.count)
            }
        } catch {
            let message = "Extract failed: \(error.localizedDescription)"
            pendingError = message
            notificationService.sendTargetExtractFailedNotification(reason: message)
        }

        isRunning = false
    }

    /// Clears any pending result/error once a consumer has presented it.
    func clearPending() {
        pendingResult = nil
        pendingError = nil
    }
}
