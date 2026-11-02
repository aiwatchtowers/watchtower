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
    func testParentIdentityChangesKeyButLifecycleDoesNotRestartTheObserver() {
        let retry = UUID()
        let initial = SessionSubagentFollowKey(follow: "root-working", retry: retry, parentToolUseID: "parent-a")
        let completed = SessionSubagentFollowKey(follow: "root-working", retry: retry, parentToolUseID: "parent-a")
        XCTAssertEqual(initial, completed)
        let differentParent = SessionSubagentFollowKey(follow: "root-working", retry: retry, parentToolUseID: "parent-b")
        XCTAssertNotEqual(initial, differentParent)
    }

    func testTheSameParentRunCannotRepeatedlyReopenCompletedHistory() {
        var observer = SessionSubagentObservation()
        let completed = SessionFeedLive(observedAt: now, turnActive: false)
        let entries = [SessionFeedEntry(id: "task", kind: "owner", at: now - 60)]
        XCTAssertEqual(observer.receiveOwn(snapshot: completed, entries: entries, error: nil, now: now), "finished")
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "running"), startedAt: now - 59)
        let parent = SessionFeedLive(observedAt: now, agents: [child])
        XCTAssertTrue(observer.receiveParent(parent, childID: "child", now: now))
        XCTAssertEqual(observer.receiveOwn(snapshot: completed, entries: entries, error: nil, now: now), "finished")
        XCTAssertFalse(observer.receiveParent(parent, childID: "child", now: now))
    }

}
