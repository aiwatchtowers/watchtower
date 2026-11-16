import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Every string of Settings → Profile → Watchman (spec §10, §11).
final class WatchmanSettingsCopyTests: XCTestCase {
    private typealias Copy = WatchmanSettingsCopy

    func testFixedStrings() {
        XCTAssertEqual(Copy.sectionTitle, "Watchman")
        XCTAssertEqual(Copy.workbenchesTitle, "Workbenches")
        XCTAssertEqual(Copy.notLearnedIntro, "Watchman hasn't learned any workbench yet. It reads your past decisions "
            + "on a workbench before it can answer for you there; nothing acts until you hand it a session.")
        XCTAssertTrue(Copy.moreWorkbenchesIntro.hasSuffix("nothing acts until you hand it a session."))
        XCTAssertEqual(Copy.startLearning, "Start Learning")
        XCTAssertEqual(Copy.retry, "Retry")
        XCTAssertEqual(Copy.sleepTitle, "Sleep window")
        XCTAssertEqual(Copy.sleepCaption, "Learned from when you stop and start working on workbenches. Recomputed weekly.")
        XCTAssertEqual([Copy.sleepLearned, Copy.sleepPinned], ["Learned", "Pinned by you"])
        XCTAssertEqual(Copy.sleepNotLearned, "Not learned yet: Watchman needs a week of your activity.")
        XCTAssertEqual(Copy.backtestTitle, "Backtest")
        XCTAssertEqual([Copy.columnCategory, Copy.columnAgreement, Copy.columnWrongHigh, Copy.columnRating],
                       ["Category", "Agreement", "Wrong while sure", "Rating"])
        XCTAssertEqual([Copy.strong, Copy.weak, Copy.notMeasured], ["Strong", "Weak", "Not measured"])
        XCTAssertEqual([Copy.runBacktest, Copy.runningButton], ["Run Backtest Now", "Running…"])
        XCTAssertTrue(Copy.neverRun.hasPrefix("Watchman hasn't checked itself yet."))
        XCTAssertTrue(Copy.busy.hasPrefix("A backtest is already running"))
        XCTAssertEqual(Copy.categories,
                       ["design", "scope", "ux_text", "tests", "review_code", "review_doc", "permission", "finish"])
    }

    /// The bars of spec §8.2: 80 % / 5 %, under 30 decisions not measured.
    func testBarNoteNamesTheBars() {
        XCTAssertEqual(Copy.barNote, "Strong: 80 % agreement or more and 5 % or less wrong while sure. "
            + "Below that Watchman marks every night decision unsure. Under 30 decisions: not measured.")
    }

    func testEstimateAndLearningLines() throws {
        XCTAssertEqual(Copy.estimateLine(WatchmanEstimate(decisions: 1850, needLabels: 1, tokens: 1_600_000)),
                       "~1 850 decisions · est. 1.6 M tokens")
        XCTAssertEqual(Copy.estimateLine(WatchmanEstimate(decisions: 620, needLabels: 1, tokens: 500_000)),
                       "~620 decisions · est. 0.5 M tokens")
        XCTAssertEqual(Copy.tokens(12_400), "12 k")
        XCTAssertEqual(Copy.tokens(900), "900")
        XCTAssertEqual(Copy.count(1_234_567), "1 234 567")

        let learning = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.learning)
        XCTAssertEqual(Copy.learningLine(learning.workbenches[0]), "Learning… 340 of 1 850")
        // Not on yet (Start Learning just pressed): 0 of the estimate.
        XCTAssertEqual(Copy.learningLine(learning.workbenches[1]), "Learning… 0 of 620")
        // Written is capped at the estimate while learning is not done.
        let over = try WatchmanStatusFixtures.decode(
            WatchmanStatusFixtures.learning.replacingOccurrences(of: #""written": 340"#, with: #""written": 2000"#))
        XCTAssertEqual(Copy.learningLine(over.workbenches[0]), "Learning… 1 850 of 1 850")
    }

    func testTableRowsInOrderWithNotMeasuredWording() throws {
        let status = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.results)
        let backtest = try XCTUnwrap(status.workbenches[0].lastDone)
        let rows = Copy.tableRows(backtest)
        XCTAssertEqual(rows.map(\.category), Copy.categories)
        XCTAssertEqual(rows.map { Copy.agreement($0) }, ["83 %", "80 %", "60 %", "87 %", "80 %", "83 %", "97 %", "—"])
        XCTAssertEqual(rows.map { Copy.wrongHigh($0) }, ["3 %", "3 %", "10 %", "0 %", "7 %", "3 %", "0 %", "—"])
        XCTAssertEqual(rows.map { Copy.rating($0) }.last, "Not measured")
        XCTAssertEqual(Copy.rating(rows[2]), "Weak")
        XCTAssertEqual(Copy.rating(rows[0]), "Strong")

        // A category the run did not report shows as not measured.
        let sparse = try WatchmanStatusFixtures.decode(#"""
        {"ok": true, "workbenches": [{"workbench": 1, "name": "acme", "enabled_at": "2026-11-02T09:00:00Z",
          "analytics_on": true, "running": false, "last_done": {"id": 1, "status": "done", "cost_usd": 0,
          "categories": [{"category": "permission", "total": 30, "agree": 26, "wrong_high": 1,
                          "status": "strong", "cost_usd": 0.75}]}}]}
        """#)
        let sparseRows = Copy.tableRows(try XCTUnwrap(sparse.workbenches[0].lastDone))
        XCTAssertEqual(sparseRows.count, 8)
        XCTAssertEqual(sparseRows.filter { Copy.rating($0) == "Not measured" }.count, 7)
    }

    func testBacktestLines() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let status = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.results)
        let done = try XCTUnwrap(status.workbenches[0].lastDone)
        XCTAssertEqual(Copy.lastRunCaption(done, timeZone: utc), "Last run 15 Nov, 03:12 · your latest 30 decisions "
            + "per category, hidden and decided again by Watchman.")
        XCTAssertEqual(Copy.lastResults(done, timeZone: utc), "Last results, 15 Nov")
        XCTAssertEqual(Copy.runningLine("ux_text, 18 of 30 · 3 of 8 categories done"),
                       "Backtest running · ux_text, 18 of 30 · 3 of 8 categories done")
        XCTAssertEqual(Copy.runningLine(""), "Backtest running · starting")
        XCTAssertEqual(try XCTUnwrap(Copy.progressFraction("ux_text, 18 of 30 · 3 of 8 categories done")),
                       (3 + 18.0 / 30) / 8, accuracy: 0.0001)
        XCTAssertNil(Copy.progressFraction("permission 12 of 30"))
        XCTAssertEqual(Copy.failedLine("the AI provider hit your plan limit", hasResults: true),
                       "The backtest stopped: the AI provider hit your plan limit. Nothing changed; the last results stay.")
        XCTAssertEqual(Copy.failedLine("interrupted", hasResults: false),
                       "The backtest stopped: it was interrupted. Nothing changed.")
        XCTAssertEqual(Copy.analyticsOffNote(name: "acme-web"),
                       "Agent analytics is off on acme-web, so your typed corrections there are not used.")
        XCTAssertEqual(Copy.sleepValue("00:30-07:45"), "00:30–07:45")
        XCTAssertNil(Copy.sleepValue(""))
        XCTAssertEqual(Copy.backtestTitle(name: "acme-api", several: true), "Backtest · acme-api")
        XCTAssertEqual(Copy.backtestTitle(name: "acme-api", several: false), "Backtest")
        XCTAssertEqual(Copy.readFailed("exit code 1"), "Couldn't read Watchman's status: exit code 1")
        XCTAssertEqual(Copy.learnFailed("x"),
                       "Learning stopped: x. Watchman stays on; the daemon continues in its next cycles.")
    }
}
