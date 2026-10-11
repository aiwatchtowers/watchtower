import XCTest
import WatchtowerCore

/// The table of spec 2026-10-10-owner-asks-v2 Part 5.2, first match wins.
final class ChatQuestionEscalationPolicyTests: XCTestCase {
    private typealias Policy = ChatQuestionEscalationPolicy

    private let started = Date(timeIntervalSince1970: 1_790_000_000)
    /// When the guard recorded the question: a minute into the run.
    private var asked: Date { started.addingTimeInterval(60) }

    private func stamp(_ date: Date) -> String { SessionAgentStatus.formatStamp(date) }

    private func row(
        projectID: Int64? = 7,
        state: String? = "waiting",
        stateAt: Date? = nil,
        questionAt: String? = nil,
        question: String? = #"{"question":"Red or orange?","options":[]}"#
    ) -> SessionAgentStateRow {
        var row = SessionAgentStateRow(
            id: 1, projectID: projectID, title: "s", agentState: state,
            agentStateAt: stamp(stateAt ?? asked), workbenchName: "acme"
        )
        row.chatQuestion = question
        row.chatQuestionAt = questionAt ?? stamp(asked)
        return row
    }

    private func decide(
        _ row: SessionAgentStateRow,
        live: Bool = true,
        startedAt: Date? = nil,
        presence: Policy.Presence = .present,
        draft: Bool = false,
        after: TimeInterval
    ) -> Policy.Decision {
        Policy.decide(row: row, live: live, startedAt: startedAt ?? started, presence: presence,
                      hasOwnerDraft: draft, now: asked.addingTimeInterval(after))
    }

    func testConstants() {
        XCTAssertEqual(Policy.timeout, 600)
        XCTAssertEqual(Policy.leaveGrace, 90)
        XCTAssertEqual(Policy.draftCap, 1800)
    }

    /// E12.
    func testTenMinutesPresentEscalates() {
        XCTAssertEqual(decide(row(), after: 0), .none)
        XCTAssertEqual(decide(row(), after: 599), .none)
        XCTAssertEqual(decide(row(), after: 600), .escalate(.timeout))
    }

    /// E13: away from minute 2.
    func testLeavingEscalatesAfterTheGrace() {
        let left = asked.addingTimeInterval(120)
        XCTAssertEqual(decide(row(), presence: .away(since: left), after: 120 + 89), .none)
        XCTAssertEqual(decide(row(), presence: .away(since: left), after: 120 + 90), .escalate(.left))
    }

    /// Leaving outranks the 10 minutes: away past both reads as `left`.
    func testAwayPastTheTimeoutIsLeft() {
        let left = asked.addingTimeInterval(9 * 60)
        XCTAssertEqual(decide(row(), presence: .away(since: left), after: 10 * 60), .none,
                       "away inside the grace at minute 10: the present-only timeout does not apply")
        XCTAssertEqual(decide(row(), presence: .away(since: left), after: 9 * 60 + 90), .escalate(.left))
    }

    /// E13a: a 40 s alt-tab, then back.
    func testComingBackInsideTheGraceKeepsTheQuestion() {
        let left = asked.addingTimeInterval(120)
        XCTAssertEqual(decide(row(), presence: .away(since: left), after: 160), .none)
        XCTAssertEqual(decide(row(), presence: .present, after: 161), .none)
        XCTAssertEqual(decide(row(), presence: .present, after: 599), .none, "the 10 minutes still count from the question")
    }

    /// E10b: recorded while the owner was away (`stop_hook_active`).
    func testAQuestionRecordedWhileAwayEscalatesAtOnce() {
        XCTAssertEqual(decide(row(), presence: .away(since: asked.addingTimeInterval(-300)), after: 0),
                       .escalate(.away))
        XCTAssertEqual(decide(row(), presence: .away(since: asked), after: 1), .escalate(.away),
                       "away since the very moment of the question")
        XCTAssertEqual(decide(row(), presence: .away(since: asked.addingTimeInterval(1)), after: 2), .none,
                       "left after it: the grace applies")
    }

    /// E13b, E15: a draft defers present, left and away alike, up to the cap.
    func testADraftDefersUpToTheCap() {
        XCTAssertEqual(decide(row(), draft: true, after: 600), .none)
        XCTAssertEqual(decide(row(), presence: .away(since: asked.addingTimeInterval(120)), draft: true, after: 1000),
                       .none)
        XCTAssertEqual(decide(row(), presence: .away(since: asked.addingTimeInterval(-60)), draft: true, after: 0),
                       .none)
        XCTAssertEqual(decide(row(), draft: true, after: 1799), .none)
        XCTAssertEqual(decide(row(), draft: true, after: 1800), .escalate(.timeout))
        XCTAssertEqual(decide(row(), presence: .away(since: asked.addingTimeInterval(120)), draft: true, after: 1800),
                       .escalate(.timeout), "the cap is a timeout whatever the presence")
    }

    /// E11, E11a: the owner's prompt moved the state (a turn running or a
    /// permission prompt up); also a value this build does not know.
    func testNotWaitingNeverEscalates() {
        for state in ["working", "approval", "dialog", nil] {
            let moved = row(state: state, stateAt: asked.addingTimeInterval(240))
            XCTAssertEqual(decide(moved, after: 1800), .none, "\(state ?? "nil")")
            XCTAssertEqual(decide(moved, presence: .away(since: asked.addingTimeInterval(-60)), after: 0), .none)
        }
    }

    /// A `waiting` stamped well after the question is a later turn's: Go's
    /// take refuses it (`agent_state_at` ≤ `chat_question_at` + 30 s).
    func testAWaitingLaterThanTheToleranceNeverEscalates() {
        XCTAssertEqual(decide(row(stateAt: asked.addingTimeInterval(30)), after: 600), .escalate(.timeout))
        XCTAssertEqual(decide(row(stateAt: asked.addingTimeInterval(31)), after: 600), .none)
        XCTAssertEqual(decide(row(stateAt: asked.addingTimeInterval(-50)), after: 600), .escalate(.timeout),
                       "no lower bound: an older waiting with nothing since is the live one")
    }

    /// E22: the process ended; also a standalone terminal.
    func testNotLiveNeverEscalates() {
        XCTAssertEqual(decide(row(), live: false, after: 1800), .none)
        XCTAssertEqual(decide(row(), live: false, presence: .away(since: started), after: 0), .none)
        XCTAssertEqual(decide(row(projectID: nil), after: 1800), .none)
    }

    /// The stored state predates this run: a dead run's question.
    func testEarlierRunNeverEscalates() {
        let restarted = asked.addingTimeInterval(10)
        XCTAssertEqual(decide(row(), startedAt: restarted, after: 1800), .none)
        let unknownStart = Policy.decide(row: row(), live: true, startedAt: nil, presence: .present,
                                         hasOwnerDraft: false, now: asked.addingTimeInterval(1800))
        XCTAssertEqual(unknownStart, .none, "an unknown start trusts nothing")
    }

    func testNoQuestionIsNone() {
        var none = row()
        none.chatQuestion = nil
        none.chatQuestionAt = nil
        XCTAssertEqual(decide(none, after: 1800), .none)
    }

    func testFutureOrUnparsableStampIsNone() {
        let future = row(questionAt: stamp(asked.addingTimeInterval(6)))
        XCTAssertEqual(decide(future, after: 0), .none, "6 s ahead of the clock")
        XCTAssertEqual(decide(future, presence: .away(since: started), after: 0), .none)
        let tolerated = row(questionAt: stamp(asked.addingTimeInterval(5)))
        XCTAssertEqual(decide(tolerated, presence: .away(since: started), after: 0), .escalate(.away),
                       "5 s ahead is tolerated")
        for bad in ["", "yesterday", "2026-10-10T12:34:56Z"] {
            XCTAssertEqual(decide(row(questionAt: bad), after: 1800), .none, bad)
        }
    }
}
