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
        let laggedResume: Bool
        let completedResume: Bool
        let lateOldEntry: Bool
        let resumeReadError: Bool
        let parentInitiallyRunning: Bool
        let unknownParentStart: Bool
        let sameCompletedParentRun: Bool
        private let lock = NSLock()
        private var calls: [[String]] = []
        private var children = 0
        private var parents = 0
        private var roots = 0
        private var running = 0
        private var maximum = 0
        private var parentObserver: (() -> Void)?
        private var lifecycleObserver: (() -> Void)?
        private let now = Date()

        init(
            nested: Bool,
            uncertainFirst: Bool = false,
            resume: Bool = true,
            laggedResume: Bool = false,
            completedResume: Bool = false,
            lateOldEntry: Bool = false,
            resumeReadError: Bool = false,
            parentInitiallyRunning: Bool = false,
            unknownParentStart: Bool = false,
            sameCompletedParentRun: Bool = false
        ) {
            self.nested = nested; self.uncertainFirst = uncertainFirst; self.resume = resume
            self.laggedResume = laggedResume; self.completedResume = completedResume; self.lateOldEntry = lateOldEntry
            self.resumeReadError = resumeReadError
            self.parentInitiallyRunning = parentInitiallyRunning; self.unknownParentStart = unknownParentStart
            self.sameCompletedParentRun = sameCompletedParentRun
        }
        var recorded: [[String]] { lock.withLock { calls } }
        var maxConcurrent: Int { lock.withLock { maximum } }
        func observeFirstParent(_ action: @escaping () -> Void) { lock.withLock { parentObserver = action } }
        func observeNextLifecycleRead(_ action: @escaping () -> Void) { lock.withLock { lifecycleObserver = action } }
        private func signalLifecycleRead() {
            let action = lifecycleObserver; lifecycleObserver = nil; action?()
        }

        func run(args: [String]) async throws -> Data {
            let payload: [String: Any] = lock.withLock {
                calls.append(args); running += 1; maximum = max(maximum, running)
                let selector = args.firstIndex(of: "--subagent").map { args[$0 + 1] }
                if selector == childID {
                    children += 1
                    if uncertainFirst && children == 1 {
                        return ["entries": [], "live_ok": false, "live_error": "Activity unavailable"]
                    }
                    let initialCount = uncertainFirst ? 2 : 1
                    let resumed = children > initialCount
                    if resumeReadError && children == initialCount + 1 {
                        return ["entries": [], "live_ok": false, "live_error": "Activity unavailable"]
                    }
                    if laggedResume && children == initialCount + (resumeReadError ? 2 : 1) {
                        return child(active: false, newInterval: false, delayed: true)
                    }
                    return child(active: resumed && !completedResume, newInterval: resumed)
                }
                if selector == parentID {
                    parents += 1
                    signalLifecycleRead()
                    if parents == 1 { parentObserver?() }
                    return parent(child: childID, resumed: parentInitiallyRunning || (resume && parents >= 3),
                                  unknown: uncertainFirst && children == 1)
                }
                roots += 1
                signalLifecycleRead()
                return parent(child: nested ? parentID : childID, resumed: parentInitiallyRunning || (resume && !nested && roots >= 3),
                              unknown: uncertainFirst && children == 1)
            }
            try? await Task.sleep(for: .milliseconds(1))
            lock.withLock { running -= 1 }
            return try JSONSerialization.data(withJSONObject: payload)
        }

        private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
        private func child(active: Bool, newInterval: Bool, delayed: Bool = false) -> [String: Any] {
            let id = newInterval ? (active ? "resumed" : "resumed-report") : (delayed && lateOldEntry ? "late-old-report" : "report")
            let entry: [String: Any] = ["id": id, "kind": "agent", "text": newInterval ? "new run" : "old complete",
                                        "at": stamp(newInterval ? now - 1 : (delayed && lateOldEntry ? now - 3 : now - 10))]
            let observed = laggedResume ? now + Double(min(children, 3) - 3) : now
            return [
                "session_id": 7, "cursor": "", "entries": [entry], "live_ok": true,
                "live": ["observed_at": stamp(observed), "turn_at": stamp(newInterval ? now - 5 : now - 60),
                         "turn_active": active, "agents": [], "agents_state": "known"]
            ]
        }
        private func parent(child: String, resumed: Bool, unknown: Bool = false) -> [String: Any] {
            let status = unknown ? "unknown" : (resumed ? "running" : "finished")
            var agent: [String: Any] = ["ref": ["tool_use_id": child, "agent_id": child, "status": status]]
            if !unknownParentStart { agent["started_at"] = stamp(resumed && !sameCompletedParentRun ? now - 4 : now - 60) }
            return [
                "session_id": 7, "cursor": "c\(roots)", "entries": [], "live_ok": true,
                "live": ["observed_at": stamp(now), "turn_active": true, "agents_state": "known", "agents": [agent]]
            ]
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
            XCTAssertGreaterThanOrEqual(waiting.filter { $0.contains(runner.parentID) }.count, uncertainFirst ? 2 : 3)
            if concurrentMain {
                XCTAssertLessThanOrEqual(waiting.filter { !$0.contains("--subagent") }.count, 1)
            } else {
                XCTAssertTrue(waiting.allSatisfy { $0.contains(runner.parentID) }, "only the immediate parent is observed")
            }
        } else {
            XCTAssertGreaterThanOrEqual(waiting.count, 2)
            XCTAssertTrue(waiting.allSatisfy { !$0.contains("--subagent") })
        }
    }

    func testDirectResumeSurvivesAnOldCompletedTranscriptWithARefreshedClock() async {
        await checkLaggedResume(nested: false, completed: false)
    }
    func testNestedResumeSurvivesAnOldCompletedTranscriptWithARefreshedClock() async {
        await checkLaggedResume(nested: true, completed: false)
    }
    func testDirectFastCompletedNewRunSettlesWithoutRepeatingHistoryReads() async {
        await checkLaggedResume(nested: false, completed: true)
    }
    func testNestedFastCompletedNewRunSettlesWithoutRepeatingHistoryReads() async {
        await checkLaggedResume(nested: true, completed: true)
    }

    private func checkLaggedResume(
        nested: Bool, completed: Bool, initiallyRunning: Bool = false, unknownStart: Bool = false
    ) async {
        let runner = Runner(nested: nested, laggedResume: true, completedResume: completed, lateOldEntry: true,
                            parentInitiallyRunning: initiallyRunning, unknownParentStart: unknownStart)
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let acknowledged = expectation(description: "new own interval acknowledged despite delayed transcript")
        var baseline: Date?
        var liveTurns: [Date] = []
        var publishedIDs: [String] = []
        var sawPending = false
        var didAcknowledge = false
        let task = Task {
            await store.followSubagent(
                runner.childID, interval: .milliseconds(1), readsMainFeed: true,
                parentToolUseID: nested ? runner.parentID : nil, isSessionActive: { true },
                isRunning: { false }, isOnScreen: { true },
                onEntries: { publishedIDs += $0.map(\.id) },
                onLive: { snapshot, _ in
                    guard let turn = snapshot?.turnAt else { return }
                    liveTurns.append(turn)
                    if baseline == nil { baseline = turn }
                    if let baseline, turn > baseline, !didAcknowledge {
                        didAcknowledge = true
                        XCTAssertEqual(snapshot?.turnActive, !completed)
                        acknowledged.fulfill()
                    }
                }, onStatus: { if $0 == "resuming" { sawPending = true } }
            )
        }
        await fulfillment(of: [acknowledged], timeout: 3)
        if completed, didAcknowledge {
            let parentWatch = expectation(description: "settled new completion returns to parent-only watch")
            runner.observeNextLifecycleRead { parentWatch.fulfill() }
            await fulfillment(of: [parentWatch], timeout: 3)
        }
        task.cancel(); await task.value
        XCTAssertTrue(didAcknowledge); XCTAssertTrue(sawPending)
        XCTAssertEqual(runner.maxConcurrent, 1)
        XCTAssertFalse(publishedIDs.contains("late-old-report"), "the previous interval cannot become the current UI snapshot")
        XCTAssertEqual(liveTurns.prefix(2).count, 2)
        if liveTurns.count >= 2 { XCTAssertGreaterThan(liveTurns[1], liveTurns[0]) }
        let childCalls = runner.recorded.filter { $0.contains(runner.childID) }
        if completed {
            XCTAssertEqual(childCalls.count, 3, "initial completion, lagged old completion, then the new completed interval")
            XCTAssertEqual(liveTurns.count, 2, "the lagged old completion was never published")
        } else {
            XCTAssertGreaterThanOrEqual(childCalls.count, 3)
        }
        if nested { XCTAssertTrue(runner.recorded.contains { $0.contains(runner.parentID) }) }
    }

    func testFreshDirectPaneRecoversAnAlreadyRunningParentBeforeOwnLogCatchesUp() async {
        await checkLaggedResume(nested: false, completed: false, initiallyRunning: true)
    }
    func testFreshNestedPaneRecoversAnAlreadyRunningParentBeforeOwnLogCatchesUp() async {
        await checkLaggedResume(nested: true, completed: false, initiallyRunning: true)
    }
    func testFreshPaneWithUnknownParentStartKeepsPollingUntilOwnEvidenceArrives() async {
        await checkLaggedResume(nested: true, completed: false, initiallyRunning: true, unknownStart: true)
    }
    func testKnownSameCompletedParentIntervalDoesNotRepeatedlyReadHistory() async {
        let runner = Runner(nested: true, parentInitiallyRunning: true, sameCompletedParentRun: true)
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let completed = expectation(description: "old own completion read")
        var sawCompletion = false
        let task = Task {
            await store.followSubagent(
                runner.childID, interval: .milliseconds(1), parentToolUseID: runner.parentID, isSessionActive: { true },
                isRunning: { true }, isOnScreen: { true }, onEntries: { _ in }, onLive: { snapshot, _ in
                    if snapshot?.turnActive == false, !sawCompletion { sawCompletion = true; completed.fulfill() }
                }
            )
        }
        await fulfillment(of: [completed], timeout: 3)
        for _ in 0..<3 {
            let parent = expectation(description: "same old parent observed")
            runner.observeNextLifecycleRead { parent.fulfill() }
            await fulfillment(of: [parent], timeout: 3)
        }
        task.cancel(); await task.value
        XCTAssertEqual(runner.recorded.filter { $0.contains(runner.childID) }.count, 1)
        XCTAssertEqual(runner.maxConcurrent, 1)
    }

    func testPendingResumeSurvivesRetryAfterAnErrorBeforeTranscriptAcknowledgement() async {
        let runner = Runner(nested: true, laggedResume: true, lateOldEntry: true, resumeReadError: true)
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let failed = expectation(description: "forced resume read fails")
        var reportedFailure = false
        let first = Task {
            await store.followSubagent(
                runner.childID, interval: .milliseconds(1), parentToolUseID: runner.parentID, isSessionActive: { true },
                isRunning: { false }, isOnScreen: { true }, onEntries: { _ in }, onLive: { _, error in
                    if error != nil, !reportedFailure { reportedFailure = true; failed.fulfill() }
                }
            )
        }
        await fulfillment(of: [failed], timeout: 3)
        first.cancel(); await first.value
        let resumed = expectation(description: "retry observes a genuinely new own interval")
        var didResume = false
        var published: [String] = []
        let retry = Task {
            await store.followSubagent(
                runner.childID, interval: .milliseconds(1), parentToolUseID: runner.parentID, isSessionActive: { true },
                isRunning: { false }, isOnScreen: { true }, onEntries: { published += $0.map(\.id) },
                onLive: { snapshot, _ in
                    if snapshot?.turnActive == true, !didResume { didResume = true; resumed.fulfill() }
                }
            )
        }
        await fulfillment(of: [resumed], timeout: 3)
        retry.cancel(); await retry.value
        XCTAssertTrue(didResume)
        XCTAssertFalse(published.contains("late-old-report"))
        XCTAssertEqual(runner.maxConcurrent, 1)
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
