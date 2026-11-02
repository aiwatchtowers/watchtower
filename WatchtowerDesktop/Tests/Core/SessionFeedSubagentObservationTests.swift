import XCTest
@testable import WatchtowerCore

@MainActor
final class SessionFeedSubagentObservationTests: XCTestCase {
    /// Every lifecycle change comes from actual CLI JSON. Neither the marker
    /// closure nor the root's coarse working state is changed to cause resume.
    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        let childID = "child-b"
        let parentID = "parent-a"
        let nested: Bool
        let uncertainFirst: Bool
        let resume: Bool
        private let lock = NSLock()
        private var calls: [[String]] = []
        private var children = 0
        private var parents = 0
        private var roots = 0
        private var running = 0
        private var maximum = 0
        private var parentObserver: (() -> Void)?
        private let now = Date()

        init(nested: Bool, uncertainFirst: Bool = false, resume: Bool = true) {
            self.nested = nested; self.uncertainFirst = uncertainFirst; self.resume = resume
        }
        var recorded: [[String]] { lock.withLock { calls } }
        var maxConcurrent: Int { lock.withLock { maximum } }
        func observeFirstParent(_ action: @escaping () -> Void) { lock.withLock { parentObserver = action } }

        func run(args: [String]) async throws -> Data {
            let payload: [String: Any] = lock.withLock {
                calls.append(args); running += 1; maximum = max(maximum, running)
                let selector = args.firstIndex(of: "--subagent").map { args[$0 + 1] }
                if selector == childID {
                    children += 1
                    if uncertainFirst && children == 1 {
                        return ["entries": [], "live_ok": false, "live_error": "Activity unavailable"]
                    }
                    let resumed = children > (uncertainFirst ? 2 : 1)
                    return child(active: resumed)
                }
                if selector == parentID {
                    parents += 1
                    if parents == 1 { parentObserver?() }
                    return parent(child: childID, resumed: resume && parents >= 3)
                }
                roots += 1
                return parent(child: nested ? parentID : childID, resumed: resume && !nested && roots >= 3)
            }
            try? await Task.sleep(for: .milliseconds(1))
            lock.withLock { running -= 1 }
            return try JSONSerialization.data(withJSONObject: payload)
        }

        private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
        private func child(active: Bool) -> [String: Any] {
            let entry: [String: Any] = ["id": active ? "resumed" : "report", "kind": "agent",
                                        "text": active ? "working again" : "complete", "at": stamp(now - 10)]
            return [
                "session_id": 7, "cursor": "", "entries": [entry], "live_ok": true,
                "live": ["observed_at": stamp(now), "turn_at": stamp(active ? now : now - 60), "turn_active": active,
                         "agents": [], "agents_state": "known"]
            ]
        }
        private func parent(child: String, resumed: Bool) -> [String: Any] {
            ["session_id": 7, "cursor": "c\(roots)", "entries": [], "live_ok": true,
             "live": ["observed_at": stamp(now), "turn_active": true, "agents_state": "known",
                      "agents": [["ref": ["tool_use_id": child, "agent_id": child, "status": resumed ? "running" : "finished"],
                                  "started_at": stamp(resumed ? now : now - 60)]]]]
        }
    }

    func testDirectChildResumesFromRootPayloadWithoutReadingCompletedHistoryEveryTick() async {
        await checkResume(nested: false)
    }
    func testNestedChildResumesOnlyFromItsImmediateParentPayload() async {
        await checkResume(nested: true)
    }
    func testUncertainChildKeepsRecoveringUntilConfirmedFinishedAndThenResumes() async {
        await checkResume(nested: true, uncertainFirst: true)
    }
    func testObservationUsesTheSameSerialReadGateAsAConcurrentMainRefresh() async {
        await checkResume(nested: true, concurrentMain: true)
    }

    private func checkResume(nested: Bool, uncertainFirst: Bool = false, concurrentMain: Bool = false) async {
        let runner = Runner(nested: nested, uncertainFirst: uncertainFirst)
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let resumed = expectation(description: "own fresh running payload after parent resume")
        var sawCompletion = false
        var sawResume = false
        var recordsAtResume: [[String]] = []
        let task = Task {
            await store.followSubagent(
                runner.childID, interval: .milliseconds(1), readsMainFeed: true,
                parentToolUseID: nested ? runner.parentID : nil, isSessionActive: { true },
                isRunning: { false }, isOnScreen: { true }, onEntries: { _ in },
                onLive: { snapshot, _ in
                    if snapshot?.turnActive == false { sawCompletion = true }
                    if sawCompletion, snapshot?.turnActive == true, !sawResume {
                        sawResume = true; recordsAtResume = runner.recorded; resumed.fulfill()
                    }
                }
            )
        }
        if concurrentMain { await store.refresh() }
        await fulfillment(of: [resumed], timeout: 3)
        task.cancel(); await task.value
        XCTAssertTrue(sawCompletion); XCTAssertTrue(sawResume)
        XCTAssertEqual(runner.maxConcurrent, 1)
        let ownIndices = recordsAtResume.indices.filter { recordsAtResume[$0].contains(runner.childID) }
        XCTAssertEqual(ownIndices.count, uncertainFirst ? 3 : 2)
        guard let last = ownIndices.last, ownIndices.count >= 2 else { return }
        let completedRead = ownIndices[ownIndices.count - 2]
        let waiting = recordsAtResume[(completedRead + 1)..<last]
        XCTAssertFalse(waiting.contains { $0.contains(runner.childID) }, "completed history stays paused")
        if nested {
            XCTAssertGreaterThanOrEqual(waiting.filter { $0.contains(runner.parentID) }.count, 3)
            XCTAssertTrue(waiting.contains { !$0.contains("--subagent") }, "root global state still refreshes")
        } else {
            XCTAssertGreaterThanOrEqual(waiting.count, 2)
            XCTAssertTrue(waiting.allSatisfy { !$0.contains("--subagent") })
        }
    }

    func testInactiveSessionReadsHistoryOnceButDoesNotStartParentWatch() async {
        let runner = Runner(nested: true, resume: false)
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.followSubagent(runner.childID, interval: .milliseconds(1), readsMainFeed: true,
                                   parentToolUseID: runner.parentID, isSessionActive: { false },
                                   isRunning: { true }, isOnScreen: { true }, onEntries: { _ in })
        XCTAssertEqual(runner.recorded.count, 1)
        XCTAssertTrue(runner.recorded[0].contains(runner.childID))
    }

    func testOffScreenObservationSpawnsNoCLIAndCancellationStopsParentWatch() async {
        let runner = Runner(nested: true, resume: false)
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        var hiddenTicks = 0
        await store.followSubagent(runner.childID, interval: .milliseconds(1), readsMainFeed: true,
                                   parentToolUseID: runner.parentID,
                                   isSessionActive: { hiddenTicks += 1; return hiddenTicks <= 3 },
                                   isRunning: { true }, isOnScreen: { false }, onEntries: { _ in })
        XCTAssertGreaterThan(hiddenTicks, 3)
        XCTAssertTrue(runner.recorded.isEmpty)
        let parentSeen = expectation(description: "parent-only observer started")
        runner.observeFirstParent { parentSeen.fulfill() }

        let visible = Task {
            await store.followSubagent(runner.childID, interval: .milliseconds(1), readsMainFeed: true,
                                       parentToolUseID: runner.parentID, isSessionActive: { true },
                                       isRunning: { true }, isOnScreen: { true }, onEntries: { _ in })
        }
        await fulfillment(of: [parentSeen], timeout: 3)
        visible.cancel(); await visible.value
        let finalCalls = runner.recorded.count
        try? await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(runner.recorded.count, finalCalls)
        XCTAssertEqual(runner.recorded.filter { $0.contains(runner.childID) }.count, 1)
        XCTAssertTrue(runner.recorded.contains { $0.contains(runner.parentID) })
        XCTAssertEqual(runner.maxConcurrent, 1)
    }
}
