import XCTest
@testable import WatchtowerCore

@MainActor
final class SessionFeedSubagentTerminalTests: XCTestCase {
    private let now = Date()
    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        let childID = "child"
        let parentID = "parent"
        private let ownFrames: [[String: Any]]
        private let parentFrames: [[String: Any]]
        private let lock = NSLock()
        private var ownCount = 0
        private var parentCount = 0
        private var running = 0
        private var maximum = 0
        private var nextParent: (() -> Void)?
        init(own: [[String: Any]], parent: [[String: Any]]) { ownFrames = own; parentFrames = parent }
        var childReads: Int { lock.withLock { ownCount } }
        var parentReads: Int { lock.withLock { parentCount } }
        var maxConcurrent: Int { lock.withLock { maximum } }
        func observeNextParent(_ action: @escaping () -> Void) { lock.withLock { nextParent = action } }
        func run(args: [String]) async throws -> Data {
            let payload = lock.withLock {
                running += 1; maximum = max(maximum, running)
                if args.contains(childID) {
                    let frame = ownFrames[min(ownCount, ownFrames.count - 1)]; ownCount += 1; return frame
                }
                let frame = parentFrames[min(parentCount, parentFrames.count - 1)]; parentCount += 1
                let action = nextParent; nextParent = nil; action?()
                return frame
            }
            try? await Task.sleep(for: .milliseconds(1))
            lock.withLock { running -= 1 }
            return try JSONSerialization.data(withJSONObject: payload)
        }
    }
    private func stamp(_ offset: TimeInterval) -> String { ISO8601DateFormatter().string(from: now + offset) }
    private func own(_ turn: TimeInterval, active: Bool, id: String) -> [String: Any] {
        ["entries": [["id": id, "kind": "agent", "text": id, "at": stamp(turn + 1)]], "live_ok": true,
         "live": ["observed_at": stamp(0), "turn_at": stamp(turn), "turn_active": active, "agents": [], "agents_state": "known"]]
    }
    private func parent(_ start: TimeInterval, status: String) -> [String: Any] {
        ["entries": [], "live_ok": true,
         "live": ["observed_at": stamp(0), "turn_active": true, "agents_state": "known",
                  "agents": [["ref": ["tool_use_id": "child", "agent_id": "child", "status": status], "started_at": stamp(start)]]]]
    }

    func testDirectParentCloseStopsAStaleActiveChildAndKeepsOnlyParentObservation() async {
        await checkClose(nested: false)
    }
    func testNestedParentCloseStopsAStaleActiveChildAndKeepsOnlyParentObservation() async {
        await checkClose(nested: true)
    }
    private func checkClose(nested: Bool) async {
        let runner = Runner(own: [own(-60, active: true, id: "old-active")], parent: [parent(-60, status: "finished")])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let closed = expectation(description: "authoritative parent terminal")
        var states: [String] = []
        var didClose = false
        let task = Task {
            await store.followSubagent(
                runner.childID, interval: .milliseconds(1), parentToolUseID: nested ? runner.parentID : nil,
                isSessionActive: { true }, isRunning: { true }, isOnScreen: { true }, onEntries: { _ in },
                onStatus: { state in
                    states.append(state)
                    if state == "finished", !didClose { didClose = true; closed.fulfill() }
                }
            )
        }
        await fulfillment(of: [closed], timeout: 3)
        let watched = expectation(description: "parent-only watch remains live")
        runner.observeNextParent { watched.fulfill() }
        await fulfillment(of: [watched], timeout: 3)
        task.cancel(); await task.value
        XCTAssertTrue(didClose); XCTAssertEqual(states.last, "finished")
        XCTAssertEqual(runner.childReads, 1); XCTAssertGreaterThanOrEqual(runner.parentReads, 2)
        XCTAssertEqual(runner.maxConcurrent, 1)
    }

    func testNestedCloseThenResumeRejectsTheOldActiveTurnUntilNewOwnTurnArrives() async {
        let frames = [own(-60, active: true, id: "old-active"), own(-60, active: true, id: "old-active"),
                      own(-5, active: true, id: "new-active")]
        let runner = Runner(own: frames, parent: [parent(-60, status: "finished"), parent(-4, status: "running")])
        await checkResumedHistory(runner, completed: false)
    }

    func testParentClosesPendingResumeButOldActiveDataCannotResurrectItWhileHistorySettles() async {
        let runner = Runner(
            own: [own(-60, active: false, id: "old-report"), own(-60, active: false, id: "old-report"),
                  own(-60, active: true, id: "old-active"), own(-60, active: true, id: "old-active"),
                  own(-5, active: false, id: "new-report")],
            parent: [parent(-60, status: "finished"), parent(-4, status: "running"), parent(-4, status: "finished")]
        )
        await checkResumedHistory(runner, completed: true)
    }

    private func checkResumedHistory(_ runner: Runner, completed: Bool) async {
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let acknowledged = expectation(description: "new interval reaches the pane")
        var baseline: Date?
        var turns: [Date] = []
        var statusesAfterClose: [String] = []
        var acknowledgedOnce = false
        let task = Task {
            await store.followSubagent(
                runner.childID, interval: .milliseconds(1), parentToolUseID: runner.parentID, isSessionActive: { true },
                isRunning: { true }, isOnScreen: { true }, onEntries: { _ in }, onLive: { snapshot, _ in
                    guard let turn = snapshot?.turnAt else { return }
                    turns.append(turn)
                    if baseline == nil { baseline = turn }
                    if let baseline, turn > baseline, !acknowledgedOnce {
                        acknowledgedOnce = true; acknowledged.fulfill()
                    }
                }, onStatus: { if completed && runner.parentReads >= 3 { statusesAfterClose.append($0) } }
            )
        }
        await fulfillment(of: [acknowledged], timeout: 3)
        if completed, acknowledgedOnce {
            let watched = expectation(description: "settled terminal interval pauses child history")
            runner.observeNextParent { watched.fulfill() }
            await fulfillment(of: [watched], timeout: 3)
        }
        task.cancel(); await task.value
        XCTAssertTrue(acknowledgedOnce)
        XCTAssertEqual(turns.prefix(2).count, 2)
        if turns.count >= 2 { XCTAssertGreaterThan(turns[1], turns[0]) }
        XCTAssertEqual(runner.maxConcurrent, 1)
        if completed {
            XCTAssertEqual(runner.childReads, 5)
            XCTAssertEqual(turns.count, 2)
            XCTAssertFalse(statusesAfterClose.isEmpty)
            XCTAssertTrue(statusesAfterClose.allSatisfy { $0 == "finished" })
        } else { XCTAssertGreaterThanOrEqual(runner.childReads, 3) }
    }
}
