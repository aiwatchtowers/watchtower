import XCTest
@testable import WatchtowerCore

/// One candidate per stop of work (spec 2026-10-25-mobile-workbench-remote §5.2).
final class WorkAlertPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        _ kind: SessionSwitcherPresentation.State.Kind,
        id: Int64 = 7,
        heldFor seconds: TimeInterval? = 60,
        openAsks: Int = 0,
        pendingRequest: Bool = false
    ) -> WorkAlertPolicy.SessionInput {
        .init(
            id: id, workbenchID: 1, title: "Release work", kind: kind, stateAt: seconds.map { now.addingTimeInterval(-$0) },
            openAsks: openAsks, hasPendingRequest: pendingRequest
        )
    }

    private func ask(id: Int64 = 3, session: Int64? = 7, kind: String = "question") -> WorkAlertPolicy.AskInput {
        .init(id: id, workbenchID: 1, sessionID: session, title: "Which way?", kind: kind, createdAt: now.addingTimeInterval(-5))
    }

    private func request(id: Int64 = 5, session: Int64 = 7) -> WorkAlertPolicy.RequestInput {
        .init(id: id, sessionID: session, workbenchID: 1, toolName: "Bash", createdAt: now.addingTimeInterval(-5))
    }

    private func candidates(
        asks: [WorkAlertPolicy.AskInput] = [],
        requests: [WorkAlertPolicy.RequestInput] = [],
        sessions: [WorkAlertPolicy.SessionInput] = []
    ) -> [WorkAlertPolicy.Candidate] {
        WorkAlertPolicy.candidates(asks: asks, requests: requests, sessions: sessions, now: now)
    }

    func testAnOpenAskIsACandidateWithTheSessionsTitle() {
        let result = candidates(asks: [ask()], sessions: [session(.waitingOnAsk, openAsks: 1)])

        XCTAssertEqual(result, [.init(
            key: "ask-3", event: .ask, workbenchID: 1, sessionID: 7, askID: 3, requestID: nil,
            startedAt: now.addingTimeInterval(-5), title: "Release work", body: "Which way?"
        )])
    }

    func testAWorkbenchAskHasNoSessionTitle() {
        XCTAssertEqual(candidates(asks: [ask(session: nil)]).map(\.title), [""])
    }

    func testAWaitingOnAskSessionPushesOnlyTheAsk() {
        let result = candidates(asks: [ask()], sessions: [session(.waitingOnAsk, openAsks: 1)])
        XCTAssertEqual(result.map(\.event), [.ask])
    }

    func testReadyToCheckPushesAsItsAsk() {
        let result = candidates(asks: [ask(kind: "check")], sessions: [session(.readyToCheck, openAsks: 1)])
        XCTAssertEqual(result.map(\.key), ["ask-3"])
    }

    func testNeedsApprovalPushesOnlyTheRequest() {
        let result = candidates(requests: [request()], sessions: [session(.needsApproval, pendingRequest: true)])

        XCTAssertEqual(result.map(\.event), [.permission])
        XCTAssertEqual(result.first?.key, "perm-5")
        XCTAssertEqual(result.first?.body, "Needs approval: Bash")
        XCTAssertEqual(result.first?.requestID, 5)
    }

    func testAStopUnder20sDoesNotPush() {
        XCTAssertEqual(candidates(sessions: [session(.stopped, heldFor: 19.9)]), [])
    }

    func testAStopHeld20sPushes() {
        let stateAt = now.addingTimeInterval(-20)
        let result = candidates(sessions: [session(.stopped, heldFor: 20)])

        XCTAssertEqual(result, [.init(
            key: "stop-7-\(Int64(stateAt.timeIntervalSince1970 * 1000))", event: .sessionStopped, workbenchID: 1, sessionID: 7,
            askID: nil, requestID: nil, startedAt: stateAt, title: "Release work", body: "Waiting for you"
        )])
    }

    func testFinishedSaysFinished() {
        let result = candidates(sessions: [session(.finished)])
        XCTAssertEqual(result.map(\.event), [.sessionStopped])
        XCTAssertEqual(result.map(\.body), ["Finished"])
    }

    func testFailedPushesSessionFailed() {
        let result = candidates(sessions: [session(.failed)])
        XCTAssertEqual(result.map(\.event), [.sessionFailed])
        XCTAssertEqual(result.map(\.body), ["Failed"])
    }

    func testAStopWithAnOpenAskOrPendingRequestPushesOnlyThatOne() {
        XCTAssertEqual(candidates(asks: [ask()], sessions: [session(.finished, openAsks: 1)]).map(\.event), [.ask])
        XCTAssertEqual(candidates(requests: [request()], sessions: [session(.stopped, pendingRequest: true)]).map(\.event), [.permission])
    }

    /// The stop an ask or a request stands for: when that one resolves and the session still reads stopped at the
    /// same moment, the stop must not push a second time.
    func testAStopWithAnOpenAskOrPendingRequestIsCovered() {
        let held = now.addingTimeInterval(-60)
        let key = WorkAlertPolicy.stopKey(session: 7, stateAt: held)
        XCTAssertEqual(WorkAlertPolicy.coveredStopKeys(sessions: [session(.readyToCheck, openAsks: 1)]), [key])
        XCTAssertEqual(WorkAlertPolicy.coveredStopKeys(sessions: [session(.needsApproval, pendingRequest: true)]), [key])
        XCTAssertEqual(WorkAlertPolicy.coveredStopKeys(sessions: [session(.stopped), session(.finished, heldFor: nil, openAsks: 1)]), [])
    }

    /// Spec §4 (no push storm): an ask or a request left open pushes on departure whatever its age; a stop only when
    /// it began within `departureWindow` before the owner went away (a stop while away began after it).
    func testOnlyARecentStopPushesOnDeparture() {
        let away = now
        let stop = { (age: TimeInterval) in
            WorkAlertPolicy.Candidate(
                key: "stop", event: .sessionStopped, workbenchID: 1, sessionID: 7, askID: nil, requestID: nil,
                startedAt: away.addingTimeInterval(-age), title: "", body: "Finished"
            )
        }
        XCTAssertEqual(WorkAlertPolicy.departureWindow, 30 * 60)
        XCTAssertTrue(WorkAlertPolicy.pushesWhileAway(stop(29 * 60), awaySince: away))
        XCTAssertTrue(WorkAlertPolicy.pushesWhileAway(stop(30 * 60), awaySince: away))
        XCTAssertFalse(WorkAlertPolicy.pushesWhileAway(stop(31 * 60), awaySince: away))
        XCTAssertTrue(WorkAlertPolicy.pushesWhileAway(stop(-60), awaySince: away), "a stop while away")
        let old = WorkAlertPolicy.candidates(asks: [ask()], requests: [request()], sessions: [], now: now)
        XCTAssertTrue(old.allSatisfy { WorkAlertPolicy.pushesWhileAway($0, awaySince: now.addingTimeInterval(86_400)) })
    }

    /// An upgraded hub never alerts on stops and requests from before the work alerts existed; asks keep `enabled_at`.
    func testStopsAndRequestsCountFromTheWorkAlertsStart() {
        let start = now.addingTimeInterval(-10)
        let result = candidates(asks: [ask()], requests: [request()], sessions: [session(.finished, heldFor: 60)])
        let counted = result.filter {
            WorkAlertPolicy.counts($0, enabledAt: now.addingTimeInterval(-3600), workAlertsStartedAt: start)
        }
        XCTAssertEqual(counted.map(\.event), [.ask, .permission])
    }

    func testAnUndatedStopNeverPushes() {
        XCTAssertEqual(candidates(sessions: [session(.finished, heldFor: nil)]), [])
    }

    func testNoOtherKindYieldsASessionCandidate() {
        let quiet: [SessionSwitcherPresentation.State.Kind] = [
            .notStarted, .running, .working, .needsApproval, .waitingOnAsk, .background, .readyToCheck
        ]
        XCTAssertEqual(candidates(sessions: quiet.enumerated().map { session($1, id: Int64($0)) }), [])
    }

    /// The key is the Kit's `WorkAlertKey.stop`: whole milliseconds rounded to the nearest, so a stamp a hair under
    /// the millisecond in floating point keys the same on every pass.
    func testTheStopKeyIsExactMilliseconds() {
        XCTAssertEqual(
            WorkAlertPolicy.stopKey(session: 7, stateAt: Date(timeIntervalSince1970: 1_089_010_964.738)), "stop-7-1089010964738"
        )
    }
}
