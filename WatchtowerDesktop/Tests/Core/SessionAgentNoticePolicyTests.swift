import XCTest
import WatchtowerCore

final class SessionAgentNoticePolicyTests: XCTestCase {
    private func agentStatus(
        _ id: Int64,
        _ state: SessionSwitcherPresentation.State,
        at: String?,
        workbench: Int64? = 7,
        name: String? = "acme",
        title: String = "Release work",
        summary: String = ""
    ) -> SessionAgentStatus {
        SessionAgentStatus(sessionID: id, workbenchID: workbench, workbenchName: name, title: title, state: state, at: at,
                           finishSummary: summary)
    }

    private func statusMap(_ statuses: SessionAgentStatus...) -> [Int64: SessionAgentStatus] {
        Dictionary(uniqueKeysWithValues: statuses.map { ($0.sessionID, $0) })
    }

    private func postedNotices(_ actions: [SessionAgentNoticePolicy.Action]) -> [SessionAgentNoticePolicy.Notice] {
        actions.compactMap { if case let .post(notice) = $0 { notice } else { nil } }
    }

    /// PROJ-11: each turn end or approval of this run is announced once;
    /// repeated polls of the same stamp stay silent. A turn end without an
    /// ask is "stopped", never "waiting for you" (§4b).
    func testProj11_OneNoticePerTransition() {
        var policy = SessionAgentNoticePolicy()
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.working), at: "t1")), canPost: true), [])
        let first = policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t2")), canPost: true)
        XCTAssertEqual(first, [.post(.init(sessionID: 1, workbenchID: 7, title: "Release work stopped",
                                           body: "acme"))])
        XCTAssertEqual(first.first.flatMap { postedNotices([$0]).first?.identifier }, "workbench-session-1")
        for _ in 0..<3 {
            XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t2")), canPost: true), [],
                           "a repeat poll of the same transition is silent")
        }
        let approval = policy.update(statusMap(agentStatus(1, .live(.needsApproval), at: "t3")), canPost: true)
        XCTAssertEqual(postedNotices(approval).map(\.title), ["Release work needs approval"],
                       "waiting → approval is a new transition")
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.needsApproval), at: "t3")), canPost: true), [])
    }

    func testBackToWorkingWithdrawsAndANextWaitNotifiesAgain() {
        var policy = SessionAgentNoticePolicy()
        _ = policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t1")), canPost: true)
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.working), at: "t2")), canPost: true),
                       [.withdraw(identifier: "workbench-session-1")])
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.working), at: "t2")), canPost: true), [], "withdrawn once")
        XCTAssertEqual(postedNotices(policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t3")), canPost: true)).count, 1)
    }

    func testNotLiveWithdraws() {
        var policy = SessionAgentNoticePolicy()
        _ = policy.update(statusMap(agentStatus(1, .live(.needsApproval), at: "t1"), agentStatus(2, .live(.working), at: "t1")), canPost: true)
        XCTAssertEqual(policy.update(statusMap(agentStatus(2, .live(.working), at: "t1")), canPost: true),
                       [.withdraw(identifier: "workbench-session-1")])
        XCTAssertEqual(policy.update([:], canPost: true), [], "a working session leaves nothing to withdraw")
    }

    func testFirstSightOfASessionAlreadyWaitingNotifies() {
        var policy = SessionAgentNoticePolicy()
        let actions = policy.update(statusMap(agentStatus(4, .live(.stopped), at: "t9", title: "Docs")), canPost: true)
        XCTAssertEqual(postedNotices(actions).map(\.title), ["Docs stopped"])
    }

    func testATransitionSeenWhilePostingIsBlockedIsNotReplayed() {
        var policy = SessionAgentNoticePolicy()
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t1")), canPost: false), [])
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t1")), canPost: true), [],
                       "the app deactivating later does not replay it")
        XCTAssertEqual(postedNotices(policy.update(statusMap(agentStatus(1, .live(.needsApproval), at: "t2")), canPost: true)).count, 1)
    }

    func testStandaloneOrUnknownWorkbenchNeverNotifies() {
        var policy = SessionAgentNoticePolicy()
        let actions = policy.update(statusMap(
            agentStatus(1, .live(.stopped), at: "t1", workbench: nil, name: nil),
            agentStatus(2, .live(.needsApproval), at: "t1", workbench: 9, name: nil)
        ), canPost: true)
        XCTAssertEqual(actions, [])
    }

    func testLeftoverBannersAreOnlyOurSessionIdentifiers() {
        let delivered = [
            "workbench-session-12", "workbench-session-3", "workbench-session-", "workbench-session-x",
            "workbench-question-12", "meeting-reminder-1", "voice-label-12"
        ]
        XCTAssertEqual(SessionAgentNoticePolicy.noticeIdentifiers(in: delivered),
                       ["workbench-session-12", "workbench-session-3"])
        XCTAssertEqual(SessionAgentNoticePolicy.identifier(sessionID: 12), "workbench-session-12")
    }

    func testPlainRunningNeverNotifies() {
        var policy = SessionAgentNoticePolicy()
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.running), at: nil)), canPost: true), [])
    }

    func testAnErrorAndAFinishAreAnnouncedWithTheirBodies() {
        var policy = SessionAgentNoticePolicy()
        let failed = policy.update(statusMap(agentStatus(1, .live(.failed, error: "rate_limit"), at: "t1")), canPost: true)
        XCTAssertEqual(postedNotices(failed), [.init(sessionID: 1, workbenchID: 7, title: "Release work hit an error",
                                                     body: "Error: rate limit")])
        _ = policy.update(statusMap(agentStatus(1, .live(.working), at: "t2")), canPost: true)
        let finished = policy.update(statusMap(agentStatus(
            1, .live(.finished), at: "t3", summary: "  Shipped the parser.\nTests pass."
        )), canPost: true)
        XCTAssertEqual(postedNotices(finished).map(\.title), ["Release work finished"])
        XCTAssertEqual(postedNotices(finished).map(\.body), ["Shipped the parser."], "the summary's first line")
        XCTAssertEqual(postedNotices(finished).first?.identifier, "workbench-session-1")

        var unknown = SessionAgentNoticePolicy()
        XCTAssertEqual(postedNotices(unknown.update(statusMap(agentStatus(2, .live(.failed), at: "t1")), canPost: true))
            .map(\.body), ["Stopped on an error"])
    }

    func testAFinishWithOpenAsksSaysHowManyWait() {
        for (asks, body) in [(1, "1 ask waiting for you"), (3, "3 asks waiting for you")] {
            var policy = SessionAgentNoticePolicy()
            let actions = policy.update(statusMap(agentStatus(
                1, .live(.finished, openAsks: asks, oldestAskID: 12), at: "t1", summary: "Done"
            )), canPost: true)
            XCTAssertEqual(postedNotices(actions).map(\.body), [body])
        }
    }

    /// The ask itself was announced (`askOpened`): waiting on it, or working
    /// with it open, is no state notice — and leaves no banner behind.
    func testWaitingOnAnAskOrWorkingWithAsksPostsNoStateNotice() {
        var policy = SessionAgentNoticePolicy()
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.waitingOnAsk, openAsks: 1, oldestAskID: 4), at: "t1"),
                                               agentStatus(2, .live(.working, openAsks: 2, oldestAskID: 5), at: "t1")),
                                     canPost: true), [])
        _ = policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t2")), canPost: true)
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.waitingOnAsk, openAsks: 1), at: "t3")), canPost: true),
                       [.withdraw(identifier: "workbench-session-1")])
    }

    /// A closed session's finished or ask state is drawn as a ring, never
    /// announced; a session leaving the live set takes its banner away.
    func testANotLiveSessionIsNeverAnnouncedAndWithdraws() {
        var policy = SessionAgentNoticePolicy()
        let closed = SessionSwitcherPresentation.State(kind: .finished, live: false)
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, closed, at: nil, summary: "Done")), canPost: true), [])
        _ = policy.update(statusMap(agentStatus(2, .live(.finished), at: "t1", summary: "Done")), canPost: true)
        XCTAssertEqual(policy.update(statusMap(agentStatus(2, SessionSwitcherPresentation.State(kind: .finished, live: false),
                                                           at: nil, summary: "Done")), canPost: true),
                       [.withdraw(identifier: "workbench-session-2")])
    }

    /// A finished session restarted reads finished with no hook of the new
    /// run: no new transition.
    func testAFinishWithoutAHookOfThisRunIsNotAnnounced() {
        var policy = SessionAgentNoticePolicy()
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .live(.finished), at: nil, summary: "Done")), canPost: true), [])
    }

    /// The answer to the session's last ask turns "waiting on an ask" into
    /// "stopped" at the same stamp: a new transition.
    func testAnAnsweredAskAtThePromptIsANewTransition() {
        var policy = SessionAgentNoticePolicy()
        _ = policy.update(statusMap(agentStatus(1, .live(.waitingOnAsk, openAsks: 1), at: "t1")), canPost: true)
        XCTAssertEqual(postedNotices(policy.update(statusMap(agentStatus(1, .live(.stopped), at: "t1")), canPost: true))
            .map(\.title), ["Release work stopped"])
    }
}
