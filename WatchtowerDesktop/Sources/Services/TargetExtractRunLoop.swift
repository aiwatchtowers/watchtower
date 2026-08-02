import Foundation

/// The actual CLI-driving run loop for `TargetExtractCenter`, split out of
/// `TargetExtractLifecycle.swift` — combined with start/cancel/retry/dismiss
/// this method's `TargetExtractService`/notification/error-mapping calls
/// re-tripped the god-file gate on that file alone.
extension TargetExtractCenter {
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
