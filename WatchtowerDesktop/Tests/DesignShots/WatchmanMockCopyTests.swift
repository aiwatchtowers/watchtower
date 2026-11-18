import WatchtowerCore
import XCTest

/// Pins the Watchman spec's string table
/// (`docs/superpowers/specs/2026-11-16-watchman-design.md` §2, §10, §11) so
/// the mockups and the spec text cannot drift. The implementation moves
/// these strings into the view models that own the screens and pins them
/// there.
@MainActor
final class WatchmanMockCopyTests: XCTestCase {
    typealias Copy = WatchmanMockCopy

    func testJournalCopy() {
        XCTAssertEqual(Copy.journalTitle, "Watchman")
        XCTAssertEqual(Copy.parkedReason, "Parked: merging to main is yours")
        XCTAssertTrue(Copy.handedReason.hasPrefix("Handed to you: "))
        XCTAssertTrue(Copy.unsure1Rationale.contains("#1201, #1288"))
        XCTAssertEqual(Copy.unsure1Meta, "confidence low · design · strong 84 %")
        XCTAssertEqual([Copy.ok, Copy.correct, Copy.openSession], ["OK", "Correct…", "Open session"])
        XCTAssertEqual(Copy.skippedLine, "Not run by you — Watchman continued")
        XCTAssertEqual(Copy.deciding, "Deciding: #1826 'Store window per workbench?' …")
        // 2 unsure cards + 4 sure lines + 8 more = the summary's 14 (12 sure).
        XCTAssertEqual(2 + Copy.sureRows.count + 8, 14)
    }

    /// Phase 2's two journal frames: the daemon line is the journal's own.
    func testPhase2JournalFrames() {
        XCTAssertEqual(Copy.daemonStopped, "Watchman is not running — the daemon is stopped")
        XCTAssertEqual(Copy.daemonStopped, WatchmanJournalCopy.daemonStopped)
        XCTAssertEqual(Copy.unsureBadge, WatchmanJournalCopy.unsureBadge)
        XCTAssertEqual(Copy.homeRow, WatchmanJournalCopy.homeRow(
            WatchmanNightCounts(start: Date(timeIntervalSince1970: 0), decided: 14, unsure: 2, waiting: 2)))
        let names = Set(WatchmanShotFixtures.shots.map(\.name))
        XCTAssertTrue(names.contains("watchman-journal-not-running"))
        XCTAssertTrue(names.contains("watchman-journal-night-unsure"))
    }

    /// Phase 2's arming frames render the real controls: the spec's copy is
    /// `WatchmanArmingCopy`'s. The sheet's confirm reads Hand to Watchman
    /// (not the mockup's Start), and the tray has no Going to sleep (D47).
    func testArmingFramesUseTheRealCopy() {
        typealias Real = WatchmanArmingCopy
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let since = AutomationDates.parse("2026-11-17T01:40:00Z")
        XCTAssertEqual(Copy.armedChip, Real.stripArmed(since: since, calendar: utc))
        XCTAssertEqual(Copy.targetArmed, Real.targetArmed(since: since, calendar: utc))
        XCTAssertEqual([Copy.handTo, Copy.takeBack, Copy.notNow], [Real.handTo, Real.takeBack, Real.notNow])
        XCTAssertEqual(Copy.armAnalytics, Real.analyticsLine)
        XCTAssertEqual(Copy.armHistory, Real.historyLine(WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000)))
        XCTAssertEqual(Copy.armLimits, Real.limitsLine)
        XCTAssertEqual(Copy.trayHandAll, Real.trayHandAll)
    }

    func testEmptyAndErrorStatesNameTheWayOut() {
        XCTAssertTrue(Copy.emptyHint.contains("Hand to Watchman"))
        XCTAssertTrue(Copy.readFailed.contains("nothing was lost"))
        XCTAssertEqual(Copy.retry, "Retry")
        XCTAssertEqual(Copy.correctQuestion, "What would you have decided?")
        XCTAssertTrue(Copy.correctSessionEnded.contains("a new session starts"))
    }

    func testHomeAndArmingCopy() {
        XCTAssertEqual(Copy.homeRow, "Overnight Watchman decided 14 — 2 unsure, 2 waiting for you")
        XCTAssertEqual(Copy.armedChip, "Watchman · Sleep since 01:40")
        XCTAssertEqual([Copy.takeBack, Copy.handTo], ["Take back", "Hand to Watchman"])
        XCTAssertEqual(Copy.armAnalytics, "Agent analytics turned on — Watchman learns from your sessions")
        XCTAssertEqual(Copy.armHistory, "Learning from your history: ~1 850 decisions, est. 1.6 M tokens")
        XCTAssertTrue(Copy.armNoProtection.contains("no branch protection"))
        XCTAssertEqual([Copy.start, Copy.notNow], ["Start", "Not now"])
    }

    func testTrayPanelAndInboxEntryCopy() {
        XCTAssertEqual(Copy.trayHandAll, "Hand all running sessions to Watchman")
        XCTAssertEqual(Copy.trayGoingToSleep, "Going to sleep")
        XCTAssertEqual(Copy.trayWatchmanStatus, "Watchman · Sleep · 3 sessions")
        XCTAssertEqual(Copy.targetArmed, "Watchman has this target · Sleep since 01:40")
        XCTAssertEqual(Copy.inboxWatchmanSummary, "2 waiting")
    }

    func testNotLearnedCopy() {
        XCTAssertEqual(Copy.notLearnedRows.first?.estimate, "~1 850 decisions · est. 1.6 M tokens")
        XCTAssertEqual(Copy.startLearning, "Start Learning")
        XCTAssertEqual(Copy.learningProgress, "Learning… 340 of 1 850")
    }

    func testSettingsCopyMatchesTheBars() {
        XCTAssertEqual(Copy.sleepValue, "00:30–07:45")
        XCTAssertTrue(Copy.barNote.contains("5 % or less of its decisions bad"))
        XCTAssertTrue(Copy.barNote.contains("none bad while sure"))
        // The eight v1 categories of spec §8.2, in order.
        XCTAssertEqual(Copy.backtestRows.map(\.category),
                       ["design", "scope", "ux_text", "tests", "review_code", "review_doc", "permission", "finish"])
        XCTAssertEqual(Copy.runBacktest, "Run Backtest Now")
        // D24: no night budget; the journal header shows the night's cost.
        XCTAssertEqual(Copy.nightCost, "Cost tonight $3.40")
    }

    /// Phase 2's Settings editing frames draw the real view on the
    /// status/profile/limits fixtures; their strings are pinned by
    /// `WatchmanSettingsCopyTests`.
    func testSettingsEditingFrames() {
        let names = Set(WatchmanShotFixtures.shots.map(\.name))
        for name in ["watchman-settings-results", "watchman-settings-add-limit", "watchman-settings-profile-edit"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertEqual(WatchmanShotFixtures.addLimitError, WatchmanSettingsCopy.limitToolBlanks)
    }

    func testEveryFrameHasAShot() {
        let names = Set(WatchmanShotFixtures.shots.map(\.name))
        XCTAssertEqual(names.count, WatchmanShotFixtures.Frame.allCases.count)
        for frame in WatchmanShotFixtures.Frame.allCases {
            XCTAssertTrue(names.contains("watchman-\(frame.rawValue)"), frame.rawValue)
        }
        // The frames this spec names (§2, §10, §11).
        for name in ["journal-night", "journal-empty", "journal-loading", "journal-error", "journal-busy",
                     "journal-narrow", "journal-correct-sheet", "home-row", "strip-armed", "strip-unarmed",
                     "arm-first-time", "settings-results", "settings-never-run", "settings-running",
                     "settings-failed", "tray-menu", "target-panel-armed", "target-panel-unarmed",
                     "inbox-entry", "settings-not-learned", "journal-not-running", "journal-night-unsure"] {
            XCTAssertTrue(names.contains("watchman-\(name)"), name)
        }
    }
}
