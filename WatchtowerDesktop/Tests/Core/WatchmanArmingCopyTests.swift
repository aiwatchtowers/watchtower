import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Every string of the arming controls (`WatchmanArmingCopy`): the spec's
/// verbatim copy (§2, §5, D21, D47) and the builder's lines.
final class WatchmanArmingCopyTests: XCTestCase {
    private typealias Copy = WatchmanArmingCopy

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private static let since = AutomationDates.parse("2026-11-17T01:40:00Z")

    func testSpecCopyIsVerbatim() {
        XCTAssertEqual(Copy.handTo, "Hand to Watchman")
        XCTAssertEqual(Copy.takeBack, "Take back")
        XCTAssertEqual(Copy.trayHandAll, "Hand all running sessions to Watchman")
        XCTAssertEqual(Copy.analyticsLine, "Agent analytics turned on — Watchman learns from your sessions")
        XCTAssertEqual(Copy.learningNote, "Until learning finishes, Watchman parks everything for you")
        XCTAssertEqual(Copy.protectionWarning,
                       "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here")
        XCTAssertEqual(Copy.daemonStopped, "Watchman is not running — the daemon is stopped")
        XCTAssertEqual(Copy.daemonStopped, WatchmanJournalCopy.daemonStopped)
    }

    func testBuilderCopy() {
        XCTAssertEqual(Copy.notNow, "Not now")
        XCTAssertEqual(Copy.limitsLine, "Merging to main, messages to people and releases stay yours: Watchman parks them.")
        // Spec §5 item 4: the sheet names the residual risks and points to the guide's list.
        XCTAssertEqual(Copy.residualRisk, "Not caught: deleting files outside the worktree from a script, "
            + "or messaging people from a script with its own token; more in Hand a session to Watchman in the guide.")
        XCTAssertTrue(Copy.sheetBody.hasPrefix("Watchman answers for you in the sessions you hand it"))
        XCTAssertEqual(Copy.sheetTitle(workbench: "acme-api"), "Hand acme-api to Watchman?")
        XCTAssertEqual(Copy.targetUnarmedCaption(target: 1820),
                       "Watchman answers for you in every session under #1820 until you take it back.")
        XCTAssertEqual(Copy.targetArmedCaption(target: 1820),
                       "Answers for you in every session under #1820: the running ones and the ones started under it.")
        XCTAssertEqual(Copy.armFailed("no row"), "Couldn't hand it to Watchman: no row")
        XCTAssertEqual(Copy.takeBackFailed("busy"), "Couldn't take it back: busy")
        XCTAssertTrue(Copy.handHelp.contains("Inbox → Watchman"))
        XCTAssertEqual(Copy.viaTargetHelp(target: 4, direct: false), "Handed over through #4 — take #4 back on its panel")
        XCTAssertEqual(Copy.viaTargetHelp(target: 4, direct: true),
                       "Handed over through #4 and directly — Take back here removes the direct hand-over; "
                           + "take #4 back on its panel")
        XCTAssertEqual(Copy.nothingToHandOver, "Nothing to hand over: no agent session is running")
        XCTAssertTrue(Copy.updateCLI.hasPrefix("Update Watchtower's command-line tool"))
        XCTAssertEqual(Copy.sessionsChanged, "The running sessions changed since this opened — this is the new set.")
        XCTAssertTrue(Copy.sidecarNote.hasPrefix("Handed to Watchman"))
    }

    /// `Sleep since` is `mode_since` on the owner's clock, 24-hour.
    func testSleepSinceFormatsModeSince() {
        XCTAssertEqual(Copy.stripArmed(since: Self.since, calendar: Self.utc), "Watchman · Sleep since 01:40")
        XCTAssertEqual(Copy.targetArmed(since: Self.since, calendar: Self.utc),
                       "Watchman has this target · Sleep since 01:40")
        var berlin = Self.utc
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        XCTAssertEqual(Copy.sleepSince(Self.since, calendar: berlin), "Sleep since 02:40")
        XCTAssertEqual(Copy.sleepSince(AutomationDates.parse("2026-11-17T23:05:00Z"), calendar: Self.utc),
                       "Sleep since 23:05")
        XCTAssertEqual(Copy.sleepSince(nil), "Sleep")
    }

    func testHistoryLine() {
        XCTAssertEqual(Copy.historyLine(WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000)),
                       "Learning from your history: ~1 850 decisions, est. 1.6 M tokens")
        XCTAssertEqual(Copy.historyLine(nil), "Learning from your history first")
    }

    func testTrayStatusLine() throws {
        XCTAssertNil(Copy.trayStatus(nil))
        let off = WatchmanStatus(workbenches: [], daemon: .running)
        XCTAssertEqual(Copy.trayStatus(off), "Watchman · Off")
        let armed = WatchmanStatus(workbenches: [], daemon: .running, mode: .sleep, modeSince: Self.since,
                                   armed: [WatchmanArmedEntry(scope: .target, id: 4)],
                                   armedSessions: [3, 5, 7].map { WatchmanArmedSession(id: $0, target: 4) })
        XCTAssertEqual(Copy.trayStatus(armed, calendar: Self.utc), "Watchman · Sleep since 01:40 · 3 sessions")
        let one = WatchmanStatus(workbenches: [], daemon: .unknown, mode: .sleep, modeSince: Self.since,
                                 armed: [WatchmanArmedEntry(scope: .session, id: 3)], armedSessions: [WatchmanArmedSession(id: 3)])
        XCTAssertEqual(Copy.trayStatus(one, calendar: Self.utc), "Watchman · Sleep since 01:40 · 1 session")
        let stopped = WatchmanStatus(workbenches: [], daemon: .stopped, mode: .sleep, modeSince: Self.since,
                                     armed: [WatchmanArmedEntry(scope: .session, id: 3)], armedSessions: [WatchmanArmedSession(id: 3)])
        XCTAssertEqual(Copy.trayStatus(stopped), Copy.daemonStopped)
    }

    /// A first time: the D21 line, the estimate and the parked-while-learning
    /// note; always the limits and the residual risk; the warning line only
    /// when `protection_warning` is non-empty.
    func testSheetContent() {
        let first = WatchmanArmReply(
            firstTime: true, estimate: WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000),
            protectionWarning: Copy.protectionWarning,
            hooksWarning: "guard cannot be installed in /tmp/acme-a\nguard cannot be installed in /tmp/acme-b")
        let content = WatchmanArmSheetContent(workbench: "acme-api", reply: first)
        XCTAssertEqual(content.title, "Hand acme-api to Watchman?")
        XCTAssertEqual(content.lines.map(\.text), [
            Copy.analyticsLine, "Learning from your history: ~1 850 decisions, est. 1.6 M tokens", Copy.learningNote,
            Copy.limitsLine, Copy.residualRisk
        ])
        XCTAssertEqual(content.warnings, [Copy.protectionWarning, "guard cannot be installed in /tmp/acme-a",
                                          "guard cannot be installed in /tmp/acme-b"])
        XCTAssertEqual([content.cancel, content.confirm], ["Not now", "Hand to Watchman"])

        let learned = WatchmanArmSheetContent(workbench: "acme-api", reply: WatchmanArmReply(protectionWarning: ""))
        XCTAssertEqual(learned.lines.map(\.text), [Copy.limitsLine, Copy.residualRisk])
        XCTAssertEqual(learned.warnings, [])
    }

    func testNeedsSheetOnFirstTimeOrAWarning() {
        XCTAssertFalse(WatchmanArmReply().needsSheet)
        XCTAssertTrue(WatchmanArmReply(firstTime: true).needsSheet)
        XCTAssertTrue(WatchmanArmReply(protectionWarning: Copy.protectionWarning).needsSheet)
        XCTAssertTrue(WatchmanArmReply(hooksWarning: "guard cannot be installed").needsSheet)
    }
}
