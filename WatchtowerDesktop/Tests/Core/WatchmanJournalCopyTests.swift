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

    /// The busy line while questions wait for learning (tuning spec §3).
    func testWaitingForLearningLines() {
        XCTAssertEqual(Copy.waitingForLearning(percent: 42, count: 3), "Waiting for learning (42%): 3 questions")
        XCTAssertEqual(Copy.waitingForLearning(percent: 7, count: 1), "Waiting for learning (7%): 1 question")
        XCTAssertEqual(Copy.waitingForLearningPaused, "Waiting for learning — background AI is paused")
        XCTAssertEqual(Copy.waitingForLearning(percent: nil, count: 3), "Waiting for learning: 3 questions",
                       "no percent known yet")
        XCTAssertEqual(Copy.waitingForLearning(percent: nil, count: 1), "Waiting for learning: 1 question")
    }

    /// The stall card (tuning spec §4b): the session's title, the reason Go
    /// stored (either one), "<workbench> · <HH:MM> · stopped".
    func testStallCardLines() {
        let created = date("2026-11-17T02:14:00Z")
        let pings = WatchmanItem(id: 1, workbenchName: "acme-api", sessionID: 41,
                                 sessionTitle: "Ship task 3 of the billing plan", kind: "stall", outcome: "parked",
                                 parkReason: "The agent stopped and did not go on after 3 pings", createdAt: created)
        XCTAssertEqual(Copy.stallTitle(pings), "#41 Ship task 3 of the billing plan")
        XCTAssertEqual(Copy.stallReason(pings), "The agent stopped and did not go on after 3 pings")
        XCTAssertEqual(Copy.stallMeta(pings, calendar: calendar), "acme-api · 02:14 · stopped")
        let stuck = WatchmanItem(id: 2, sessionID: 42, kind: "stall", outcome: "parked",
                                 parkReason: "The agent stopped and Watchman could not get a ping through for 9 minutes",
                                 createdAt: created)
        XCTAssertEqual(Copy.stallTitle(stuck), "Session 42", "a session with no title: by its id")
        XCTAssertEqual(Copy.stallReason(stuck),
                       "The agent stopped and Watchman could not get a ping through for 9 minutes")
        XCTAssertEqual(Copy.stallMeta(stuck, calendar: calendar), "02:14 · stopped")
        XCTAssertEqual(Copy.stallReason(WatchmanItem(id: 3, kind: "stall", outcome: "parked", createdAt: created)),
                       "The agent stopped")
    }

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
        XCTAssertEqual(Copy.outcome(WatchmanItem(id: 6, outcome: "superseded", createdAt: created)),
                       "The ask was withdrawn before the answer")
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
