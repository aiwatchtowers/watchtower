import XCTest
import WatchtowerCore

final class SessionAgentNoticePolicyTests: XCTestCase {
    private func agentStatus(
        _ id: Int64,
        _ state: SessionSwitcherPresentation.State,
        at: String?,
        workbench: Int64? = 7,
        name: String? = "acme",
        title: String = "Release work"
    ) -> SessionAgentStatus {
        SessionAgentStatus(sessionID: id, workbenchID: workbench, workbenchName: name, title: title, state: state, at: at)
    }

    private func statusMap(_ statuses: SessionAgentStatus...) -> [Int64: SessionAgentStatus] {
        Dictionary(uniqueKeysWithValues: statuses.map { ($0.sessionID, $0) })
    }

    private func postedNotices(_ actions: [SessionAgentNoticePolicy.Action]) -> [SessionAgentNoticePolicy.Notice] {
        actions.compactMap { if case let .post(notice) = $0 { notice } else { nil } }
    }

    /// PROJ-11: each transition into waiting or approval is announced once;
    /// repeated polls of the same stamp stay silent.
    func testProj11_OneNoticePerTransition() {
        var policy = SessionAgentNoticePolicy()
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .working, at: "t1")), canPost: true), [])
        let first = policy.update(statusMap(agentStatus(1, .waitingForOwner, at: "t2")), canPost: true)
        XCTAssertEqual(first, [.post(.init(sessionID: 1, workbenchID: 7, title: "Release work is waiting for you",
                                           body: "acme"))])
        XCTAssertEqual(first.first.flatMap { postedNotices([$0]).first?.identifier }, "workbench-session-1")
        for _ in 0..<3 {
            XCTAssertEqual(policy.update(statusMap(agentStatus(1, .waitingForOwner, at: "t2")), canPost: true), [],
                           "a repeat poll of the same transition is silent")
        }
        let approval = policy.update(statusMap(agentStatus(1, .needsApproval, at: "t3")), canPost: true)
        XCTAssertEqual(postedNotices(approval).map(\.title), ["Release work needs approval"],
                       "waiting → approval is a new transition")
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .needsApproval, at: "t3")), canPost: true), [])
    }

    func testBackToWorkingWithdrawsAndANextWaitNotifiesAgain() {
        var policy = SessionAgentNoticePolicy()
        _ = policy.update(statusMap(agentStatus(1, .waitingForOwner, at: "t1")), canPost: true)
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .working, at: "t2")), canPost: true),
                       [.withdraw(identifier: "workbench-session-1")])
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .working, at: "t2")), canPost: true), [], "withdrawn once")
        XCTAssertEqual(postedNotices(policy.update(statusMap(agentStatus(1, .waitingForOwner, at: "t3")), canPost: true)).count, 1)
    }

    func testNotLiveWithdraws() {
        var policy = SessionAgentNoticePolicy()
        _ = policy.update(statusMap(agentStatus(1, .needsApproval, at: "t1"), agentStatus(2, .working, at: "t1")), canPost: true)
        XCTAssertEqual(policy.update(statusMap(agentStatus(2, .working, at: "t1")), canPost: true),
                       [.withdraw(identifier: "workbench-session-1")])
        XCTAssertEqual(policy.update([:], canPost: true), [], "a working session leaves nothing to withdraw")
    }

    func testFirstSightOfASessionAlreadyWaitingNotifies() {
        var policy = SessionAgentNoticePolicy()
        let actions = policy.update(statusMap(agentStatus(4, .waitingForOwner, at: "t9", title: "Docs")), canPost: true)
        XCTAssertEqual(postedNotices(actions).map(\.title), ["Docs is waiting for you"])
    }

    func testATransitionSeenWhilePostingIsBlockedIsNotReplayed() {
        var policy = SessionAgentNoticePolicy()
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .waitingForOwner, at: "t1")), canPost: false), [])
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .waitingForOwner, at: "t1")), canPost: true), [],
                       "the app deactivating later does not replay it")
        XCTAssertEqual(postedNotices(policy.update(statusMap(agentStatus(1, .needsApproval, at: "t2")), canPost: true)).count, 1)
    }

    func testStandaloneOrUnknownWorkbenchNeverNotifies() {
        var policy = SessionAgentNoticePolicy()
        let actions = policy.update(statusMap(
            agentStatus(1, .waitingForOwner, at: "t1", workbench: nil, name: nil),
            agentStatus(2, .needsApproval, at: "t1", workbench: 9, name: nil)
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
        XCTAssertEqual(policy.update(statusMap(agentStatus(1, .running, at: nil)), canPost: true), [])
    }
}
