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
        let entries = [SessionFeedEntry(id: "report", kind: "agent", at: now - 58)]
        XCTAssertEqual(observer.receiveOwn(snapshot: completed, entries: entries, error: nil, now: now), "finished")
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "running"), startedAt: now - 59)
        let parent = SessionFeedLive(observedAt: now, agents: [child])
        XCTAssertFalse(observer.receiveParent(parent, childID: "child", now: now))
        XCTAssertEqual(observer.receiveOwn(snapshot: completed, entries: entries, error: nil, now: now), "finished")
        XCTAssertFalse(observer.receiveParent(parent, childID: "child", now: now))
    }

    func testPendingResumeRejectsOldCompletedClockAndLateEntryButAcceptsANewCompletedTurn() {
        var observer = SessionSubagentObservation()
        let completed = SessionFeedLive(observedAt: now - 2, turnAt: now - 60, turnActive: false)
        let oldEntries = [SessionFeedEntry(id: "old-report", kind: "agent", at: now - 10)]
        XCTAssertEqual(observer.receiveOwn(snapshot: completed, entries: oldEntries, error: nil, now: now), "finished")
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "finished"), startedAt: now - 60)
        var parent = SessionFeedLive(observedAt: now, agents: [child])
        XCTAssertFalse(observer.receiveParent(parent, childID: "child", now: now))
        parent.agents[0].ref.status = "running"
        parent.agents[0].startedAt = now - 4
        XCTAssertTrue(observer.receiveParent(parent, childID: "child", now: now))
        var old = completed
        old.observedAt = now - 1
        let late = oldEntries + [SessionFeedEntry(id: "late-old-report", kind: "agent", at: now - 3)]
        XCTAssertEqual(observer.receiveOwn(snapshot: old, entries: late, error: nil, now: now), "resuming")
        XCTAssertTrue(observer.awaitingResume); XCTAssertFalse(observer.finished)
        XCTAssertEqual(observer.receiveOwn(snapshot: nil, entries: [], error: "read failed", now: now), "unknown")
        XCTAssertTrue(observer.awaitingResume)
        let new = SessionFeedLive(observedAt: now, turnAt: now - 5, turnActive: false)
        let newEntries = [SessionFeedEntry(id: "new-report", kind: "agent", at: now - 1)]
        XCTAssertEqual(observer.receiveOwn(snapshot: new, entries: newEntries, error: nil, now: now), "finished")
        XCTAssertFalse(observer.awaitingResume); XCTAssertTrue(observer.finished)
        XCTAssertFalse(observer.receiveParent(parent, childID: "child", now: now), "same parent run must not reprobe settled history")
    }

    func testResumeCanAcknowledgeNewEntryEvidenceWhenTurnMarkersAreUnavailable() {
        var observer = SessionSubagentObservation()
        let old = SessionFeedLive(observedAt: now - 2, turnActive: false)
        let oldEntries = [SessionFeedEntry(id: "old", kind: "agent", at: now - 10)]
        XCTAssertEqual(observer.receiveOwn(snapshot: old, entries: oldEntries, error: nil, now: now), "finished")
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "finished"))
        var parent = SessionFeedLive(observedAt: now, agents: [child])
        XCTAssertFalse(observer.receiveParent(parent, childID: "child", now: now))
        parent.agents[0].ref.status = "running"
        XCTAssertTrue(observer.receiveParent(parent, childID: "child", now: now))
        let refreshed = SessionFeedLive(observedAt: now, turnActive: false)
        XCTAssertEqual(observer.receiveOwn(snapshot: refreshed, entries: oldEntries, error: nil, now: now), "resuming")
        let newEntries = oldEntries + [SessionFeedEntry(id: "new", kind: "agent", at: now - 1)]
        XCTAssertEqual(observer.receiveOwn(snapshot: refreshed, entries: newEntries, error: nil, now: now), "finished")
        XCTAssertFalse(observer.awaitingResume)
    }

    func testParentTerminalCannotCloseANewerOwnOrPendingResumeInterval() {
        var observer = SessionSubagentObservation()
        let old = SessionFeedLive(observedAt: now, turnAt: now - 60, turnActive: true)
        XCTAssertEqual(observer.receiveOwn(snapshot: old, entries: [], error: nil, now: now), "running")
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "finished"), startedAt: now - 60)
        let closed = SessionFeedLive(observedAt: now, agents: [child])
        XCTAssertFalse(observer.receiveParent(closed, childID: "child", now: now)); XCTAssertTrue(observer.finished)
        var resumed = closed
        resumed.agents[0].ref.status = "running"; resumed.agents[0].startedAt = now - 4
        XCTAssertTrue(observer.receiveParent(resumed, childID: "child", now: now))
        XCTAssertEqual(observer.receiveOwn(snapshot: old, entries: [], error: nil, now: now), "resuming")
        XCTAssertFalse(observer.receiveParent(closed, childID: "child", now: now)); XCTAssertFalse(observer.finished)
        let new = SessionFeedLive(observedAt: now, turnAt: now - 5, turnActive: true)
        XCTAssertEqual(observer.receiveOwn(snapshot: new, entries: [], error: nil, now: now), "running")
        XCTAssertFalse(observer.receiveParent(closed, childID: "child", now: now)); XCTAssertFalse(observer.finished)
    }
    func testRepeatedOldParentTerminalCannotUndoANewerOwnTurnObservedOnRefresh() {
        var observer = SessionSubagentObservation()
        let old = SessionFeedLive(observedAt: now, turnAt: now - 60, turnActive: true)
        _ = observer.receiveOwn(snapshot: old, entries: [], error: nil, now: now)
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "finished"), startedAt: now - 60)
        let closed = SessionFeedLive(observedAt: now, agents: [child])
        _ = observer.receiveParent(closed, childID: "child", now: now)
        let new = SessionFeedLive(observedAt: now, turnAt: now - 5, turnActive: true)
        XCTAssertEqual(observer.receiveOwn(snapshot: new, entries: [], error: nil, now: now), "running")
        _ = observer.receiveParent(closed, childID: "child", now: now)
        XCTAssertFalse(observer.finished)
        var currentClosed = closed
        currentClosed.agents[0].startedAt = now - 4
        _ = observer.receiveParent(currentClosed, childID: "child", now: now)
        XCTAssertTrue(observer.finished)
    }

    func testUnknownParentClockKeepsUncertaintyUntilOwnEvidenceOrTerminalParent() {
        var observer = SessionSubagentObservation()
        let old = SessionFeedLive(observedAt: now, turnAt: now - 60, turnActive: false)
        let entries = [SessionFeedEntry(id: "report", kind: "agent", at: now - 10)]
        _ = observer.receiveOwn(snapshot: old, entries: entries, error: nil, now: now)
        let child = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "child", status: "running"))
        var parent = SessionFeedLive(observedAt: now, agents: [child])
        XCTAssertTrue(observer.receiveParent(parent, childID: "child", now: now))
        XCTAssertEqual(observer.receiveOwn(snapshot: old, entries: entries, error: nil, now: now), "resuming")
        XCTAssertTrue(observer.awaitingOwnEvidence); XCTAssertTrue(observer.shouldReadOwn); XCTAssertFalse(observer.finished)
        parent.agents[0].ref.status = "finished"
        _ = observer.receiveParent(parent, childID: "child", now: now)
        XCTAssertTrue(observer.finished); XCTAssertFalse(observer.shouldReadOwn)
    }

}
