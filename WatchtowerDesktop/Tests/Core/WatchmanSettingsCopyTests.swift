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
                       ["Category", "Agreement", "Bad while sure", "Rating"])
        XCTAssertEqual([Copy.strong, Copy.weak, Copy.notMeasured], ["Strong", "Weak", "Not measured"])
        XCTAssertEqual([Copy.runBacktest, Copy.runningButton], ["Run Backtest Now", "Running…"])
        XCTAssertTrue(Copy.neverRun.hasPrefix("Watchman hasn't checked itself yet."))
        XCTAssertTrue(Copy.busy.hasPrefix("A backtest is already running"))
        XCTAssertEqual(Copy.categories,
                       ["design", "scope", "ux_text", "tests", "review_code", "review_doc", "permission", "finish"])
    }

    /// The bar of spec §9 (ask #1423): at most 5 % bad, none bad while sure;
    /// under 30 decisions not measured.
    func testBarNoteNamesTheBars() {
        XCTAssertEqual(Copy.barNote, "Strong: 5 % or less of its decisions bad (ones you would have had to undo) "
            + "and none bad while sure; a different but reasonable decision does not count against it. "
            + "Below that Watchman marks every night decision unsure. "
            + "Under 30 decisions, or fewer than 20 left after the ones handed to you: not measured.")
    }

    func testEstimateAndLearningLines() throws {
        XCTAssertEqual(Copy.estimateLine(WatchmanEstimate(decisions: 1850, needLabels: 1, tokens: 1_600_000)),
                       "~1 850 decisions · est. 1.6 M tokens")
        XCTAssertEqual(Copy.estimateLine(WatchmanEstimate(decisions: 620, needLabels: 1, tokens: 500_000)),
                       "~620 decisions · est. 500 k tokens")
        XCTAssertEqual(Copy.tokens(12_400), "12 k")
        XCTAssertEqual(Copy.tokens(50_000), "50 k")
        XCTAssertEqual(Copy.tokens(1_750), "2 k")
        XCTAssertEqual(Copy.tokens(999_700), "1.0 M")
        XCTAssertEqual(Copy.tokens(2_340_000), "2.3 M")
        XCTAssertEqual(Copy.tokens(900), "900")
        XCTAssertEqual(Copy.estimateUnavailable, "Couldn't count its decisions in time (a large repository).")
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
        XCTAssertEqual(rows.map { Copy.baseRate($0) },
                       ["base rate 50 %", "base rate 50 %", "base rate 50 %", "base rate 50 %", "base rate 50 %",
                        "base rate 50 %", "base rate 50 %", nil])
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
        // An old row without the key decodes with a base rate of 0.
        XCTAssertEqual(Copy.baseRate(sparseRows[6]), "base rate 0 %")
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
        XCTAssertEqual(Copy.refreshFailed("exit code 1"),
                       "Couldn't refresh Watchman's status: exit code 1. Showing the last one read.")
        XCTAssertEqual(Copy.learnFailed("x"),
                       "Learning stopped: x. Watchman stays on; the daemon continues in its next cycles.")
    }

    func testHandedCopy() throws {
        XCTAssertEqual(Copy.handedHeader, "Handed")
        XCTAssertEqual(Copy.notMeasuredHanded(handed: 12), "Not measured: 12 of 30 handed to you")
        XCTAssertEqual(Copy.relabelling(left: 340), "Sorting earlier decisions: 340 left · the backtest runs after it")
        let status = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.results)
        let rows = Copy.tableRows(try XCTUnwrap(status.workbenches[0].lastDone))
        XCTAssertEqual(Copy.handedCell(rows[0]), "—")
        XCTAssertEqual(Copy.handedCell(rows[7]), "18")
        XCTAssertEqual(Copy.handedNote(rows[7]), "Not measured: 18 of 30 handed to you")
        XCTAssertNil(Copy.handedNote(rows[0]))
        // Not measured without handoffs has no note.
        let plain = WatchmanBacktestCategory(category: "finish", total: 0, agree: 0, wrongHigh: 0, costUSD: 0,
                                             status: "not_measured")
        XCTAssertNil(Copy.handedNote(plain))
    }

    // MARK: - Editing (phase 2)

    func testEditingCopy() {
        XCTAssertEqual([Copy.edit, Copy.unpin, Copy.save, Copy.cancel, Copy.remove, Copy.add],
                       ["Edit", "Unpin", "Save", "Cancel", "Remove", "Add"])
        XCTAssertEqual(Copy.bullet, "•")
        XCTAssertEqual(Copy.saveFailed("x"), "Couldn't save: x")
        XCTAssertEqual(Copy.unpinFailed("x"), "Couldn't unpin: x")
        XCTAssertEqual(Copy.addFailed("x"), "Couldn't add the limit: x")
        XCTAssertEqual(Copy.removeFailed("x"), "Couldn't remove the limit: x")
    }

    func testSleepEditCopy() {
        XCTAssertEqual(Copy.sleepPlaceholder, "00:30-07:45")
        XCTAssertEqual(Copy.sleepPinnedNote, "Saving pins the window: the weekly recompute leaves it until you unpin it.")
        XCTAssertEqual(Copy.sleepBadFormat, "Write the window as HH:MM-HH:MM on a 24-hour clock, e.g. 00:30-07:45.")
    }

    func testProfileCopy() {
        XCTAssertEqual(Copy.profileTitle, "What Watchman learned")
        XCTAssertEqual(Copy.profileTitle(name: "acme-web", several: true), "What Watchman learned · acme-web")
        XCTAssertEqual(Copy.profileTitle(name: "acme-web", several: false), "What Watchman learned")
        XCTAssertEqual(Copy.profileCaption, "Your rules per category, distilled weekly from your decisions. "
            + "An edit pins the text until you unpin it.")
        XCTAssertEqual(Copy.profileEmpty, "No rules yet: a category needs at least 5 learned decisions. "
            + "They are rebuilt weekly.")
        XCTAssertEqual(Copy.profilePinned, "Pinned by you")
        XCTAssertEqual(Copy.profilePinnedNote, "Saving pins this text: the weekly rebuild leaves it until you unpin it.")
        XCTAssertEqual(Copy.profileEmptyText, "Write at least one rule line.")
        XCTAssertEqual(Copy.profileTooLong(lines: 23), "At most 20 lines; this text has 23.")
        XCTAssertEqual(Copy.profileReadFailed("x"), "Couldn't read what Watchman learned: x")
        XCTAssertEqual(Copy.profileLearned("2026-11-14T03:00:00Z", timeZone: .gmt), "Learned 14 Nov")
        XCTAssertEqual(Copy.profileLearned("", timeZone: .gmt), "Learned")
    }

    func testLimitsCopy() {
        XCTAssertEqual(Copy.limitsTitle, "Your hard limits")
        XCTAssertEqual(Copy.limitsCaption, "Watchman parks these for you in every mode. "
            + "The built-in ones can't be removed; you can add your own.")
        XCTAssertEqual(Copy.addLimit, "Add a Limit…")
        XCTAssertEqual(Copy.limitKindTitle, "Kind")
        XCTAssertEqual(Copy.limitEmptyPattern, "Write the command's first words or the tool's name.")
        XCTAssertEqual(Copy.limitOneLine, "The pattern must be one line.")
        XCTAssertEqual(Copy.limitToolBlanks, "A tool name has no spaces.")
        XCTAssertEqual(Copy.limitsReadFailed("x"), "Couldn't read the limits: x")
        XCTAssertEqual(WatchmanLimitKind.allCases.map(Copy.limitKind), ["Command", "Tool"])
        XCTAssertEqual(WatchmanLimitKind.allCases.map(Copy.limitPlaceholder), ["terraform apply", "create_jira_issue"])
        XCTAssertEqual(WatchmanLimitKind.allCases.map(Copy.limitHint), [
            "Parks every shell command that starts with these words.",
            "Parks the tool of this name, also as an MCP tool."
        ])
    }

    /// Every built-in row the CLI lists has its own line; a name a newer CLI
    /// adds shows as it is.
    func testEveryBuiltinLimitHasALine() {
        XCTAssertEqual(WatchmanStatusFixtures.builtinLimits.map(Copy.builtinLimit), [
            "A command that cannot be read",
            "A plumbing push (git send-pack)",
            "Push to or merge into the default branch",
            "Create, delete or push a tag",
            "A GitHub release",
            "An App Store Connect or TestFlight upload",
            "A forced push",
            "A forced move of a shared branch",
            "Delete outside the session's worktrees",
            "A message or comment other people see",
            "Change the agent's own permission settings",
            "Edit a file outside the workbench folder and its worktrees"
        ])
        XCTAssertEqual(Copy.builtinLimit("new_row"), "new_row")
    }

    /// The built-in rows on one line, the full list in its tooltip.
    func testBuiltinSummaryLine() {
        let names = WatchmanStatusFixtures.builtinLimits
        XCTAssertEqual(Copy.builtinSummary(names), "Built in: A command that cannot be read, "
            + "A plumbing push (git send-pack), Push to or merge into the default branch, "
            + "Create, delete or push a tag… (12)")
        XCTAssertEqual(Copy.builtinSummary(["tag", "release"]), "Built in: Create, delete or push a tag, A GitHub release (2)")
        XCTAssertEqual(Copy.builtinHelp(names).split(separator: "\n").count, 12)
        XCTAssertTrue(Copy.builtinHelp(names).hasSuffix("Edit a file outside the workbench folder and its worktrees"))
    }

    func testRemoveConfirmationNamesThePattern() {
        XCTAssertEqual(Copy.removeConfirmTitle("terraform apply"), "Remove the limit “terraform apply”?")
        XCTAssertEqual(Copy.removeConfirmMessage, "Watchman may then take this action for you while it holds a session.")
        XCTAssertEqual(Copy.profileLoading, "Reading what Watchman learned…")
    }
}
