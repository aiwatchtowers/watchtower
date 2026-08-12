import Foundation
import WatchtowerCore

/// Error-classification helpers for `TargetExtractCenter`, split into their own
/// file so the center's phase/lifecycle logic isn't crowded by string matching.
extension TargetExtractCenter {
    static func rawText(for error: Error) -> String {
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
