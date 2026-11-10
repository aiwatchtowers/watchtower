import XCTest
@testable import WatchtowerCore

/// Every Report a Problem string, pinned to the spec's "UI strings" table
/// (docs/superpowers/specs/2026-11-04-report-a-problem-design.md).
final class ReportProblemCopyTests: XCTestCase {
    func testStringsArePinned() {
        typealias Copy = ReportProblemCopy
        XCTAssertEqual(Copy.menu, "Report a Problem…")
        XCTAssertEqual(Copy.title, "Report a Problem")
        XCTAssertEqual(
            Copy.intro,
            "Tell us what went wrong. Watchtower sends nothing itself: you review everything below "
                + "and submit it on GitHub yourself."
        )
        XCTAssertEqual(Copy.corpIntro, "This is your organization's build. Save the diagnostics to a file to share them.")
        XCTAssertEqual(Copy.fieldLabel, "What happened?")
        XCTAssertEqual(Copy.fieldPlaceholder, "What you did, what you expected, what you saw instead.")
        XCTAssertEqual(Copy.corpFieldPlaceholder, "Steps to reproduce, what you expected, and what happened instead.")
        XCTAssertEqual(Copy.fieldRequired, "Describe the problem to continue.")
        XCTAssertEqual(Copy.blockTitle, "Diagnostics that will be included")
        XCTAssertEqual(
            Copy.blockCaption,
            "Kinds, counts, states and error classes only — no names, ids, message text or log lines."
        )
        XCTAssertEqual(Copy.loading, "Collecting diagnostics…")
        XCTAssertEqual(Copy.retry, "Retry")
        XCTAssertEqual(Copy.publicNote, "GitHub issues are public. Check the text before you submit.")
        XCTAssertEqual(Copy.discussionsLink, "A question, not a problem? Ask in Discussions")
        XCTAssertEqual(Copy.cancel, "Cancel")
        XCTAssertEqual(Copy.done, "Done")
        XCTAssertEqual(Copy.saveDiagnostics, "Save Diagnostics…")
        XCTAssertEqual(Copy.openIssue, "Open GitHub Issue")
        XCTAssertEqual(Copy.copyReport, "Copy Report")
        XCTAssertEqual(Copy.copyLink, "Copy Link")
        XCTAssertEqual(Copy.openLogs, "Open Logs")
        XCTAssertEqual(Copy.settingsEntry, "Report a Problem…")
        XCTAssertEqual(
            Copy.opened,
            "Opened in your browser. Finish the issue there; this window keeps your text until you press Done."
        )
        XCTAssertEqual(Copy.tooLong, "The report did not fit in the link. Copy it and paste it into Logs on GitHub.")
        XCTAssertEqual(Copy.reportCopied, "Report copied.")
        XCTAssertEqual(Copy.linkCopied, "Link copied.")
        XCTAssertEqual(Copy.browserFailed, "Could not open your browser. Copy the link and paste it into a browser.")
        XCTAssertEqual(Copy.saveFailed("Disk full."), "Could not save the file: Disk full.")
        XCTAssertEqual(Copy.logsPlaceholder, "Paste the report from Watchtower here.")
        XCTAssertEqual(Copy.truncatedSuffix, "… (full text in the pasted report)")
    }

    func testFailureReasonsArePinned() {
        let tail = ". The report will carry the app and macOS versions only."
        XCTAssertEqual(
            ReportProblemCopy.failed(.timedOut),
            "Could not collect diagnostics: the watchtower command did not answer in 10 seconds" + tail
        )
        XCTAssertEqual(
            ReportProblemCopy.failed(.missing),
            "Could not collect diagnostics: the watchtower command is missing" + tail
        )
        XCTAssertEqual(
            ReportProblemCopy.failed(.exit(3)),
            "Could not collect diagnostics: the watchtower command failed (exit 3)" + tail
        )
        XCTAssertEqual(
            ReportProblemCopy.failed(.unreadable),
            "Could not collect diagnostics: its answer could not be read" + tail
        )
    }
}
