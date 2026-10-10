import XCTest
import WatchtowerCore

final class SessionAgentStatusTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_790_000_000)
    /// The read's clock: a minute into the run.
    private var readAt: Date { started.addingTimeInterval(60) }

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
        openAsks: Int = 0,
        background: Int? = nil,
        backgroundAt: String? = nil
    ) -> SessionAgentStateRow {
        SessionAgentStateRow(id: 1, projectID: 7, title: "s", agentState: stored, agentStateAt: at, workbenchName: "acme",
                             finishedAt: finishedAt, agentFailedAt: failedAt, agentError: error, openAsks: openAsks,
                             agentBackground: background, agentBackgroundAt: backgroundAt)
    }

    private func effective(
        _ stored: SessionAgentState?, at: String?, startedAt: Date?, live: Bool = true
    ) -> SessionSwitcherPresentation.State {
        SessionAgentStatus.effective(row: row(stored?.rawValue, at: at), live: live, startedAt: startedAt, now: readAt)
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
        XCTAssertEqual(SessionAgentStatus.effective(row: previousError, live: true, startedAt: started, now: readAt),
                       .live(.running),
                       "an error of the earlier run is not shown")
        XCTAssertEqual(SessionAgentStatus.effective(row: previousError, live: false, startedAt: started, now: readAt),
                       .notStarted)
        let previousBackground = row("waiting", at: stamp(-1), background: 2, backgroundAt: stamp(-0.5))
        XCTAssertEqual(SessionAgentStatus.effective(row: previousBackground, live: true, startedAt: started, now: readAt),
                       .live(.running), "background agents of the earlier run are not shown")
        XCTAssertEqual(SessionAgentStatus.effective(row: previousBackground, live: false, startedAt: started, now: readAt),
                       .notStarted)
    }

    /// PROJ-11 (amended 2026-10-03, #411): §4b's order, the first match
    /// winning — approval > error > working > background > finished > open
    /// ask > stopped > running > not started. Finished and open asks are not
    /// run-scoped; the hook states, background among them, are.
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
            ("approval beats background agents",
             row("approval", at: now, background: 2, backgroundAt: now), true, .live(.needsApproval)),
            ("error beats background agents",
             row("waiting", at: now, failedAt: now, error: "rate_limit", background: 2, backgroundAt: now), true,
             .live(.failed, error: "rate_limit")),
            ("working beats background agents",
             row("working", at: now, background: 1, backgroundAt: now), true, .live(.working)),
            ("background beats finished",
             row("waiting", at: now, finishedAt: done, background: 2, backgroundAt: now), true,
             .live(.background, backgroundAgents: 2)),
            ("background beats an open ask",
             row("waiting", at: now, openAsks: 1, background: 1, backgroundAt: now), true,
             .live(.background, openAsks: 1, backgroundAgents: 1)),
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
            ("not live + a previous run's working", row("working", at: old), false, .notStarted),
            ("not live + background agents: never background",
             row("waiting", at: now, background: 2, backgroundAt: now), false, .notStarted),
            ("not live + background agents + finished: a ring",
             row("waiting", at: now, finishedAt: done, background: 2, backgroundAt: now), false,
             State(kind: .finished, live: false))
        ]
        for (name, input, live, expected) in cases {
            XCTAssertEqual(SessionAgentStatus.effective(row: input, live: live, startedAt: started, now: readAt),
                           expected, name)
        }
        let kinds = Set(cases.map(\.3.kind))
        XCTAssertEqual(kinds.count, 9, "every §4b kind is covered")
    }

    /// PROJ-11 (#411, ruling F3): error outranks background on the row shape
    /// Go actually stores (`TestProj11_StopOverWaitingWithAnotherCountWrites`):
    /// a StopFailure at t0, then a counted Stop at t1 keeps the error and
    /// moves both agent_state_at and agent_failed_at to t1, stamping the
    /// count at t1; then an idle notice at t2 drops the count and moves both
    /// again.
    func testProj11_ErrorOutranksACountedStopOnGosRowShape() {
        let afterCountedStop = row("waiting", at: stamp(2), failedAt: stamp(2), error: "rate_limit",
                                   background: 2, backgroundAt: stamp(2))
        XCTAssertEqual(SessionAgentStatus.effective(row: afterCountedStop, live: true, startedAt: started, now: readAt),
                       .live(.failed, error: "rate_limit"), "a counted Stop over a failed waiting")
        let afterIdleNotice = row("waiting", at: stamp(3), failedAt: stamp(3), error: "rate_limit")
        XCTAssertEqual(SessionAgentStatus.effective(row: afterIdleNotice, live: true, startedAt: started, now: readAt),
                       .live(.failed, error: "rate_limit"), "an idle notice after it")
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
                                                 startedAt: started, now: readAt)
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
            rows, liveIDs: [1, 2, 4], startedAt: [1: started, 2: started, 4: started], now: readAt
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

    /// Board #396 (PROJ-12): the SessionStart hook's mark — no state,
    /// stamped this run — says the hooks report this run: the dot stays
    /// plain running, no turn is over (`isAtPrompt` keeps its rule), and an
    /// answer may get its Return. An earlier run's mark, a row with no
    /// stamp, an unknown stored value or a session that is not live vouch
    /// for nothing.
    func testTheRunsMarkSaysTheHooksReportThisRun() {
        func resolvedMarkStatus(_ stored: String?, at: String?, live: Bool = true) -> SessionAgentStatus? {
            SessionAgentStatus.resolve(
                [row(stored, at: at)], liveIDs: live ? [1] : [], startedAt: [1: started], now: readAt
            )[1]
        }
        let marked = resolvedMarkStatus(nil, at: stamp(1))
        XCTAssertEqual(marked?.state, .live(.running))
        XCTAssertNil(marked?.at, "no hook state")
        XCTAssertTrue(marked?.runMarked == true)
        XCTAssertTrue(marked?.hooksReported == true)
        XCTAssertFalse(marked?.isAtPrompt == true, "a hand-off still waits for a turn end")
        XCTAssertTrue(resolvedMarkStatus("waiting", at: stamp(1))?.hooksReported == true, "a hook state reports too")
        XCTAssertFalse(resolvedMarkStatus("waiting", at: stamp(1))?.runMarked == true)
        XCTAssertFalse(marked?.isTrusted(startedAt: started) == true, "a mark has no stamp to hold for a run")

        for (stored, at, live, name) in [
            (nil, stamp(-1), true, "an earlier run's mark"),
            (nil, nil, true, "no stamp: cleared without the state hooks"),
            ("idle", stamp(1), true, "an unknown stored value"),
            ("waiting", stamp(-1), true, "an earlier run's state"),
            (nil, stamp(1), false, "not live")
        ] as [(String?, String?, Bool, String)] {
            let status = resolvedMarkStatus(stored, at: at, live: live)
            XCTAssertFalse(status?.hooksReported == true, name)
            XCTAssertFalse(status?.runMarked == true, name)
        }
    }

    func testAtPromptOnlyAfterATurnOfThisRun() {
        func status(_ state: SessionSwitcherPresentation.State, at: String?) -> SessionAgentStatus {
            SessionAgentStatus(sessionID: 1, workbenchID: 7, workbenchName: "acme", title: "s", state: state, at: at)
        }
        for kind: SessionSwitcherPresentation.State.Kind in [.stopped, .failed, .finished, .waitingOnAsk, .background] {
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
        let state = SessionAgentStatus.effective(row: waiting, live: false, startedAt: started, now: readAt)
        XCTAssertEqual(state, SessionSwitcherPresentation.State(kind: .waitingOnAsk, live: false, openAsks: 2, oldestAskID: 12))
        XCTAssertEqual(SessionStatePresentation.caption(for: state), "Waiting for you · ask #12 · 2 asks")
        XCTAssertEqual(SessionAgentStatus.resolve([waiting], liveIDs: [], startedAt: [:], now: readAt)[1]?.finishSummary, "Shipped")

        var stale = row(nil, at: nil)
        stale.oldestOpenAskID = 12
        XCTAssertNil(SessionAgentStatus.effective(row: stale, live: false, startedAt: started, now: readAt).oldestAskID,
                     "no open ask, no ask to name")
    }

    // MARK: - Background agents (#411)

    private func background(
        count: Int?, reportedAt: String?, now: Date? = nil, openAsks: Int = 0, finishedAt: String? = nil
    ) -> SessionSwitcherPresentation.State {
        let input = row("waiting", at: stamp(1), finishedAt: finishedAt, openAsks: openAsks,
                        background: count, backgroundAt: reportedAt)
        return SessionAgentStatus.effective(row: input, live: true, startedAt: started, now: now ?? readAt)
    }

    /// PROJ-11 (#411): a turn end with background agents still running is
    /// not Stopped — the main agent waits for them.
    func testProj11_BackgroundAgentsAreNotStopped() {
        let state = background(count: 2, reportedAt: stamp(2))
        XCTAssertEqual(state, .live(.background, backgroundAgents: 2))
        XCTAssertEqual(state.kind, .background)
        XCTAssertEqual(state.backgroundAgents, 2)
        XCTAssertTrue(state.live)
        XCTAssertEqual(effective(.waiting, at: stamp(1), startedAt: started).backgroundAgents, 0,
                       "no count shown outside background")
    }

    /// PROJ-11 (#411): an open ask does not turn a session with background
    /// agents into Waiting for you; the asks are carried for the caption.
    func testProj11_BackgroundWithAsksIsNotWaitingOnAsk() {
        var input = row("waiting", at: stamp(1), openAsks: 1, background: 2, backgroundAt: stamp(2))
        input.oldestOpenAskID = 12
        let state = SessionAgentStatus.effective(row: input, live: true, startedAt: started, now: readAt)
        XCTAssertEqual(state, SessionSwitcherPresentation.State(
            kind: .background, live: true, openAsks: 1, oldestAskID: 12, backgroundAgents: 2
        ))
    }

    /// PROJ-11 (#411): a count lowered to zero keeps the session in
    /// background for the grace only (the main agent is about to wake);
    /// after it the row is what it would be without the count.
    func testProj11_BackgroundEndsOnGrace() {
        let reported = started.addingTimeInterval(2)
        let inGrace = reported.addingTimeInterval(119)
        let afterGrace = reported.addingTimeInterval(121)
        XCTAssertEqual(background(count: 0, reportedAt: stamp(2), now: inGrace), .live(.background))
        XCTAssertEqual(background(count: 0, reportedAt: stamp(2), now: afterGrace), .live(.stopped))
        XCTAssertEqual(background(count: 0, reportedAt: stamp(2), now: afterGrace, openAsks: 1),
                       .live(.waitingOnAsk, openAsks: 1))
        XCTAssertEqual(background(count: 0, reportedAt: stamp(2), now: afterGrace, finishedAt: stamp(1)),
                       .live(.finished))
        XCTAssertEqual(background(count: 3, reportedAt: stamp(2), now: reported.addingTimeInterval(3600)),
                       .live(.background, backgroundAgents: 3), "a count above zero never ends on the Desktop's clock")
    }

    /// PROJ-11 (#411): an unreadable, missing or future report stamp, or no
    /// count, is no background.
    func testProj11_UnreadableOrFutureBackgroundStampIsNotBackground() {
        XCTAssertEqual(background(count: 2, reportedAt: "garbage"), .live(.stopped), "unreadable")
        XCTAssertEqual(background(count: 2, reportedAt: "2026-10-03 12:34:56"), .live(.stopped), "not the stamp layout")
        XCTAssertEqual(background(count: 2, reportedAt: stamp(60 + 600)), .live(.stopped), "10 min in the future")
        XCTAssertEqual(background(count: 2, reportedAt: nil), .live(.stopped), "no report stamp")
        XCTAssertEqual(background(count: nil, reportedAt: stamp(2)), .live(.stopped), "no count")
    }

    /// The main agent of a background session sits at its prompt: hand-offs
    /// and an answer's Return treat it like Stopped.
    func testProj11_BackgroundIsAtPrompt() throws {
        let input = row("waiting", at: stamp(1), background: 1, backgroundAt: stamp(2))
        let status = try XCTUnwrap(
            SessionAgentStatus.resolve([input], liveIDs: [1], startedAt: [1: started], now: readAt)[1]
        )
        XCTAssertEqual(status.state.kind, .background)
        XCTAssertEqual(status.at, stamp(1))
        XCTAssertTrue(status.isAtPrompt)
        XCTAssertTrue(status.hooksReported)
        XCTAssertTrue(status.isTrusted(startedAt: started))
        XCTAssertFalse(status.isTrusted(startedAt: started.addingTimeInterval(10)), "a later run")
    }

    /// The one staleness seam: a future report is over, a count above zero
    /// runs, zero runs for the grace only.
    func testBackgroundPolicyVerdicts() {
        let policy = SessionBackgroundPolicy.current
        let report = started
        XCTAssertEqual(SessionBackgroundPolicy.grace, 120)
        XCTAssertEqual(policy.verdict(count: 1, lastReport: report, now: report.addingTimeInterval(36_000)), .running)
        XCTAssertEqual(policy.verdict(count: 0, lastReport: report, now: report), .running)
        XCTAssertEqual(policy.verdict(count: 0, lastReport: report, now: report.addingTimeInterval(119.9)), .running)
        XCTAssertEqual(policy.verdict(count: 0, lastReport: report, now: report.addingTimeInterval(120)), .over)
        XCTAssertEqual(policy.verdict(count: 2, lastReport: report.addingTimeInterval(1), now: report), .over,
                       "a report from the future")
    }

    /// §10: a count above zero is probed once its report is 30 minutes old;
    /// zero, a younger report or a report from the future is not.
    func testNeedsProbeTable() {
        let policy = SessionBackgroundPolicy.current
        let report = started
        XCTAssertEqual(SessionBackgroundPolicy.staleAfter, 30 * 60)
        XCTAssertFalse(policy.needsProbe(count: 2, lastReport: report, now: report.addingTimeInterval(29 * 60 + 59)))
        XCTAssertTrue(policy.needsProbe(count: 2, lastReport: report, now: report.addingTimeInterval(30 * 60)))
        XCTAssertTrue(policy.needsProbe(count: 1, lastReport: report, now: report.addingTimeInterval(36_000)))
        XCTAssertFalse(policy.needsProbe(count: 0, lastReport: report, now: report.addingTimeInterval(36_000)),
                       "a count of zero ends on the grace, not on a probe")
        XCTAssertFalse(policy.needsProbe(count: 2, lastReport: report.addingTimeInterval(60), now: report),
                       "a report from the future")
    }

    /// PROJ-11 (#411, §10 F24): a count shown over after failed probes reads
    /// as what the row would be without it — Stopped, or its ask — and only
    /// for the sessions named.
    func testProj11_DisplayOverEndsTheCountWithoutAWrite() {
        let input = row("waiting", at: stamp(1), background: 2, backgroundAt: stamp(2))
        let late = started.addingTimeInterval(3600)
        XCTAssertEqual(SessionAgentStatus.effective(row: input, live: true, startedAt: started, now: late,
                                                    displayOver: true), .live(.stopped))
        var asking = input
        asking.openAsks = 1
        XCTAssertEqual(SessionAgentStatus.effective(row: asking, live: true, startedAt: started, now: late,
                                                    displayOver: true), .live(.waitingOnAsk, openAsks: 1))
        var other = input
        other.id = 2
        let statuses = SessionAgentStatus.resolve([input, other], liveIDs: [1, 2], startedAt: [1: started, 2: started],
                                                  now: late, displayOver: [1])
        XCTAssertEqual(statuses[1]?.state, .live(.stopped))
        XCTAssertEqual(statuses[1]?.at, stamp(1), "the stop it shows is the background Stop's")
        XCTAssertEqual(statuses[2]?.state, .live(.background, backgroundAgents: 2))
    }
}
