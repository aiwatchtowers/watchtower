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
        XCTAssertEqual(Copy.protectionWarning,
                       "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here")
        XCTAssertEqual(Copy.daemonStopped, "Watchman is not running — the daemon is stopped")
        XCTAssertEqual(Copy.daemonStopped, WatchmanJournalCopy.daemonStopped)
    }

    /// The tuning spec's instruction copy (§2, §3), verbatim.
    func testInstructionCopyIsVerbatim() {
        XCTAssertEqual(Copy.fieldLabel, "Instruction for Watchman (optional)")
        XCTAssertEqual(Copy.placeholder, "What this session is for, what to prefer, what to leave to you — "
            + "e.g. \"ship task 3 only; ask me before touching the schema\"")
        XCTAssertEqual(Copy.shortTitle, "Hand to Watchman")
        XCTAssertEqual(Copy.handOver, "Hand over")
        XCTAssertEqual(Copy.cancel, "Cancel")
        XCTAssertEqual(Copy.editTitle, "Instruction for Watchman")
        XCTAssertEqual(Copy.save, "Save")
        XCTAssertEqual(Copy.instructionButton, "Instruction…")
        XCTAssertEqual(Copy.instructionIcon, "text.quote")
        XCTAssertEqual(Copy.retry, "Retry")
        XCTAssertEqual(Copy.saveFailed("the database is busy — try again"),
                       "Could not save: the database is busy — try again")
        XCTAssertEqual(Copy.counter(1912), "1912 / 2000")
        XCTAssertEqual(Copy.learningLine(WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000)),
                       "Watchman learns this workbench first (about 1 850 decisions). Questions asked meanwhile wait "
                           + "and are decided once it finishes — or answer them yourself.")
        XCTAssertEqual(Copy.learningLine(nil),
                       "Watchman learns this workbench first. Questions asked meanwhile wait "
                           + "and are decided once it finishes — or answer them yourself.")
    }

    /// The counter shows past 1800 characters as Go counts them (trimmed,
    /// runes); the field keeps at most 2000.
    func testCounterAndClip() {
        XCTAssertNil(Copy.counter(for: String(repeating: "a", count: 1800)))
        XCTAssertNil(Copy.counter(for: "  " + String(repeating: "a", count: 1800) + "\n"), "edges are trimmed")
        XCTAssertEqual(Copy.counter(for: String(repeating: "a", count: 1801)), "1801 / 2000")
        XCTAssertEqual(Copy.counter(for: String(repeating: "é", count: 1900)), "1900 / 2000")
        XCTAssertEqual(Copy.clipped(String(repeating: "a", count: 2100)).count, 2000)
        XCTAssertEqual(Copy.clipped("ship task 3"), "ship task 3")
        // Counted as the counter and Go count: the edges do not use the budget.
        let padded = "\n  " + String(repeating: "a", count: 2000) + "  \n"
        XCTAssertEqual(Copy.clipped(padded), padded)
        XCTAssertEqual(Copy.clipped("  " + String(repeating: "a", count: 2001)), "  " + String(repeating: "a", count: 2000))
        XCTAssertEqual(Copy.instructionUnread, "Watchman's stored instruction could not be read, so an empty one "
            + "would erase it unseen — type the new instruction, or Cancel")
        XCTAssertTrue(Copy.armInProgress.hasPrefix("Watchman is still handing this over or taking it back"))
    }

    func testSubject() {
        XCTAssertEqual(Copy.subject(.session(41), title: "Ship task 3"), "#41 Ship task 3")
        XCTAssertEqual(Copy.subject(.session(41), title: nil), "Session 41")
        XCTAssertEqual(Copy.subject(.target(4), title: ""), "Target #4")
        XCTAssertEqual(Copy.subject(.target(4), title: "Billing plan"), "#4 Billing plan")
    }

    func testBuilderCopy() {
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

    /// `since` is the arming time on the owner's clock, 24-hour; no mode
    /// word (tuning D8).
    func testSinceFormatsTheArmingTime() {
        XCTAssertEqual(Copy.stripArmed(since: Self.since, calendar: Self.utc), "Watchman · since 01:40")
        XCTAssertEqual(Copy.stripArmed(since: nil), "Watchman · on")
        XCTAssertEqual(Copy.targetArmed(since: Self.since, calendar: Self.utc),
                       "Watchman has this target · since 01:40")
        XCTAssertEqual(Copy.targetArmed(since: nil), "Watchman has this target")
        var berlin = Self.utc
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        XCTAssertEqual(Copy.since(Self.since, calendar: berlin), "since 02:40")
        XCTAssertEqual(Copy.since(AutomationDates.parse("2026-11-17T23:05:00Z"), calendar: Self.utc), "since 23:05")
        XCTAssertEqual(Copy.since(nil), "on")
        XCTAssertFalse(Copy.stripArmed(since: Self.since).contains("Sleep"))
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
        XCTAssertEqual(Copy.trayStatus(armed, calendar: Self.utc), "Watchman · since 01:40 · 3 sessions")
        let one = WatchmanStatus(workbenches: [], daemon: .unknown, mode: .sleep, modeSince: Self.since,
                                 armed: [WatchmanArmedEntry(scope: .session, id: 3)], armedSessions: [WatchmanArmedSession(id: 3)])
        XCTAssertEqual(Copy.trayStatus(one, calendar: Self.utc), "Watchman · since 01:40 · 1 session")
        let stopped = WatchmanStatus(workbenches: [], daemon: .stopped, mode: .sleep, modeSince: Self.since,
                                     armed: [WatchmanArmedEntry(scope: .session, id: 3)], armedSessions: [WatchmanArmedSession(id: 3)])
        XCTAssertEqual(Copy.trayStatus(stopped), Copy.daemonStopped)
    }

    /// A first time: the D21 line, the estimate and the learning line;
    /// always the limits and the residual risk; the warning line only when
    /// `protection_warning` is non-empty.
    func testSheetContent() {
        let estimate = WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000)
        let first = WatchmanArmReply(
            firstTime: true, estimate: estimate, protectionWarning: Copy.protectionWarning,
            hooksWarning: "guard cannot be installed in /tmp/acme-a\nguard cannot be installed in /tmp/acme-b")
        let content = WatchmanArmSheetContent(workbench: "acme-api", reply: first)
        XCTAssertEqual(content.mode, .firstTime)
        XCTAssertEqual(content.title, "Hand acme-api to Watchman?")
        XCTAssertEqual(content.body, Copy.sheetBody)
        XCTAssertEqual(content.lines.map(\.text), [
            Copy.analyticsLine, "Learning from your history: ~1 850 decisions, est. 1.6 M tokens",
            Copy.learningLine(estimate), Copy.limitsLine, Copy.residualRisk
        ])
        XCTAssertEqual(content.warnings, [Copy.protectionWarning, "guard cannot be installed in /tmp/acme-a",
                                          "guard cannot be installed in /tmp/acme-b"])
        XCTAssertEqual([content.cancel, content.confirm], ["Cancel", "Hand over"])
        XCTAssertEqual([content.fieldLabel, content.placeholder], [Copy.fieldLabel, Copy.placeholder])

        let learned = WatchmanArmSheetContent(workbench: "acme-api", reply: WatchmanArmReply(protectionWarning: ""))
        XCTAssertEqual(learned.lines.map(\.text), [Copy.limitsLine, Copy.residualRisk])
        XCTAssertEqual(learned.warnings, [])
    }

    /// Each hand-over's sheet: the short one names its subject only; a
    /// warning still opens the first-time one; the tray lists its sessions
    /// and shows the lines only when its check asks; edit says Save.
    func testSheetModes() {
        typealias Content = WatchmanArmSheetContent
        let short = Content.handOver(.session(41), workbench: "acme-api", reply: WatchmanArmReply(),
                                     subject: "#41 Ship task 3", sessions: ["#41 Ship task 3"])
        XCTAssertEqual(short.mode, .short)
        XCTAssertEqual(short.title, "Hand to Watchman")
        XCTAssertEqual(short.subject, "#41 Ship task 3")
        XCTAssertNil(short.body)
        XCTAssertEqual([short.lines.count, short.sessions.count, short.warnings.count], [0, 0, 0])

        let warned = Content.handOver(.target(4), workbench: "acme-api",
                                      reply: WatchmanArmReply(protectionWarning: Copy.protectionWarning),
                                      subject: "#4 Billing", sessions: [])
        XCTAssertEqual(warned.mode, .firstTime)
        XCTAssertEqual(warned.title, "Hand acme-api to Watchman?")
        XCTAssertEqual(warned.warnings, [Copy.protectionWarning])
        XCTAssertNil(warned.subject)

        let tray = Content.handOver(.allRunning, workbench: nil, reply: WatchmanArmReply(sessions: [1, 2]),
                                    subject: "", sessions: ["#1 a", "#2 b"])
        XCTAssertEqual(tray.mode, .tray)
        XCTAssertEqual(tray.title, "Hand to Watchman")
        XCTAssertEqual(tray.sessions, ["#1 a", "#2 b"])
        XCTAssertEqual(tray.lines, [])
        let trayFirst = Content.handOver(.allRunning, workbench: nil, reply: WatchmanArmReply(firstTime: true),
                                         subject: "", sessions: ["#1 a"])
        XCTAssertEqual(trayFirst.lines.first?.text, Copy.analyticsLine)

        let edit = Content.edit(subject: "#41 Ship task 3")
        XCTAssertEqual(edit.mode, .edit)
        XCTAssertEqual([edit.title, edit.confirm, edit.cancel], ["Instruction for Watchman", "Save", "Cancel"])
        XCTAssertEqual(edit.lines, [])
    }

    func testNeedsSheetOnFirstTimeOrAWarning() {
        XCTAssertFalse(WatchmanArmReply().needsSheet)
        XCTAssertTrue(WatchmanArmReply(firstTime: true).needsSheet)
        XCTAssertTrue(WatchmanArmReply(protectionWarning: Copy.protectionWarning).needsSheet)
        XCTAssertTrue(WatchmanArmReply(hooksWarning: "guard cannot be installed").needsSheet)
    }
}
