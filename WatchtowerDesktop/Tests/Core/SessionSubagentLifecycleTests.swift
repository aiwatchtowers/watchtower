import XCTest
@testable import WatchtowerCore

final class SessionSubagentLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNestedCompletionOverridesInitiallyRunningMarkerAndFreshResumeRestarts() {
        let completed = SessionFeedLive(observedAt: now, turnActive: false)
        XCTAssertEqual(SessionSubagentLifecycle.status(parentStatus: "running", snapshot: completed, error: nil, now: now), "finished")
        var resumed = completed
        resumed.turnActive = true
        XCTAssertEqual(SessionSubagentLifecycle.status(parentStatus: "finished", snapshot: resumed, error: nil, now: now), "running")
        XCTAssertEqual(SessionSubagentLifecycle.status(parentStatus: "running", snapshot: completed, error: nil, now: now + 11), "finished")
        XCTAssertEqual(SessionSubagentLifecycle.status(parentStatus: "running", snapshot: completed, error: "read failed", now: now), "finished")
    }

    func testBackgroundChildrenKeepACompletedMainTurnWorking() {
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "running"))
        let background = SessionFeedLive(observedAt: now, turnActive: false, agents: [child])
        XCTAssertEqual(SessionSubagentLifecycle.status(parentStatus: "finished", snapshot: background, error: nil, now: now), "running")
        var unresolved = background
        unresolved.agents = []
        unresolved.agentsState = "unknown"
        XCTAssertEqual(SessionSubagentLifecycle.status(parentStatus: "running", snapshot: unresolved, error: nil, now: now), "unknown")
    }
    func testParentResumeRestartsButOwnCompletionDoesNotChangeFollowKey() {
        let retry = UUID()
        let initial = SessionSubagentFollowKey(follow: "root-working", retry: retry, parentStatus: "running")
        let ownCompleted = SessionSubagentFollowKey(follow: "root-working", retry: retry, parentStatus: "running")
        XCTAssertEqual(initial, ownCompleted)
        let parentFinished = SessionSubagentFollowKey(follow: "root-working", retry: retry, parentStatus: "finished")
        XCTAssertNotEqual(initial, parentFinished)
        let parentResumed = SessionSubagentFollowKey(follow: "root-working", retry: retry, parentStatus: "running")
        XCTAssertNotEqual(parentFinished, parentResumed)
        let active = SessionFeedLive(observedAt: now, turnActive: true)
        XCTAssertEqual(SessionSubagentLifecycle.status(parentStatus: "running", snapshot: active, error: nil, now: now + 11), "running")
    }

}
