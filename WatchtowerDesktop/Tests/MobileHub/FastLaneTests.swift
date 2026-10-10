import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The hub's fast lane (mobile POC spec §4.5): the session state center's
/// changes and the Desktop's own table writes nudge the publisher, which
/// sends within one coalescing window plus one send instead of the 10 s
/// tick; the center's existing closures keep firing (PROJ-12 wiring).
@MainActor
final class FastLaneTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var terminals: TerminalCenter!
    private var centers: [SessionAgentStateCenter] = []
    private var lanes: [FastLane] = []
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let started = Date().addingTimeInterval(-600)

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt fastlane \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        centers = []
        lanes = []
        suiteName = "FastLaneTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        terminals = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        terminals.shell = { "/bin/zsh" }
        terminals.transcriptExists = { _ in true }
        terminals.now = { [started] in started }
    }

    override func tearDown() {
        lanes.forEach { $0.stop() }
        centers.forEach { $0.stop() }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeCenter() -> SessionAgentStateCenter {
        let center = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: terminals, interval: .seconds(60), notifier: RecordingSessionNotifier(),
            defaults: defaults, notificationCenter: NotificationCenter()
        )
        center.isAppActive = { true }
        centers.append(center)
        return center
    }

    private func makeLane(
        _ center: SessionAgentStateCenter?,
        liveness: SessionLivenessBox = SessionLivenessBox(),
        nudge: @escaping @Sendable (Set<SliceKind>) -> Void,
        sessionStateChanged: @escaping (Int64) -> Void = { _ in }
    ) -> FastLane {
        let lane = FastLane(
            dbPool: pool, agentStates: center, terminalCenter: terminals, liveness: liveness,
            nudge: nudge, sessionStateChanged: sessionStateChanged
        )
        lanes.append(lane)
        return lane
    }

    private func workbench() async throws -> (project: Int64, dir: String) {
        let dir = folder.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let project = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: dir) }
        return (project, dir)
    }

    private func session(in workbench: (project: Int64, dir: String)) async throws -> TerminalSession {
        try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: workbench.project, kind: .claude, title: "Release work", folderPath: workbench.dir,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    /// The hook's write, from another connection (in the app, the Go
    /// process), so GRDB observation never sees it.
    private func hookWrites(_ ids: [Int64], _ state: String, at offset: TimeInterval) throws {
        let other = try DatabaseQueue(path: path)
        try other.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ? WHERE id = ?",
                    arguments: [state, stamp(offset), id]
                )
            }
        }
    }

    private func latestPayloads(_ transport: StubHubTransport, kind: SliceKind) throws -> [String: [String: Any]] {
        var latest: [String: [String: Any]] = [:]
        for saved in transport.saved where saved.record.kind == kind.rawValue {
            latest[saved.record.recordName] = try SliceJSON.object(saved.record.payload)
        }
        return latest
    }

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.now
        let origin: ContinuousClock.Instant

        init() { origin = current }

        var now: ContinuousClock.Instant { lock.withLock { current } }

        func set(_ offset: Duration) {
            lock.withLock { current = origin + offset }
        }
    }

    private final class NudgeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [Set<SliceKind>] = []
        var nudges: [Set<SliceKind>] { lock.withLock { all } }
        func record(_ kinds: Set<SliceKind>) { lock.withLock { all.append(kinds) } }
    }

    // MARK: - Fast lane

    /// Spec §13 B1 (f): Needs approval reaches the published `state_kind`
    /// within one coalescing window plus one send on a fake clock, long
    /// before the 10 s tick.
    func testNeedsApprovalReachesTheZoneWithinOneWindowPlusOneSend() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        let liveness = SessionLivenessBox()
        let clock = FakeClock()
        let transport = StubHubTransport()
        let publisher = SlicePublisher(
            dbPool: pool, state: try HubSyncState.inMemory(), transport: transport,
            sources: [TerminalSessionSlice(liveness: { liveness.current }, reportSummary: { _, _ in nil })]
        ) { clock.now }
        let lane = makeLane(center, liveness: liveness) { publisher.nudge(kinds: $0) }
        lane.start()
        terminals.start(row, fresh: true)
        await center.poll()
        try await publisher.publishOnce()
        let record = SliceKind.terminalSession.recordName(id: String(row.id))
        XCTAssertEqual(try latestPayloads(transport, kind: .terminalSession)[record]?["state_kind"] as? String, "running")
        _ = publisher.takeDueFastKinds(now: clock.origin + .seconds(1))

        clock.set(.seconds(5))
        try hookWrites([row.id], "approval", at: 1)
        await center.poll()

        let deadline = try XCTUnwrap(publisher.fastDeadline, "the state change nudged the publisher")
        XCTAssertLessThanOrEqual(deadline, clock.origin + .seconds(6), "one coalescing window")
        XCTAssertLessThan(deadline, clock.origin + .seconds(10), "not the 10 s tick")
        let kinds = try XCTUnwrap(publisher.takeDueFastKinds(now: deadline))
        XCTAssertTrue(kinds.isSuperset(of: [.terminalSession, .workbench]))
        try await publisher.publishOnce(kinds: kinds)
        let published = try XCTUnwrap(try latestPayloads(transport, kind: .terminalSession)[record])
        XCTAssertEqual(published["state_kind"] as? String, "needs_approval")
        XCTAssertEqual(published["state_tone"] as? String, "orange")
        XCTAssertEqual(published["state_glyph"] as? String, "hand.raised.fill")
    }

    /// #411 (PROJ-11: Agents working is never announced): a turn end with
    /// background agents running reaches the phone as `working` with the
    /// Mac's caption and glyph, and raises no `ask_alert`.
    func testAgentsWorkingPublishesAsWorkingAndRaisesNoAlert() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        let liveness = SessionLivenessBox()
        let clock = FakeClock()
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        _ = try HubIdentity(sidecar: sidecar).ensureEnabledAt(started)
        let sliceNow = started.addingTimeInterval(60)
        let publisher = SlicePublisher(
            dbPool: pool, state: sidecar, transport: transport,
            sources: [
                TerminalSessionSlice(liveness: { liveness.current }, reportSummary: { _, _ in nil }, now: { sliceNow }),
                AskAlertSlice(sidecar: sidecar) { sliceNow }
            ]
        ) { clock.now }
        let log = NudgeLog()
        let lane = makeLane(center, liveness: liveness) { kinds in
            log.record(kinds)
            publisher.nudge(kinds: kinds)
        }
        lane.start()
        terminals.start(row, fresh: true)
        try hookWrites([row.id], "working", at: 1)
        await center.poll()
        try await publisher.publishOnce()
        _ = publisher.takeDueFastKinds(now: clock.origin + .seconds(1))

        clock.set(.seconds(5))
        let turnEnd = stamp(2)
        let other = try DatabaseQueue(path: path)
        try await other.write { db in
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ?,
                        agent_background = 2, agent_background_at = ? WHERE id = ?
                    """,
                arguments: [turnEnd, turnEnd, row.id]
            )
        }
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state.kind, .background)

        let deadline = try XCTUnwrap(publisher.fastDeadline, "the state change nudged the publisher")
        let kinds = try XCTUnwrap(publisher.takeDueFastKinds(now: deadline))
        XCTAssertFalse(log.nudges.contains { $0.contains(.askAlert) }, "a session state never nudges an alert")
        try await publisher.publishOnce(kinds: kinds.union([.askAlert]))
        let record = SliceKind.terminalSession.recordName(id: String(row.id))
        let published = try XCTUnwrap(try latestPayloads(transport, kind: .terminalSession)[record])
        XCTAssertEqual(published["state_kind"] as? String, "working")
        XCTAssertEqual(published["state_caption"] as? String, "2 agents working")
        XCTAssertEqual(published["state_glyph"] as? String, "person.2.fill")
        XCTAssertEqual(published["state_tone"] as? String, "green")
        XCTAssertFalse(transport.saved.contains { $0.record.kind == SliceKind.askAlert.rawValue }, "no ask_alert")
    }

    func testAStateChangeAsksForTheWorkbenchsGitAndSummaryRefresh() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        var changed: [Int64] = []
        let lane = makeLane(center, nudge: { _ in }, sessionStateChanged: { changed.append($0) })
        terminals.start(row, fresh: true)
        await center.poll()
        lane.start()
        XCTAssertEqual(changed, [], "starting is not a change")

        try hookWrites([row.id], "working", at: 1)
        await center.poll()
        XCTAssertEqual(changed, [bench.project])
        await center.poll()
        XCTAssertEqual(changed, [bench.project], "an unchanged read asks for nothing")
    }

    func testStartCopiesTheLivenessAndNudgesTheSessionKinds() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        terminals.start(row, fresh: true)
        let liveness = SessionLivenessBox()
        let log = NudgeLog()
        let lane = makeLane(center, liveness: liveness) { log.record($0) }
        lane.start()
        XCTAssertEqual(liveness.current.liveIDs, [row.id])
        XCTAssertEqual(liveness.current.startedAt[row.id], started)
        XCTAssertEqual(log.nudges.first, [.terminalSession, .workbench])
    }

    // MARK: - Closure chaining

    func testTheCentersExistingClosuresStillFireAndAreRestoredOnStop() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        var changes = 0
        var reads = 0
        center.onChange = { changes += 1 }
        center.onRead = { reads += 1 }
        let log = NudgeLog()
        let lane = makeLane(center) { log.record($0) }
        lane.start()
        let atStart = log.nudges.count

        await center.poll()
        XCTAssertEqual(changes, 1, "the existing onChange fires")
        XCTAssertEqual(reads, 1, "the existing onRead fires")
        XCTAssertEqual(log.nudges.count, atStart + 1, "and the fast lane nudges")

        lane.stop()
        terminals.start(row, fresh: true)
        try hookWrites([row.id], "working", at: 1)
        await center.poll()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(log.nudges.count, atStart + 1, "a stopped lane is unhooked")
    }

    /// The PROJ-12 held-answer wiring `WorkbenchesViewModel` sets on the
    /// center keeps working with the fast lane chained on top.
    func testAHeldAnswerStillGoesWithTheFastLaneChained() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
        let askID = try await pool.write { db in
            try TestDatabase.insertOwnerAsk(db, projectID: bench.project, sessionID: row.id, payload: questions)
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults, terminalCenter: terminals, agentStates: center)
        let log = NudgeLog()
        let lane = makeLane(center) { log.record($0) }
        lane.start()
        terminals.start(row, fresh: true)
        let process = try XCTUnwrap(processes.last)
        try hookWrites([row.id], "approval", at: 1)
        await center.poll()

        await vm.asks.load(projectID: bench.project)
        let ask = try XCTUnwrap(vm.asks.openAsks[bench.project]?.first { $0.id == askID })
        vm.asks.drafts.update(askID) { $0.picks["a"] = .init(labels: ["Yes"]) }
        let delivery = await vm.asks.answer(ask)
        XCTAssertEqual(delivery, .held)

        let before = log.nudges.count
        try hookWrites([row.id], "working", at: 2)
        await center.poll()
        await awaitHubCondition("the held line goes") { process.inputs.count == 2 }
        XCTAssertEqual(process.inputs.last, [0x0D])
        XCTAssertGreaterThan(log.nudges.count, before, "the fast lane nudged too")
    }

    // MARK: - Table observation

    func testTheDesktopsOwnTableWritesNudgeTheirKinds() async throws {
        let bench = try await workbench()
        let log = NudgeLog()
        let lane = makeLane(nil) { log.record($0) }
        lane.start()
        await awaitHubCondition("every table is observed") { lane.observedTables == FastLane.observedTables.count }
        let baseline = log.nudges.count

        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: bench.project) }
        await awaitHubCondition("a target write nudges") { log.nudges.dropFirst(baseline).contains { $0.contains(.workbenchTarget) } }
        _ = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: bench.project) }
        await awaitHubCondition("an ask write nudges") { log.nudges.contains { $0.contains(.ownerAsk) } }
        XCTAssertTrue(
            log.nudges.contains { $0.isSuperset(of: [.ownerAsk, .askAlert]) },
            "a new or closed ask nudges its alert with it"
        )
        _ = try await pool.write { try TestDatabase.insertWorkbenchComment($0, projectID: bench.project, targetID: target) }
        await awaitHubCondition("a comment write nudges") { log.nudges.contains { $0.contains(.workbenchComment) } }
        let beforeSession = log.nudges.count
        _ = try await session(in: bench)
        await awaitHubCondition("a session write nudges") {
            log.nudges.dropFirst(beforeSession).contains { $0.contains(.terminalSession) }
        }

        lane.stop()
        XCTAssertEqual(lane.observedTables, 0)
        // The positive control: a live lane over the same pool sees the same
        // write; once it has, the stopped lane would have seen it too.
        let control = NudgeLog()
        let live = makeLane(nil) { control.record($0) }
        live.start()
        await awaitHubCondition("the control lane observes") { live.observedTables == FastLane.observedTables.count }
        let stopped = log.nudges.count
        _ = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: bench.project) }
        await awaitHubCondition("the live lane sees the write") { control.nudges.contains { $0.contains(.ownerAsk) } }
        XCTAssertEqual(log.nudges.count, stopped, "a stopped lane observes nothing")
    }

    // MARK: - Review focus 5

    /// 30 live sessions changing state every second for 60 s: at most 30
    /// fast sends, each ≥ 2 s apart, and the last published state of every
    /// session equals its last DB state, at most one window plus one
    /// spacing after the last change.
    func testReviewFocus5AStormOfStateChangesSendsAtMostOncePerSpacing() async throws {
        let bench = try await workbench()
        var rows: [TerminalSession] = []
        for _ in 0..<30 { rows.append(try await session(in: bench)) }
        let ids = rows.map(\.id)
        let center = makeCenter()
        let liveness = SessionLivenessBox()
        let clock = FakeClock()
        let transport = StubHubTransport()
        let publisher = SlicePublisher(
            dbPool: pool, state: try HubSyncState.inMemory(), transport: transport,
            sources: [TerminalSessionSlice(liveness: { liveness.current }, reportSummary: { _, _ in nil })]
        ) { clock.now }
        let lane = makeLane(center, liveness: liveness) { publisher.nudge(kinds: $0) }
        rows.forEach { terminals.start($0, fresh: true) }
        await center.poll()
        lane.start()
        try await publisher.publishOnce()
        _ = publisher.takeDueFastKinds(now: clock.origin + .seconds(1))

        let states = ["working", "approval", "waiting"]
        let wire = ["working": "working", "approval": "needs_approval", "waiting": "stopped"]
        var sends: [ContinuousClock.Instant] = []
        var lastChange = clock.origin
        var lastState = ""
        let start = Duration.seconds(10)
        for step in 0..<(64 * 4) {
            let offset = start + .milliseconds(250 * step)
            clock.set(offset)
            if step.isMultiple(of: 4), step / 4 < 60 {
                let second = step / 4
                lastState = states[second % states.count]
                try hookWrites(ids, lastState, at: Double(second + 1))
                await center.poll()
                lastChange = clock.now
            }
            if let kinds = publisher.takeDueFastKinds(now: clock.now) {
                sends.append(clock.now)
                try await publisher.publishOnce(kinds: kinds)
            }
        }

        XCTAssertLessThanOrEqual(sends.count, 30)
        XCTAssertGreaterThan(sends.count, 20, "the storm is sent, not starved")
        for (earlier, later) in zip(sends, sends.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, .seconds(2), "fast sends are at least 2 s apart")
        }
        let lastSend = try XCTUnwrap(sends.last)
        XCTAssertGreaterThanOrEqual(lastSend, lastChange)
        XCTAssertLessThanOrEqual(lastSend - lastChange, .seconds(3), "never older than one window plus one spacing")
        let published = try latestPayloads(transport, kind: .terminalSession)
        for id in ids {
            let record = SliceKind.terminalSession.recordName(id: String(id))
            XCTAssertEqual(published[record]?["state_kind"] as? String, wire[lastState], "session \(id)")
        }
        let stored = try await pool.read { db in
            try String.fetchSet(db, sql: "SELECT agent_state FROM terminal_sessions WHERE kind = 'claude'")
        }
        XCTAssertEqual(stored, [lastState], "the last published state is the last DB state")
    }

    // MARK: - Hub wiring

    func testTheLaneIsAHubCompanionOnTheMainActor() {
        let lane = makeLane(nil) { _ in }
        let companion: any HubCompanion = lane
        companion.start()
        XCTAssertTrue(lane.isRunning)
        companion.stop()
        XCTAssertFalse(lane.isRunning)
    }
}
