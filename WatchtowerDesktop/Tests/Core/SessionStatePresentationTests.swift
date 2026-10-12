import XCTest
import WatchtowerCore

final class SessionStatePresentationTests: XCTestCase {
    private typealias State = SessionSwitcherPresentation.State

    /// Spec 2026-10-03-workbench-session-report §4b's table, row by row.
    func testEachTableRow() {
        let rows: [(State, SessionStatePresentation.Tone, String?, String)] = [
            (.live(.working), .green, nil, "Working"),
            (.live(.working, openAsks: 2), .green, "questionmark", "Working · 2 asks open"),
            (.live(.waitingOnAsk, openAsks: 1), .orange, "questionmark", "Waiting for you · ask #12"),
            (.live(.needsApproval), .orange, "hand.raised.fill", "Needs approval"),
            (.live(.finished, openAsks: 1), .orange, "checkmark", "Finished · 1 ask open"),
            (.live(.stopped), .secondary, "pause.fill", "Stopped"),
            (.live(.finished), .blue, "checkmark", "Finished"),
            (.live(.failed, error: "rate limit"), .red, "exclamationmark", "Error: rate limit"),
            (.live(.running), .green, nil, "Running"),
            (.notStarted, .secondary, nil, "Not running")
        ]
        for (state, tone, glyph, caption) in rows {
            XCTAssertEqual(SessionStatePresentation.color(for: state), tone, "\(state)")
            XCTAssertEqual(SessionStatePresentation.glyph(for: state), glyph, "\(state)")
            XCTAssertEqual(SessionStatePresentation.caption(for: state, oldestAskID: 12), caption, "\(state)")
            XCTAssertEqual(SessionStatePresentation.isRing(state), !state.live, "\(state)")
        }
    }

    func testFillOrRingFollowsLiveness() {
        let closedFinished = State(kind: .finished, live: false)
        XCTAssertTrue(SessionStatePresentation.isRing(closedFinished))
        XCTAssertEqual(SessionStatePresentation.color(for: closedFinished), .blue, "a blue ring: finished and closed")
        let closedAsk = State(kind: .waitingOnAsk, live: false, openAsks: 1)
        XCTAssertTrue(SessionStatePresentation.isRing(closedAsk))
        XCTAssertEqual(SessionStatePresentation.color(for: closedAsk), .orange, "an orange ring: closed with an ask")
        XCTAssertTrue(SessionStatePresentation.isRing(.notStarted))
        XCTAssertEqual(SessionStatePresentation.color(for: .notStarted), .secondary, "a grey ring: not running")
        XCTAssertFalse(SessionStatePresentation.isRing(.live(.stopped)))
    }

    func testAskCountsInCaptions() {
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.working, openAsks: 1), oldestAskID: nil),
                       "Working · 1 ask open")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.working, openAsks: 2), oldestAskID: nil),
                       "Working · 2 asks open")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.finished, openAsks: 2), oldestAskID: nil),
                       "Finished · 2 asks open")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.waitingOnAsk, openAsks: 1), oldestAskID: 12),
                       "Waiting for you · ask #12")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.waitingOnAsk, openAsks: 3), oldestAskID: 12),
                       "Waiting for you · ask #12 · 3 asks")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.waitingOnAsk, openAsks: 3), oldestAskID: nil),
                       "Waiting for you · 3 asks", "without the oldest id the caption names no ask")
    }

    /// #534: Ready to check is purple with a checklist glyph, a ring when
    /// not live and never pulsing; its caption names the oldest ask, says
    /// "review" only when every open ask is one, and counts more than one.
    func testReadyToCheckIsPurpleWithChecklist() {
        let checks = State.live(.readyToCheck, openAsks: 1, oldestAskID: 7, openQuestionAsks: 0)
        XCTAssertEqual(SessionStatePresentation.color(for: checks), .purple)
        XCTAssertEqual(SessionStatePresentation.glyph(for: checks), "checklist")
        XCTAssertFalse(SessionStatePresentation.isRing(checks))
        XCTAssertFalse(SessionStatePresentation.pulses(checks))
        XCTAssertEqual(SessionStatePresentation.caption(for: checks), "Ready to check · ask #7")
        let ring = State(kind: .readyToCheck, live: false, openAsks: 1, oldestAskID: 7, openQuestionAsks: 0)
        XCTAssertTrue(SessionStatePresentation.isRing(ring))
        XCTAssertEqual(SessionStatePresentation.color(for: ring), .purple, "a purple ring")
        let reviews = State.live(.readyToCheck, openAsks: 1, oldestAskID: 7, openQuestionAsks: 0, openReviewAsks: 1)
        XCTAssertEqual(SessionStatePresentation.caption(for: reviews), "Ready for review · ask #7")
        XCTAssertEqual(SessionStatePresentation.glyph(for: reviews), "checklist")
        let mixed = State.live(.readyToCheck, openAsks: 2, oldestAskID: 7, openQuestionAsks: 0, openReviewAsks: 1)
        XCTAssertEqual(SessionStatePresentation.caption(for: mixed), "Ready to check · ask #7 · 2 asks",
                       "a check among reviews reads check")
        let many = State.live(.readyToCheck, openAsks: 3, oldestAskID: 7, openQuestionAsks: 0, openReviewAsks: 3)
        XCTAssertEqual(SessionStatePresentation.caption(for: many), "Ready for review · ask #7 · 3 asks")
        XCTAssertEqual(SessionStatePresentation.caption(for: checks, oldestAskID: nil), "Ready to check")
    }

    /// #534: Working and Agents working keep their kind and caption with only
    /// checks or reviews open; the glyph beside the ask count is `checklist`,
    /// and one question brings back `questionmark`.
    func testWorkingWithOnlyChecksShowsChecklistGlyph() {
        let cases: [(State, String?, String)] = [
            (.live(.working, openAsks: 1, openQuestionAsks: 0), "checklist", "Working · 1 ask open"),
            (.live(.working, openAsks: 2, openQuestionAsks: 1), "questionmark", "Working · 2 asks open"),
            (.live(.background, openAsks: 1, backgroundAgents: 2, openQuestionAsks: 0, openReviewAsks: 1),
             "checklist", "2 agents working · 1 ask open"),
            (.live(.background, openAsks: 1, backgroundAgents: 2), "questionmark", "2 agents working · 1 ask open"),
            (.live(.background, backgroundAgents: 2), "person.2.fill", "2 agents working")
        ]
        for (state, glyph, caption) in cases {
            XCTAssertEqual(SessionStatePresentation.glyph(for: state), glyph, "\(state)")
            XCTAssertEqual(SessionStatePresentation.caption(for: state), caption, "\(state)")
            XCTAssertEqual(SessionStatePresentation.color(for: state), .green, "\(state)")
        }
    }

    func testErrorCaption() {
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.failed, error: "rate_limit"), oldestAskID: nil),
                       "Error: rate limit", "the raw error type reads as words")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.failed, error: "authentication_failed"), oldestAskID: nil),
                       "Error: authentication failed")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.failed, error: "overloaded"), oldestAskID: nil),
                       "Error: overloaded")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.failed, error: "_"), oldestAskID: nil),
                       "Stopped on an error", "nothing left after the underscores")
        XCTAssertEqual(SessionStatePresentation.caption(for: .live(.failed), oldestAskID: nil), "Stopped on an error",
                       "an unknown error type")
    }

    /// Spec 2026-10-10-session-background-agents §5.2: green; `person.2.fill`
    /// without asks, `questionmark` with them; the caption counts the agents.
    func testBackgroundIsGreenWithAgentCount() {
        let rows: [(State, String?, String)] = [
            (.live(.background), "person.2.fill", "Agents working"),
            (.live(.background, backgroundAgents: 1), "person.2.fill", "1 agent working"),
            (.live(.background, backgroundAgents: 3), "person.2.fill", "3 agents working"),
            (.live(.background, openAsks: 1, backgroundAgents: 1), "questionmark", "1 agent working · 1 ask open"),
            (.live(.background, openAsks: 2, backgroundAgents: 3), "questionmark", "3 agents working · 2 asks open"),
            (.live(.background, openAsks: 2), "questionmark", "Agents working · 2 asks open")
        ]
        for (state, glyph, caption) in rows {
            XCTAssertEqual(SessionStatePresentation.color(for: state), .green, "\(state)")
            XCTAssertEqual(SessionStatePresentation.glyph(for: state), glyph, "\(state)")
            XCTAssertEqual(SessionStatePresentation.caption(for: state), caption, "\(state)")
            XCTAssertFalse(SessionStatePresentation.isRing(state), "\(state)")
            XCTAssertTrue(SessionStatePresentation.pulses(state), "\(state)")
        }
        let closed = State(kind: .background, live: false, backgroundAgents: 2)
        XCTAssertTrue(SessionStatePresentation.isRing(closed), "not live: a ring")
        XCTAssertFalse(SessionStatePresentation.pulses(closed), "a ring never pulses")
    }

    func testOnlyALiveBackgroundPulses() {
        let kinds: [State.Kind] = [
            .notStarted, .running, .working, .waitingOnAsk, .needsApproval, .finished, .stopped, .failed, .background
        ]
        for kind in kinds {
            for live in [true, false] {
                XCTAssertEqual(SessionStatePresentation.pulses(State(kind: kind, live: live)),
                               kind == .background && live, "\(kind) live=\(live)")
            }
        }
    }
}
