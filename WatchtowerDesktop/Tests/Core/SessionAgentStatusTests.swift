import XCTest
import WatchtowerCore

final class SessionAgentStatusTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    private func row(
        _ stored: String?,
        at: String?,
        finishedAt: String? = nil,
        failedAt: String? = nil,
        error: String = "",
        openAsks: Int = 0
    ) -> SessionAgentStateRow {
        SessionAgentStateRow(id: 1, projectID: 7, title: "s", agentState: stored, agentStateAt: at, workbenchName: "acme",
                             finishedAt: finishedAt, agentFailedAt: failedAt, agentError: error, openAsks: openAsks)
    }

    private func effective(
        _ stored: SessionAgentState?, at: String?, startedAt: Date?, live: Bool = true
    ) -> SessionSwitcherPresentation.State {
        SessionAgentStatus.effective(row: row(stored?.rawValue, at: at), live: live, startedAt: startedAt)
    }

    /// PROJ-11: a state written during an earlier process run (before the
    /// current `startedAt`) never shows — Restart, relaunch or an app
    /// restart start at plain running until the new run's first hook.
    func testProj11_StateFromAnEarlierRunIsIgnored() {
        for stored in [SessionAgentState.working, .waiting, .approval] {
            XCTAssertEqual(effective(stored, at: stamp(-0.001), startedAt: started), .live(.running),
                           "\(stored) from the earlier run is not trusted")
            XCTAssertEqual(effective(stored, at: stamp(1), startedAt: started, live: false), .notStarted,
                           "\(stored) of a session that is not live is not trusted")
        }
        XCTAssertEqual(effective(.waiting, at: stamp(30), startedAt: nil), .live(.running),
                       "no known start time: nothing is trusted")
        XCTAssertEqual(effective(.waiting, at: "2026-10-03 12:34:56", startedAt: started), .live(.running),
                       "an unreadable stamp is not trusted")
        let previousError = row("waiting", at: stamp(-1), failedAt: stamp(-1), error: "rate_limit")
        XCTAssertEqual(SessionAgentStatus.effective(row: previousError, live: true, startedAt: started), .live(.running),
                       "an error of the earlier run is not shown")
        XCTAssertEqual(SessionAgentStatus.effective(row: previousError, live: false, startedAt: started), .notStarted)
    }

    /// PROJ-11 (amended 2026-10-03): §4b's order, the first match winning —
    /// approval > error > working > finished > open ask > stopped > running
    /// > not started. Finished and open asks are not run-scoped; the hook
    /// states are.
    func testProj11_StateOrder() {
        let now = stamp(5)
        let old = stamp(-5)
        let done = stamp(4)
        typealias State = SessionSwitcherPresentation.State
        let cases: [(String, SessionAgentStateRow, Bool, State)] = [
            ("approval beats everything",
             row("approval", at: now, finishedAt: done, openAsks: 2), true, .live(.needsApproval, openAsks: 2)),
            ("error beats working, finished and asks",
             row("waiting", at: now, finishedAt: done, failedAt: now, error: "rate_limit", openAsks: 1), true,
             .live(.failed, openAsks: 1, error: "rate_limit")),
            ("an unknown error type", row("waiting", at: now, failedAt: now), true, .live(.failed)),
            ("working beats an open ask", row("working", at: now, openAsks: 1), true, .live(.working, openAsks: 1)),
            ("finished beats an open ask and a turn end",
             row("waiting", at: now, finishedAt: done, openAsks: 1), true, .live(.finished, openAsks: 1)),
            ("an open ask beats a turn end", row("waiting", at: now, openAsks: 3), true, .live(.waitingOnAsk, openAsks: 3)),
            ("a turn end", row("waiting", at: now), true, .live(.stopped)),
            ("a failure flag of an older write is not this turn's error",
             row("waiting", at: now, failedAt: old, error: "rate_limit"), true, .live(.stopped)),
            ("nothing reported in this run", row(nil, at: nil), true, .live(.running)),
            ("not live + finished: a ring", row("waiting", at: old, finishedAt: old), false,
             State(kind: .finished, live: false)),
            ("not live + an open ask: a ring", row("waiting", at: old, openAsks: 1), false,
             State(kind: .waitingOnAsk, live: false, openAsks: 1)),
            ("not live + a previous run's error", row("waiting", at: old, failedAt: old, error: "x"), false, .notStarted),
            ("not live + a previous run's approval", row("approval", at: old), false, .notStarted),
            ("not live + a previous run's working", row("working", at: old), false, .notStarted)
        ]
        for (name, input, live, expected) in cases {
            XCTAssertEqual(SessionAgentStatus.effective(row: input, live: live, startedAt: started), expected, name)
        }
        let kinds = Set(cases.map(\.3.kind))
        XCTAssertEqual(kinds.count, 8, "every §4b kind is covered")
    }

    /// PROJ-11 (amended 2026-10-03): a stored `waiting` is a turn that is
    /// over — Stopped, grey — never "waiting for you"; only an open ask or a
    /// permission dialog turns a session to the owner.
    func testProj11_TurnEndWithoutAskIsStoppedNotWaiting() {
        let state = effective(.waiting, at: stamp(1), startedAt: started)
        XCTAssertEqual(state, .live(.stopped))
        XCTAssertEqual(SessionStatePresentation.color(for: state), .secondary)
        XCTAssertEqual(SessionStatePresentation.caption(for: state, oldestAskID: nil), "Stopped")
        let asked = SessionAgentStatus.effective(row: row("waiting", at: stamp(1), openAsks: 1), live: true,
                                                 startedAt: started)
        XCTAssertEqual(asked.kind, .waitingOnAsk)
        XCTAssertEqual(SessionStatePresentation.color(for: asked), .orange)
    }

    func testLiveStateOfThisRunIsShown() {
        XCTAssertEqual(effective(.working, at: stamp(1), startedAt: started), .live(.working))
        XCTAssertEqual(effective(.waiting, at: stamp(1), startedAt: started), .live(.stopped))
        XCTAssertEqual(effective(.approval, at: stamp(1), startedAt: started), .live(.needsApproval))
        XCTAssertEqual(effective(.waiting, at: stamp(0), startedAt: started), .live(.stopped),
                       "a state stamped at the start instant counts")
    }

    func testAStatusHoldsOnlyForTheRunItWasWrittenIn() {
        func status(_ at: String?) -> SessionAgentStatus {
            SessionAgentStatus(sessionID: 1, workbenchID: 2, workbenchName: "acme", title: "s",
                               state: .live(at == nil ? .running : .stopped), at: at)
        }
        XCTAssertTrue(status(stamp(1)).isTrusted(startedAt: started))
        XCTAssertFalse(status(stamp(1)).isTrusted(startedAt: started.addingTimeInterval(10)), "a later run")
        XCTAssertFalse(status(stamp(1)).isTrusted(startedAt: nil), "no known start")
        XCTAssertTrue(status(nil).isTrusted(startedAt: started.addingTimeInterval(10)), "plain running always holds")
    }

    func testNullStateIsPlainRunning() {
        XCTAssertEqual(effective(nil, at: nil, startedAt: started), .live(.running))
        XCTAssertEqual(effective(nil, at: stamp(5), startedAt: started), .live(.running))
    }

    func testStampParsesAsUTCWhateverTheProcessTimeZone() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let parsed = try XCTUnwrap(SessionAgentStatus.parseStamp("2026-10-03T12:34:56.789Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: parsed)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2026, 10, 3, 12, 34, 56])
        XCTAssertEqual(Double(parts.nanosecond ?? 0) / 1e6, 789, accuracy: 1)
        XCTAssertNil(SessionAgentStatus.parseStamp(""))
    }

    func testResolveDecidesLivenessAndKeepsOnlyTheTrustedStamp() {
        let rows = [
            SessionAgentStateRow(id: 1, projectID: 7, title: "One", agentState: "waiting",
                                 agentStateAt: stamp(2), workbenchName: "acme"),
            SessionAgentStateRow(id: 2, projectID: 7, title: "Two", agentState: "approval",
                                 agentStateAt: stamp(-2), workbenchName: "acme"),
            SessionAgentStateRow(id: 3, projectID: 7, title: "Three", agentState: "waiting",
                                 agentStateAt: stamp(2), workbenchName: "acme"),
            SessionAgentStateRow(id: 4, projectID: 7, title: "Four", agentState: "idle",
                                 agentStateAt: stamp(2), workbenchName: "acme"),
            SessionAgentStateRow(id: 5, projectID: 7, title: "Five", agentState: "waiting",
                                 agentStateAt: stamp(2), workbenchName: "acme", finishedAt: stamp(1))
        ]
        let statuses = SessionAgentStatus.resolve(
            rows, liveIDs: [1, 2, 4], startedAt: [1: started, 2: started, 4: started]
        )
        XCTAssertEqual(Set(statuses.keys), [1, 2, 3, 4, 5])
        XCTAssertEqual(statuses[1], SessionAgentStatus(
            sessionID: 1, workbenchID: 7, workbenchName: "acme", title: "One", state: .live(.stopped), at: stamp(2)
        ))
        XCTAssertTrue(statuses[1]?.isAtPrompt == true)
        XCTAssertEqual(statuses[2]?.state, .live(.running))
        XCTAssertNil(statuses[2]?.at, "an untrusted state carries no stamp")
        XCTAssertEqual(statuses[3]?.state, .notStarted, "a row that is not live trusts no hook state")
        XCTAssertNil(statuses[3]?.at)
        XCTAssertEqual(statuses[4]?.state, .live(.running), "an unknown stored value reads as no state")
        XCTAssertEqual(statuses[5]?.state, SessionSwitcherPresentation.State(kind: .finished, live: false))
        XCTAssertFalse(statuses[5]?.isAtPrompt == true, "a session that is not live is at no prompt")
    }

    func testAtPromptOnlyAfterATurnOfThisRun() {
        func status(_ state: SessionSwitcherPresentation.State, at: String?) -> SessionAgentStatus {
            SessionAgentStatus(sessionID: 1, workbenchID: 7, workbenchName: "acme", title: "s", state: state, at: at)
        }
        for kind: SessionSwitcherPresentation.State.Kind in [.stopped, .failed, .finished, .waitingOnAsk] {
            XCTAssertTrue(status(.live(kind), at: "t").isAtPrompt, "\(kind) over a turn end")
            XCTAssertFalse(status(.live(kind), at: nil).isAtPrompt, "\(kind) without a turn end of this run")
        }
        for kind: SessionSwitcherPresentation.State.Kind in [.running, .working, .needsApproval] {
            XCTAssertFalse(status(.live(kind), at: "t").isAtPrompt, "\(kind)")
        }
    }

    /// The waiting caption names the oldest open ask; a resolved status
    /// carries the summary a finished notice shows.
    func testTheOldestOpenAskAndTheSummaryAreCarried() {
        var waiting = row(nil, at: nil, openAsks: 2)
        waiting.oldestOpenAskID = 12
        waiting.finishSummary = "Shipped"
        let state = SessionAgentStatus.effective(row: waiting, live: false, startedAt: started)
        XCTAssertEqual(state, SessionSwitcherPresentation.State(kind: .waitingOnAsk, live: false, openAsks: 2, oldestAskID: 12))
        XCTAssertEqual(SessionStatePresentation.caption(for: state), "Waiting for you · ask #12 · 2 asks")
        XCTAssertEqual(SessionAgentStatus.resolve([waiting], liveIDs: [], startedAt: [:])[1]?.finishSummary, "Shipped")

        var stale = row(nil, at: nil)
        stale.oldestOpenAskID = 12
        XCTAssertNil(SessionAgentStatus.effective(row: stale, live: false, startedAt: started).oldestAskID,
                     "no open ask, no ask to name")
    }
}
