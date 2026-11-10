import XCTest
@testable import WatchtowerCore

/// Every string of the closed asks list (#1713 spec, "Model and strings"),
/// pinned one by one so a change is a deliberate one.
final class ClosedAskListCopyTests: XCTestCase {
    private typealias Copy = ClosedAskListCopy

    func testFixedStrings() {
        XCTAssertEqual(Copy.title, "Closed asks")
        XCTAssertEqual(Copy.scopeOutside, "Filed outside the app")
        XCTAssertEqual(Copy.scopeAutomations, "Automation runs")
        XCTAssertEqual(Copy.searchPlaceholder, "Search titles, answers, #number")
        XCTAssertEqual(Copy.loading, "Loading closed asks…")
        XCTAssertEqual(Copy.empty, "No closed asks here yet.")
        XCTAssertEqual(Copy.emptyHint, "Asks you answer, and asks the agent withdraws, are kept here.")
        XCTAssertEqual(Copy.askGone, "That ask no longer exists. The list was read again.")
        XCTAssertEqual(Copy.retry, "Retry")
        XCTAssertEqual(Copy.clearSearch, "Clear Search")
        XCTAssertEqual(Copy.back, "Closed asks")
        XCTAssertEqual(Copy.backHelp, "Back to the closed asks (Esc)")
        XCTAssertEqual(Copy.busyHelp, "Refreshing…")
        XCTAssertEqual(Copy.buttonHelp, "Show the closed asks")
        XCTAssertEqual(Copy.today, "Today")
        XCTAssertEqual(Copy.yesterday, "Yesterday")
        XCTAssertEqual(Copy.unknownDate, "Unknown date")
        XCTAssertEqual(Copy.approved, "Approved")
        XCTAssertEqual(Copy.changesRequested, "Changes requested")
        XCTAssertEqual(Copy.withdrawnByAgent, "withdrawn by the agent")
        XCTAssertEqual(Copy.replacedByNewer, "replaced by a newer ask")
    }

    func testChipWords() {
        XCTAssertEqual(ClosedAskListModel.Chip.answered.text, "Answered")
        XCTAssertEqual(ClosedAskListModel.Chip.delivered.text, "Delivered")
        XCTAssertEqual(ClosedAskListModel.Chip.withdrawn.text, "Withdrawn")
        XCTAssertEqual(ClosedAskListModel.Chip.replaced.text, "Replaced")
        XCTAssertEqual(ClosedAskListModel.Chip.dismissed.text, "Dismissed")
    }

    func testBuiltStrings() {
        XCTAssertEqual(Copy.entryLabel(81), "▸ 81 closed")
        XCTAssertEqual(Copy.scopeSession("Fix the login redirect"), "Session · Fix the login redirect")
        XCTAssertEqual(Copy.loadFailed("the database is busy"), "Could not load the closed asks: the database is busy")
        XCTAssertEqual(Copy.refreshFailed("the database is busy", readAt: "14:32"),
                       "Could not refresh the list: the database is busy. It shows what was read at 14:32.")
        XCTAssertEqual(Copy.openFailed("disk I/O error"), "Could not open the ask: disk I/O error")
        XCTAssertEqual(Copy.noMatch("postgres"), "No closed asks match “postgres”.")
        XCTAssertEqual(Copy.matches(4, of: 84), "4 of 84")
        XCTAssertEqual(Copy.comments(1), "1 comment")
        XCTAssertEqual(Copy.comments(3), "3 comments")
        XCTAssertEqual(Copy.replacedBy(406), "replaced by #406")
    }

    func testTrailingPeriodOfAReasonIsNotDoubled() {
        XCTAssertEqual(Copy.refreshFailed("disk I/O error.", readAt: "09:05"),
                       "Could not refresh the list: disk I/O error. It shows what was read at 09:05.")
    }
}
