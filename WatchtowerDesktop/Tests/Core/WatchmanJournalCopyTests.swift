import XCTest
@testable import WatchtowerCore

/// Pins the journal's copy (spec §10 and the phase-2 plan's verbatim lines).
final class WatchmanJournalCopyTests: XCTestCase {
    typealias Copy = WatchmanJournalCopy

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private func date(_ text: String) -> Date { AutomationDates.parse(text) ?? .distantPast }

    func testHomeRowText() {
        let counts = WatchmanNightCounts(start: date("2026-11-16T12:00:00Z"), decided: 14, unsure: 2, waiting: 2)
        XCTAssertEqual(Copy.homeRow(counts), "Overnight Watchman decided 14 — 2 unsure, 2 waiting for you")
    }

    func testGapLine() {
        let gap = date("2026-11-17T02:10:00Z")...date("2026-11-17T03:05:00Z")
        XCTAssertEqual(Copy.gapLine(gap, calendar: calendar), "the Mac slept from 02:10 to 03:05, nothing ran")
    }

    func testOwnerFirstAndSessionEndedLines() {
        let created = date("2026-11-17T02:00:00Z")
        XCTAssertEqual(Copy.outcome(WatchmanItem(id: 1, outcome: "owner_first", createdAt: created)),
                       "the owner answered first")
        XCTAssertEqual(Copy.outcome(WatchmanItem(id: 2, outcome: "answered", delivery: "no_session", createdAt: created)),
                       "session ended")
        XCTAssertEqual(Copy.outcome(WatchmanItem(id: 3, outcome: "answered", createdAt: created)), "Answered in the session")
        XCTAssertEqual(Copy.outcome(WatchmanItem(id: 4, outcome: "approved", createdAt: created)), "Approved the review round")
        XCTAssertEqual(Copy.outcome(WatchmanItem(id: 5, outcome: "changes", createdAt: created)),
                       "Asked for changes in the review round")
    }

    func testEveryCardLabel() {
        XCTAssertEqual(Copy.title, "Watchman")
        XCTAssertEqual(Copy.waitingTitle, "WAITING FOR YOU")
        XCTAssertEqual(Copy.checksTitle, "Checks nobody ran")
        XCTAssertEqual(Copy.decidedTitle, "Decided")
        XCTAssertEqual([Copy.unsureBadge, Copy.choseLabel, Copy.leanedOn], ["Unsure", "Chose", "Leaned on"])
        XCTAssertEqual(Copy.checkLine, "Not run by you — Watchman continued")
        XCTAssertEqual(Copy.daemonStopped, "Watchman is not running — the daemon is stopped")
        XCTAssertEqual(Copy.retry, "Retry")
        XCTAssertTrue(Copy.readFailed.contains("nothing was lost"))
        XCTAssertTrue(Copy.emptyHint.contains("Hand to Watchman"))
        XCTAssertEqual(Copy.deciding("Store the window per workbench?\nmore"), "Deciding: Store the window per workbench?")

        let created = date("2026-11-17T05:12:00Z")
        let parked = WatchmanItem(id: 1, workbenchName: "acme-api", sessionID: 4, outcome: "parked",
                                  parkReason: "merging to main is yours", createdAt: created)
        XCTAssertEqual(Copy.waitingReason(parked), "Parked: merging to main is yours")
        XCTAssertEqual(Copy.place(parked, calendar: calendar), "acme-api · session 4 · 05:12")
        let handed = WatchmanItem(id: 2, outcome: "handed", rationale: "issue a new token in the provider's console",
                                  createdAt: created)
        XCTAssertEqual(Copy.waitingReason(handed), "Handed to you: issue a new token in the provider's console")
        let decided = WatchmanItem(id: 3, kind: "permission", confidence: "low", category: "", createdAt: created)
        XCTAssertEqual(Copy.meta(decided), "confidence low · permission")
        XCTAssertEqual(Copy.meta(WatchmanItem(id: 4, confidence: "high", category: "design", createdAt: created)),
                       "confidence high · design")
        XCTAssertEqual(Copy.question(WatchmanItem(id: 5, kind: "review_code", question: "", createdAt: created)),
                       "Code review")
    }

    func testNightLinesAndHeader() {
        let start = date("2026-11-16T12:00:00Z")
        let now = date("2026-11-17T09:00:00Z")
        XCTAssertEqual(Copy.nightTitle(start, now: now, calendar: calendar), "Tonight")
        XCTAssertEqual(Copy.nightTitle(start, now: date("2026-11-17T13:00:00Z"), calendar: calendar), "Night of 16 Nov")

        let unsure = WatchmanItem(id: 1, createdAt: date("2026-11-17T01:40:00Z"),
                                  decidedAt: date("2026-11-17T01:41:00Z"))
        let sure = WatchmanItem(id: 2, unsure: false, createdAt: date("2026-11-17T07:00:00Z"),
                                decidedAt: date("2026-11-17T07:30:00Z"))
        let waiting = WatchmanItem(id: 3, outcome: "parked", createdAt: date("2026-11-17T03:00:00Z"))
        var night = WatchmanNight(date: start, waiting: [waiting], decided: [unsure, sure], costUSD: 3.4)
        XCTAssertEqual(Copy.nightListLine(night, live: false), "2 decided · 1 unsure · 1 waiting")
        XCTAssertEqual(Copy.nightListLine(night, live: true), "In progress · 2 decided so far")
        XCTAssertEqual(Copy.nightSpan(night, live: false, calendar: calendar), "01:40–07:30 · the Mac stayed awake")
        XCTAssertEqual(Copy.nightSpan(night, live: true, calendar: calendar), "Since 01:40 · Watchman is on")
        XCTAssertEqual(Copy.cost(night.costUSD, tonight: true), "Cost tonight $3.40")
        XCTAssertEqual(Copy.cost(night.costUSD, tonight: false), "Cost $3.40")
        XCTAssertEqual(Copy.decidedSummary(unsure: 2, sure: 12), "2 unsure · 12 sure")
        XCTAssertEqual(Copy.decidedSummary(unsure: 3, sure: 0), "3 unsure")

        night.gaps = [date("2026-11-17T02:10:00Z")...date("2026-11-17T03:00:00Z")]
        XCTAssertEqual(Copy.nightSpan(night, live: false, calendar: calendar), "01:40–07:30")
        night.decided = [sure]
        night.waiting = []
        XCTAssertEqual(Copy.nightListLine(night, live: false), "1 decided · all sure")
    }

    func testInboxEntryLines() {
        let counts = WatchmanNightCounts(start: date("2026-11-16T12:00:00Z"), decided: 14, unsure: 2, waiting: 2)
        XCTAssertEqual(Copy.inboxSummary(waiting: 2), "2 waiting")
        XCTAssertEqual(Copy.inboxSummary(waiting: 0), "")
        XCTAssertEqual(Copy.inboxDetail(counts, now: date("2026-11-18T09:00:00Z"), calendar: calendar),
                       "Night of 16 Nov · 14 decided · 2 unsure")
        XCTAssertEqual(Copy.inboxDetail(nil, now: date("2026-11-18T09:00:00Z"), calendar: calendar), "")
    }

    /// C1: the Watchman entry has its own empty-state copy key.
    func testEmptyStateCopyKey() throws {
        let copy = try XCTUnwrap(EmptyStateCopyTable.copy(for: Copy.emptyCopyKey, briefingHour: 8))
        XCTAssertEqual(copy.title, "No night yet")
        XCTAssertTrue(copy.landsHere.hasPrefix("When you hand a session to Watchman and leave"))
        XCTAssertNil(copy.primaryAction)
    }

    /// OK, Correct… and where a correction went (Task 17).
    func testFeedbackLines() {
        XCTAssertEqual([Copy.ok, Copy.correct, Copy.openSession, Copy.markDone],
                       ["OK", "Correct…", "Open session", "Mark done"])
        XCTAssertEqual(Copy.okGiven, "You marked this OK — Watchman learns from it")
        XCTAssertEqual(Copy.corrected("Global.\nOne window."), "You corrected: Global.")
        XCTAssertEqual(Copy.sending, "Sending your correction…")
        XCTAssertEqual(Copy.sentToSession(3), "Sent to session 3")
        XCTAssertEqual(Copy.typedIntoSession(3), "Typed into session 3 — press Return there to send it")
        XCTAssertEqual(Copy.copiedForSession(3), "On the clipboard — paste it into session 3")
        XCTAssertEqual(Copy.heldForSession(3), "Waiting to go into session 3 — it is on a permission prompt")
        XCTAssertEqual(Copy.startedSession(42), "Started session 42 with your correction")
        XCTAssertEqual(Copy.notSent("the workbench is gone"), "Not sent — the workbench is gone")
        XCTAssertEqual(Copy.saveFailed("database is locked"), "Couldn't save: database is locked")
        XCTAssertEqual([Copy.correctTitle, Copy.correctQuestion, Copy.cancel, Copy.sendCorrection],
                       ["Correct this decision", "What would you have decided?", "Cancel", "Send Correction"])
        let item = WatchmanItem(id: 9, workbenchName: "acme-api", sessionID: 0, targetID: 0, question: "Rename it?",
                                createdAt: date("2026-11-17T02:00:00Z"))
        XCTAssertEqual(Copy.correctionLine(item, text: " Keep it.\n\n Ship. "),
                       "Watchman decided \"Rename it?\" while I was away. My correction: Keep it. Ship.")
    }
}
