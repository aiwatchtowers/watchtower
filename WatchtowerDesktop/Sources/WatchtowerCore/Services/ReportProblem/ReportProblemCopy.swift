import Foundation

/// Every string of the Report a Problem sheet and its entry points, pinned by
/// `ReportProblemCopyTests` to the spec's "UI strings" table
/// (docs/superpowers/specs/2026-11-04-report-a-problem-design.md).
package enum ReportProblemCopy {
    /// Why `watchtower diagnostics` gave no answer.
    package enum FailureReason: Equatable, Sendable {
        case timedOut
        case missing
        case exit(Int32)
        case unreadable

        var text: String {
            switch self {
            case .timedOut: "the watchtower command did not answer in 10 seconds"
            case .missing: "the watchtower command is missing"
            case .exit(let code): "the watchtower command failed (exit \(code))"
            case .unreadable: "its answer could not be read"
            }
        }
    }

    package static let menu = "Report a Problem…"
    package static let title = "Report a Problem"
    package static let intro = "Tell us what went wrong. Watchtower sends nothing itself: "
        + "you review everything below and submit it on GitHub yourself."
    package static let corpIntro = "This is your organization's build. Save the diagnostics to a file to share them."

    package static let fieldLabel = "What happened?"
    package static let fieldPlaceholder = "What you did, what you expected, what you saw instead."
    package static let corpFieldPlaceholder = "Steps to reproduce, what you expected, and what happened instead."
    package static let fieldRequired = "Describe the problem to continue."

    package static let blockTitle = "Diagnostics that will be included"
    package static let blockCaption =
        "Kinds, counts, states and error classes only — no names, ids, message text or log lines."
    package static let loading = "Collecting diagnostics…"
    package static let retry = "Retry"

    package static func failed(_ reason: FailureReason) -> String {
        "Could not collect diagnostics: \(reason.text). The report will carry the app and macOS versions only."
    }

    package static let publicNote = "GitHub issues are public. Check the text before you submit."
    package static let discussionsLink = "A question, not a problem? Ask in Discussions"

    package static let cancel = "Cancel"
    package static let done = "Done"
    package static let saveDiagnostics = "Save Diagnostics…"
    package static let openIssue = "Open GitHub Issue"
    package static let copyReport = "Copy Report"
    package static let copyLink = "Copy Link"
    /// Settings → System → Logs: the existing button and the new one beside it.
    package static let openLogs = "Open Logs"
    package static let settingsEntry = menu

    package static let opened =
        "Opened in your browser. Finish the issue there; this window keeps your text until you press Done."
    package static let tooLong = "The report did not fit in the link. Copy it and paste it into Logs on GitHub."
    package static let reportCopied = "Report copied."
    package static let linkCopied = "Link copied."

    package static let browserFailed = "Could not open your browser. Copy the link and paste it into a browser."

    package static func saveFailed(_ reason: String) -> String {
        "Could not save the file: \(reason)"
    }

    /// Put into the link's `logs` field when the report does not fit.
    package static let logsPlaceholder = "Paste the report from Watchtower here."
    /// Ends a user text cut to fit the link.
    package static let truncatedSuffix = "… (full text in the pasted report)"
}
