import Foundation

/// App-wide, single-slot registry for the "Extract with AI" target-extraction
/// call. It owns its own cancellable `Task`, so the extraction — and its result
/// — survives the presenting `CreateTargetSheet` being dismissed and any
/// navigation away (the "начал → ушёл → вернулся" contract shared with
/// `MeetingRecorderCenter`). The global `ExtractIndicatorView` capsule reflects
/// `phase` from every screen; there is no wall-clock timeout — the only early
/// stop is `cancel()`, which terminates the CLI subprocess.
///
/// The lifecycle methods (`start`/`cancel`/`retry`/`dismiss`/`run`) live in
/// `TargetExtractLifecycle.swift` and the CLI-error classification in
/// `TargetExtractErrorMapping.swift` — this file holds only the type's shape
/// (state + init) so it stays under the structural god-file fan-out gate.
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

    // `phase`/`result`/`lastRawError` are mutated from
    // `TargetExtractLifecycle.swift`'s methods, so they can't be
    // `private(set)` (Swift's `private` doesn't cross files) — the
    // module-internal setter is the cost of splitting the lifecycle out.
    var phase: Phase = .idle
    /// The extracted proposal, set alongside `.ready`. Read by the capsule /
    /// sheet to present `ExtractPreviewSheet`; cleared by `dismiss()`.
    var result: TargetExtractResult?
    /// Raw CLI stderr behind the friendly `.failed` message, surfaced under the
    /// capsule's "Show details" disclosure. Nil unless the last run failed.
    var lastRawError: String?

    /// The in-flight extraction. Internal (not private) so tests can await it.
    var task: Task<Void, Never>?

    // Remembered inputs so `retry()` can re-run the same call.
    var lastText = ""
    var lastSourceRef = ""
    var lastRunner: CLIRunnerProtocol?

    let notificationService: TargetExtractNotifying

    init(notificationService: TargetExtractNotifying = NotificationService.shared) {
        self.notificationService = notificationService
    }
}
