import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The hub's change triggers (mobile POC spec §4.5): the Desktop's own ask
/// writes nudge the publisher's fast lane; session state changes drive the
/// git, summary and report runners and reach the phone on the 30 s full
/// tick (board #724, owner decision Q3); the center's existing closures
/// keep firing (PROJ-12 wiring).
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
    /// The one wall clock of a test: the center and every slice judge the
    /// background agent count (#411) at it. `FakeClock` is the other clock
    /// on purpose: the publisher schedules its fast lane on a monotonic
    /// `ContinuousClock.Instant`, which no `Date` stands in for.
    private var wall = WallClock(Date())

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
        wall = WallClock(started.addingTimeInterval(60))
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

    private func makeCenter(probeRunner: (any CLIRunnerProtocol)? = nil) -> SessionAgentStateCenter {
        let wall = self.wall
        let center = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: terminals, interval: .seconds(60), notifier: RecordingSessionNotifier(),
            defaults: defaults, notificationCenter: NotificationCenter(), clock: { wall.now }, probeRunner: probeRunner
        )
        center.isAppActive = { true }
        centers.append(center)
        return center
    }

    private func makeLane(
        _ center: SessionAgentStateCenter?,
        liveness: SessionLivenessBox = SessionLivenessBox(),
        sessionStatesChanged: @escaping () -> Void = {},
        nudge: @escaping @Sendable (Set<SliceKind>) -> Void,
        sessionStateChanged: @escaping (Int64) -> Void = { _ in }
    ) -> FastLane {
        let lane = FastLane(
            dbPool: pool, agentStates: center, terminalCenter: terminals, liveness: liveness,
            nudge: nudge, sessionStateChanged: sessionStateChanged, sessionStatesChanged: sessionStatesChanged
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

    /// The background agent count's write, from another connection (the
    /// `Stop` hook): `waiting` one second into the run, `count` reported at
    /// `reportOffset` seconds into it.
    private func countWrites(_ id: Int64, count: Int, reportedAt reportOffset: TimeInterval = 2) throws {
        let other = try DatabaseQueue(path: path)
        try other.write { db in
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ?,
                        agent_background = ?, agent_background_at = ? WHERE id = ?
                    """,
                arguments: [stamp(1), count, stamp(reportOffset), id]
            )
        }
    }

    /// The `terminal_session` slice over `liveness`, judging at the wall clock.
    private func terminalSlice(_ liveness: SessionLivenessBox) -> TerminalSessionSlice {
        let wall = self.wall
        return TerminalSessionSlice(liveness: { liveness.current }, reportSummary: { _, _ in nil }, now: { wall.now })
    }

    private func latestPayloads(_ transport: StubHubTransport, kind: SliceKind) throws -> [String: [String: Any]] {
        var latest: [String: [String: Any]] = [:]
        for saved in try transport.openedSaves() where saved.record.kind == kind.rawValue {
            latest[saved.record.recordName] = try SliceJSON.object(saved.record.payload)
        }
        return latest
    }

    /// A `Date` clock the test moves by hand.
    private final class WallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// The publisher's monotonic clock (the fast lane's deadlines).
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

    /// Spec §13 B1 (f), amended by board #724 (owner decision Q3): Needs
    /// approval reaches the published `state_kind` at the next 30 s full
    /// tick, without an immediate send; the 10 s urgent tick leaves it.
    func testNeedsApprovalRidesTheNextFullTickWithoutAnImmediateSend() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        let liveness = SessionLivenessBox()
        let clock = FakeClock()
        let transport = StubHubTransport()
        let publisher = SlicePublisher(
            dbPool: pool, state: try HubSyncState.inMemory(), transport: transport.sealing(),
            sources: [terminalSlice(liveness)],
            clock: { clock.now },
            sendNow: { await transport.sendNow() }
        )
        let lane = makeLane(center, liveness: liveness) { publisher.nudge(kinds: $0) }
        lane.start()
        terminals.start(row, fresh: true)
        await center.poll()
        XCTAssertEqual(publisher.takeDueCycle(now: clock.origin), .full)
        await publisher.run(.full)
        let record = SliceKind.terminalSession.recordName(id: String(row.id))
        XCTAssertEqual(try latestPayloads(transport, kind: .terminalSession)[record]?["state_kind"] as? String, "running")

        clock.set(.seconds(5))
        try hookWrites([row.id], "approval", at: 1)
        await center.poll()

        // The change nudges only the ask kinds (board #724): their fast
        // cycle leaves the session state for the full tick.
        let fast = try XCTUnwrap(publisher.takeDueCycle(now: clock.origin + .seconds(6)))
        XCTAssertEqual(fast, .urgent(FastLane.stateChangeKinds))
        await publisher.run(fast)
        XCTAssertEqual(try latestPayloads(transport, kind: .terminalSession)[record]?["state_kind"] as? String, "running")
        let urgent = try XCTUnwrap(publisher.takeDueCycle(now: clock.origin + .seconds(10)))
        XCTAssertEqual(urgent, .urgent(SlicePublisher.urgentKinds))
        await publisher.run(urgent)
        XCTAssertEqual(try latestPayloads(transport, kind: .terminalSession)[record]?["state_kind"] as? String, "running")

        XCTAssertEqual(publisher.takeDueCycle(now: clock.origin + .seconds(30)), .full)
        await publisher.run(.full)
        let published = try XCTUnwrap(try latestPayloads(transport, kind: .terminalSession)[record])
        XCTAssertEqual(published["state_kind"] as? String, "needs_approval")
        XCTAssertEqual(published["state_tone"] as? String, "orange")
        XCTAssertEqual(published["state_glyph"] as? String, "hand.raised.fill")
        XCTAssertEqual(transport.sendNowCalls, 0, "a session state leaves the send to CKSyncEngine")
    }

    /// #411 (PROJ-11: Agents working is never announced): a turn end with
    /// background agents running reaches the phone as `working` with the
    /// Mac's caption and glyph, and raises no `ask_alert`: the open ask's
    /// one alert went out before, and the state change adds none.
    func testAgentsWorkingPublishesAsWorkingAndRaisesNoAlert() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        // A workbench ask (no session, so the session's state stays its
        // own): the alert slice has a record to publish, once.
        _ = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: bench.project) }
        let center = makeCenter()
        let liveness = SessionLivenessBox()
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        _ = try HubIdentity(sidecar: sidecar).ensureEnabledAt(started)
        let wall = self.wall
        let publisher = SlicePublisher(
            dbPool: pool, state: sidecar, transport: transport.sealing(names: sidecar),
            sources: [terminalSlice(liveness), AskAlertSlice(sidecar: sidecar) { wall.now }]
        )
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
        let alerts = { try transport.openedSaves().filter { $0.record.kind == SliceKind.askAlert.rawValue }.count }
        XCTAssertEqual(try alerts(), 1, "the open ask's alert")

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

        XCTAssertFalse(log.nudges.isEmpty)
        XCTAssertTrue(
            log.nudges.allSatisfy { $0 == FastLane.stateChangeKinds },
            "a session state nudges only the ask kinds; it rides the full tick"
        )
        try await publisher.publishOnce(kinds: [.terminalSession, .askAlert])
        let record = SliceKind.terminalSession.recordName(id: String(row.id))
        let published = try XCTUnwrap(try latestPayloads(transport, kind: .terminalSession)[record])
        XCTAssertEqual(published["state_kind"] as? String, "working")
        XCTAssertEqual(published["state_caption"] as? String, "2 agents working")
        XCTAssertEqual(published["state_glyph"] as? String, "person.2.fill")
        XCTAssertEqual(published["state_tone"] as? String, "green")
        XCTAssertEqual(try alerts(), 1, "no second ask_alert")
    }

    /// #411 §10 (board #73): two failed staleness probes show the count over
    /// on the Mac with no write; the phone gets the same Stopped, through
    /// the liveness the fast lane copies — the row alone still says Agents
    /// working.
    func testACountShownOverAfterFailedProbesReachesThePhoneAsStopped() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        terminals.start(row, fresh: true)
        try countWrites(row.id, count: 2)
        wall.now = started.addingTimeInterval(2 + 31 * 60)
        let runner = ScriptedProbeRunner(json: ProbeAnswer.failed)
        let center = makeCenter(probeRunner: runner)
        let liveness = SessionLivenessBox()
        let transport = StubHubTransport()
        let publisher = SlicePublisher(
            dbPool: pool, state: try HubSyncState.inMemory(), transport: transport.sealing(), sources: [terminalSlice(liveness)]
        )
        let lane = makeLane(center, liveness: liveness) { publisher.nudge(kinds: $0) }
        lane.start()
        await center.poll()
        await awaitHubCondition("the first probe runs") { runner.invocations.count == 1 }
        try await publisher.publishOnce(kinds: [.terminalSession])
        let record = SliceKind.terminalSession.recordName(id: String(row.id))
        XCTAssertEqual(try latestPayloads(transport, kind: .terminalSession)[record]?["state_kind"] as? String, "working")

        wall.now = wall.now.addingTimeInterval(SessionBackgroundProber.retryAfter)
        await center.poll()
        await awaitHubCondition("two failed probes show the count over") {
            center.statuses[row.id]?.state == .live(.stopped)
        }
        XCTAssertEqual(Set(liveness.current.displayOver.keys), [row.id], "the lane copied the center's over set")
        try await publisher.publishOnce(kinds: [.terminalSession])
        let published = try XCTUnwrap(try latestPayloads(transport, kind: .terminalSession)[record])
        XCTAssertEqual(published["state_kind"] as? String, "stopped")
        XCTAssertEqual(published["state_caption"] as? String, "Stopped")

        // Review F8: a stopped center forgets what it showed over.
        lane.stop()
        center.stop()
        XCTAssertTrue(center.displayOver.isEmpty)
    }

    /// #411 (board #73): a count lowered to zero ages out on the clock alone,
    /// with no write. The full tick reaches the phone with no nudge (the
    /// slice judges at its own clock), and the center's poll nudges the
    /// fast lane's ask kinds (board #724).
    func testAZeroCountThatAgesOutReachesThePhoneOnTheTickAndTheFastLane() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        terminals.start(row, fresh: true)
        try countWrites(row.id, count: 0)
        let center = makeCenter()
        let liveness = SessionLivenessBox()
        let clock = FakeClock()
        let transport = StubHubTransport()
        let publisher = SlicePublisher(
            dbPool: pool, state: try HubSyncState.inMemory(), transport: transport.sealing(), sources: [terminalSlice(liveness)]
        ) { clock.now }
        let lane = makeLane(center, liveness: liveness) { publisher.nudge(kinds: $0) }
        lane.start()
        await center.poll()
        try await publisher.publishOnce()
        let record = SliceKind.terminalSession.recordName(id: String(row.id))
        XCTAssertEqual(try latestPayloads(transport, kind: .terminalSession)[record]?["state_caption"] as? String,
                       "Agents working", "within the grace")
        _ = publisher.takeDueCycle(now: clock.origin + .seconds(1))
        XCTAssertNil(publisher.fastDeadline)

        wall.now = started.addingTimeInterval(2 + SessionBackgroundPolicy.grace + 1)
        try await publisher.publishOnce()
        XCTAssertEqual(try latestPayloads(transport, kind: .terminalSession)[record]?["state_kind"] as? String,
                       "stopped", "the full tick alone, before any read or nudge")

        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.stopped))
        XCTAssertNotNil(publisher.fastDeadline, "the center's poll saw the same change and nudged the ask kinds")
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

    /// Board #724: a state change nudges the ask kinds once (Go's ask
    /// writes are not observed); an unchanged read nudges nothing.
    func testAStateChangeNudgesTheAskKinds() async throws {
        let bench = try await workbench()
        let row = try await session(in: bench)
        let center = makeCenter()
        let log = NudgeLog()
        let lane = makeLane(center) { log.record($0) }
        terminals.start(row, fresh: true)
        await center.poll()
        lane.start()

        try hookWrites([row.id], "approval", at: 1)
        await center.poll()
        XCTAssertEqual(log.nudges, [[.ownerAsk, .askAlert]])
        await center.poll()
        XCTAssertEqual(log.nudges, [[.ownerAsk, .askAlert]], "an unchanged read nudges nothing")
        XCTAssertTrue(FastLane.stateChangeKinds.isSubset(of: SlicePublisher.urgentKinds), "the publisher keeps these nudges")
    }

    func testStartCopiesTheLivenessAndNudgesNothing() async throws {
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
        XCTAssertEqual(log.nudges, [], "the session kinds ride the full tick")
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
        var laneSaw = 0
        let lane = makeLane(center, sessionStatesChanged: { laneSaw += 1 }, nudge: { _ in })
        lane.start()

        await center.poll()
        XCTAssertEqual(changes, 1, "the existing onChange fires")
        XCTAssertEqual(reads, 1, "the existing onRead fires")
        XCTAssertEqual(laneSaw, 1, "and the lane sees the change")

        lane.stop()
        terminals.start(row, fresh: true)
        try hookWrites([row.id], "working", at: 1)
        await center.poll()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(laneSaw, 1, "a stopped lane is unhooked")
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
        var laneSaw = 0
        let lane = makeLane(center, sessionStatesChanged: { laneSaw += 1 }, nudge: { _ in })
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

        let before = laneSaw
        try hookWrites([row.id], "working", at: 2)
        await center.poll()
        await awaitHubCondition("the held line goes") { process.inputs.count == 2 }
        XCTAssertEqual(process.inputs.last, [0x0D])
        XCTAssertGreaterThan(laneSaw, before, "the lane saw the change too")
    }

    // MARK: - Table observation

    /// Only the asks are observed: every other table's writes publish on
    /// the full tick, which a nudge could not bring forward.
    func testTheDesktopsOwnAskWritesNudgeTheAskKinds() async throws {
        XCTAssertEqual(FastLane.observedTables.map(\.table), ["owner_asks"])
        XCTAssertTrue(
            FastLane.observedTables.allSatisfy { $0.kinds.isSubset(of: SlicePublisher.urgentKinds) },
            "an observation nudges only kinds the fast lane keeps"
        )
        let bench = try await workbench()
        let log = NudgeLog()
        let lane = makeLane(nil) { log.record($0) }
        lane.start()
        await awaitHubCondition("every table is observed") { lane.observedTables == FastLane.observedTables.count }

        _ = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: bench.project) }
        await awaitHubCondition("an ask write nudges") { log.nudges.contains { $0.contains(.ownerAsk) } }
        XCTAssertTrue(
            log.nudges.contains { $0.isSuperset(of: [.ownerAsk, .askAlert]) },
            "a new or closed ask nudges its alert with it"
        )

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

    /// 30 live sessions changing state every second for 60 s (amended by
    /// board #724, owner decision Q3): the session kind is saved at most
    /// once per 30 s full tick, never with an immediate send, and the last
    /// published state of every session equals its last DB state at most
    /// one tick after the last change.
    func testReviewFocus5AStormOfStateChangesIsSavedAtMostOncePerTick() async throws {
        let bench = try await workbench()
        var rows: [TerminalSession] = []
        for _ in 0..<30 { rows.append(try await session(in: bench)) }
        let ids = rows.map(\.id)
        let center = makeCenter()
        let liveness = SessionLivenessBox()
        let clock = FakeClock()
        let transport = StubHubTransport()
        let publisher = SlicePublisher(
            dbPool: pool, state: try HubSyncState.inMemory(), transport: transport.sealing(),
            sources: [terminalSlice(liveness)],
            clock: { clock.now },
            sendNow: { await transport.sendNow() }
        )
        let lane = makeLane(center, liveness: liveness) { publisher.nudge(kinds: $0) }
        rows.forEach { terminals.start($0, fresh: true) }
        await center.poll()
        lane.start()

        let states = ["working", "approval", "waiting"]
        let wire = ["working": "working", "approval": "needs_approval", "waiting": "stopped"]
        var saves: [Duration] = []
        var lastChange = Duration.zero
        var lastState = ""
        let start = Duration.seconds(10)
        for step in 0...(90 * 4) {
            let offset = Duration.milliseconds(250 * step)
            clock.set(offset)
            if offset >= start, step.isMultiple(of: 4), (offset - start) < .seconds(60) {
                let second = Int((offset - start).components.seconds)
                lastState = states[second % states.count]
                try hookWrites(ids, lastState, at: Double(second + 1))
                await center.poll()
                lastChange = offset
            }
            let before = transport.saved.count
            if let cycle = publisher.takeDueCycle(now: clock.now) {
                await publisher.run(cycle)
            }
            if transport.saved.count > before { saves.append(offset) }
        }

        let ticks: [Duration] = [.zero, .seconds(30), .seconds(60), .seconds(90)]
        XCTAssertTrue(Set(saves).isSubset(of: ticks), "saved only at full ticks: \(saves)")
        XCTAssertTrue(saves.starts(with: [.zero, .seconds(30), .seconds(60)]), "the storm is sent, not starved")
        XCTAssertEqual(transport.sendNowCalls, 0, "session states never ask for an immediate send")
        XCTAssertLessThanOrEqual(.seconds(90) - lastChange, .seconds(30), "checked one full tick after the last change")
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
