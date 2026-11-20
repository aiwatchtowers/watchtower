import XCTest
@testable import WatchtowerChatText

/// The live steps disclosure of the current turn (#2065 spec §3): the fixed
/// six-row slot above the live line, its rows and timers, when it hides, and
/// the line's chevron and turn summary while it is open.
final class WorkchatStepsPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func step(_ id: String, _ tool: String, _ summary: String, start: Date?, end: Date?) -> SessionLiveAction {
        SessionLiveAction(id: id, tool: tool, summary: summary, startedAt: start, completedAt: end)
    }
    private func live(
        steps: [SessionLiveAction],
        more: Int = 0,
        turnActive: Bool = true,
        conversation: String = "c1",
        observed: Date? = nil
    ) -> SessionFeedLive {
        SessionFeedLive(observedAt: observed ?? now, conversation: conversation, turnAt: now - 60, turnActive: turnActive,
                        steps: steps, stepsMore: more)
    }
    private func slot(_ live: SessionFeedLive?, error: String? = nil, working: Bool = true) -> WorkchatLivePresentation.StepsSlot? {
        WorkchatLivePresentation.stepsSlot(snapshot: live, error: error, working: working, now: now)
    }
    private func row(_ live: SessionFeedLive?, stepsOpen: Bool = false) -> WorkchatLivePresentation.Row? {
        WorkchatLivePresentation.row(snapshot: live, error: nil, loaded: true, working: true, stateAt: now - 5, now: now,
                                     stepsOpen: stepsOpen)
    }
    private func steps(_ count: Int) -> [SessionLiveAction] {
        (0..<count).map { index in
            let start = now - TimeInterval(100 - index * 2)
            return step("s\(index)", "Read", "file\(index).go", start: start, end: index == count - 1 ? nil : start + 1)
        }
    }
    private var two: [SessionLiveAction] { steps(2) }

    func testRowsDurationsAndRunningTimer() throws {
        let slot = try XCTUnwrap(slot(live(steps: [
            step("t1", "Read", "live.go", start: now - 30, end: now - 26),
            step("t2", "Bash", "go test ./internal/sessionfeed", start: now - 14, end: nil)
        ])))
        XCTAssertEqual(slot.rows.map(\.id), ["t1", "t2"])
        XCTAssertEqual(slot.rows.map(\.summary), ["live.go", "go test ./internal/sessionfeed"])
        XCTAssertEqual(slot.rows.map(\.time), ["0:04", "0:14"])
        XCTAssertEqual(slot.rows.map(\.running), [false, true])
        XCTAssertEqual(slot.rows[0].symbol, WorkchatActivityPresenter.symbol(for: "Read"))
        XCTAssertEqual(slot.rows[1].symbol, WorkchatActivityPresenter.symbol(for: "Bash"))
        XCTAssertEqual(slot.title, "This turn · 2 steps")
    }

    func testMissingTimesShowNoDuration() throws {
        let slot = try XCTUnwrap(slot(live(steps: [
            step("t1", "Read", "a.go", start: nil, end: now - 2),
            step("t2", "Bash", "make", start: nil, end: nil)
        ])))
        XCTAssertEqual(slot.rows.map(\.time), [nil, nil])
        XCTAssertEqual(slot.rows.map(\.running), [false, true])
    }

    func testOpenStepBeforeCompletedOnesKeepsItsTimer() throws {
        // The Go cap keeps an older step that is still open ahead of completed ones.
        let slot = try XCTUnwrap(slot(live(steps: [
            step("a", "Agent", "review", start: now - 41, end: nil),
            step("b", "Read", "x.go", start: now - 5, end: now - 3)
        ])))
        XCTAssertEqual(slot.rows.map(\.time), ["0:41", "0:02"])
        XCTAssertEqual(slot.rows.map(\.running), [true, false])
    }

    func testTitleCountsTheCut() throws {
        XCTAssertEqual(try XCTUnwrap(slot(live(steps: steps(40), more: 5))).title, "This turn · 45 steps")
        XCTAssertEqual(try XCTUnwrap(slot(live(steps: steps(1)))).title, "This turn · 1 step")
        XCTAssertEqual(WorkchatLivePresentation.turnSummary(1), "This turn · 1 step")
        XCTAssertEqual(WorkchatLivePresentation.turnSummary(8), "This turn · 8 steps")
        XCTAssertEqual(WorkchatLivePresentation.stepsToggleHint(open: true), "Hide this turn’s steps")
        XCTAssertEqual(WorkchatLivePresentation.stepsToggleHint(open: false), "Show this turn’s steps")
    }

    func testStepsSlotHiddenOnTurnEndStopAndCard() {
        XCTAssertNotNil(slot(live(steps: two)))
        XCTAssertNil(slot(live(steps: two, turnActive: false)), "the turn ended")
        XCTAssertNil(slot(live(steps: two), working: false), "stop, or the host or session closed")
        XCTAssertNil(slot(nil), "the card shows: the pane passes no snapshot")
        XCTAssertNil(slot(live(steps: [])))
    }

    func testStepsSlotHiddenOnStaleOrError() {
        XCTAssertNotNil(slot(live(steps: two, observed: now - 9)))
        XCTAssertNil(slot(live(steps: two, observed: now - 10)), "a stale snapshot")
        XCTAssertNil(slot(live(steps: two), error: "x"), "a failed read")
        var undated = live(steps: two)
        undated.observedAt = nil
        XCTAssertNil(slot(undated), "a snapshot with no observation time")
    }

    func testNewConversationShowsOnlyItsSteps() throws {
        let first = try XCTUnwrap(slot(live(steps: [step("a1", "Read", "a.go", start: now - 9, end: now - 8)], conversation: "A")))
        XCTAssertEqual(first.rows.map(\.id), ["a1"])
        let second = try XCTUnwrap(slot(live(steps: [step("b1", "Edit", "b.go", start: now - 2, end: nil)], conversation: "B")))
        XCTAssertEqual(second.rows.map(\.id), ["b1"])
        XCTAssertEqual(second.title, "This turn · 1 step")
    }

    func testSlotHeightIsFixedAtSixRows() {
        XCTAssertEqual(WorkchatLivePresentation.stepsVisibleRows, 6)
        XCTAssertEqual(WorkchatLivePresentation.stepsHeight(rowHeight: 20), 120)
    }

    func testLineChevronAndSummaryWhenOpen() throws {
        let eight = steps(8)
        let open = try XCTUnwrap(row(live(steps: eight), stepsOpen: true))
        XCTAssertEqual(open.chevron, "chevron.down")
        XCTAssertEqual(open.text, "This turn · 8 steps")
        XCTAssertEqual(open.elapsed, "1:00", "the turn timer, not the newest step's")
        XCTAssertFalse(open.pulse)
        let closed = try XCTUnwrap(row(live(steps: eight), stepsOpen: false))
        XCTAssertEqual(closed.chevron, "chevron.up")
        XCTAssertNotEqual(closed.text, "This turn · 8 steps")
        XCTAssertNil(try XCTUnwrap(row(live(steps: []))).chevron)
        XCTAssertNil(try XCTUnwrap(row(live(steps: eight, turnActive: false), stepsOpen: true)).chevron,
                     "no slot, no chevron")
    }

    func testCardHidesTheChevron() throws {
        let hidden = try XCTUnwrap(WorkchatLivePresentation.row(
            snapshot: live(steps: steps(3)), error: nil, loaded: true, working: true, stateAt: nil, now: now,
            activityHidden: true, stepsOpen: true))
        XCTAssertNil(hidden.chevron)
        XCTAssertFalse(hidden.activity)
    }

    func testDecodesStepsAndDefaults() throws {
        let with = Data("""
        {"observed_at":"2026-11-19T10:00:00Z","conversation":"c","turn_active":true,
         "steps":[{"id":"t1","tool":"Read","summary":"a.go","started_at":"2026-11-19T09:59:50Z",
                   "completed_at":"2026-11-19T09:59:54Z"},
                  {"id":"t2","tool":"Bash","summary":"make","started_at":"2026-11-19T09:59:55Z"}],
         "steps_more":3}
        """.utf8)
        let decoded = try JSONDecoder().decode(SessionFeedLive.self, from: with)
        XCTAssertEqual(decoded.steps.map(\.id), ["t1", "t2"])
        XCTAssertNotNil(decoded.steps[0].completedAt)
        XCTAssertNil(decoded.steps[1].completedAt)
        XCTAssertEqual(decoded.stepsMore, 3)
        let without = try JSONDecoder().decode(SessionFeedLive.self, from: Data(#"{"conversation":"c"}"#.utf8))
        XCTAssertEqual(without.steps, [])
        XCTAssertEqual(without.stepsMore, 0)
    }
}
