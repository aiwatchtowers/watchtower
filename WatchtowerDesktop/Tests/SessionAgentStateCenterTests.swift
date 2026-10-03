import XCTest
import AppKit
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The reads a center made, by the ids asked for.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [[Int64]] = []
    var fail = false

    var reads: [[Int64]] { lock.withLock { asked } }

    func record(_ ids: [Int64]) throws {
        try lock.withLock {
            asked.append(ids)
            if fail { throw CancellationError() }
        }
    }
}

@MainActor
final class SessionAgentStateCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var terminals: TerminalCenter!
    private var log: ReadLog!
    private var centers: [SessionAgentStateCenter] = []
    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt agent \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        log = ReadLog()
        centers = []
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
        // No loop outlives its test.
        centers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeCenter(interval: Duration = .milliseconds(20)) -> SessionAgentStateCenter {
        let reader: SessionAgentStateCenter.Reader = { [pool, log] ids in
            try log?.record(ids)
            guard let pool else { return [] }
            return try await pool.read { try TerminalSessionQueries.fetchAgentStates($0, ids: ids) }
        }
        let center = SessionAgentStateCenter(dbPool: pool, terminalCenter: terminals, interval: interval, read: reader)
        centers.append(center)
        return center
    }

    private func session(_ kind: TerminalSession.Kind = .claude, title: String = "Release work") async throws
        -> TerminalSession {
        let dir = folder.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try await pool.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme", folder: dir)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: kind, title: title, folderPath: dir,
                claudeSessionID: kind == .claude ? UUID().uuidString.lowercased() : nil
            ))
        }
    }

    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    /// What the hook does: a write from another connection (in the app, another process).
    private func hookWrites(_ id: Int64, _ state: String, at offset: TimeInterval) throws {
        let other = try DatabaseQueue(path: path)
        try other.write { db in
            try db.execute(
                sql: "UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ? WHERE id = ?",
                arguments: [state, stamp(offset), id]
            )
        }
    }

    private func eventually(
        _ what: String, within timeout: Duration = .seconds(3), _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testNoLiveClaudeSessionReadsNothing() async throws {
        let center = makeCenter()
        center.start()
        await center.poll()
        let shell = try await session(.shell)
        terminals.start(shell, fresh: true)
        await center.poll()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.reads, [], "a live shell has no hooks to read")
        XCTAssertFalse(center.isPolling)
        XCTAssertEqual(center.statuses, [:])
    }

    func testPollStartsAndStopsWithLiveness() async throws {
        let center = makeCenter()
        center.start()
        XCTAssertFalse(center.isPolling)
        let row = try await session()
        terminals.start(row, fresh: true)
        await eventually("the loop starts with a live claude session") { center.isPolling }
        await eventually("it reads the live session") { log.reads.contains([row.id]) }
        processes.last?.exit(0)
        await eventually("the loop stops with the last session") { !center.isPolling }
        let count = log.reads.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.reads.count, count, "no reads once nothing is live")
    }

    func testAHookWriteIsPublishedWithinATick() async throws {
        let center = makeCenter()
        center.start()
        let row = try await session()
        terminals.start(row, fresh: true)
        await eventually("the first poll ran") { center.statuses[row.id]?.state == .running }
        try hookWrites(row.id, "waiting", at: 1)
        await eventually("the waiting state shows", within: .seconds(1)) {
            center.statuses[row.id]?.state == .waitingForOwner
        }
        XCTAssertEqual(center.statuses[row.id]?.title, "Release work")
        XCTAssertEqual(center.statuses[row.id]?.at, stamp(1))
        try hookWrites(row.id, "approval", at: 2)
        await eventually("approval shows") { center.statuses[row.id]?.state == .needsApproval }
    }

    func testAnUnchangedReadDoesNotReassignStatuses() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "working", at: 1)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .working)
        var changed = false
        withObservationTracking { _ = center.statuses } onChange: { changed = true }
        await center.poll()
        await center.poll()
        XCTAssertFalse(changed, "an unchanged read re-renders nothing")
        try hookWrites(row.id, "waiting", at: 2)
        await center.poll()
        XCTAssertTrue(changed)
    }

    /// Decision 9 end to end: a state the previous run wrote is not shown
    /// after a Restart; the new run's first hook is.
    func testAStateFromBeforeARestartIsIgnoredAfterIt() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "waiting", at: 1)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .waitingForOwner)

        processes.last?.exit(0)
        await center.poll()
        XCTAssertNil(center.statuses[row.id], "an exited session has no status")

        terminals.now = { [started] in started.addingTimeInterval(10) }
        terminals.start(row, fresh: false)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .running, "the earlier run's waiting is not trusted")
        try hookWrites(row.id, "working", at: 11)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .working)
    }

    func testExitDropsTheStatusWhileOtherSessionsRun() async throws {
        let center = makeCenter()
        let first = try await session(title: "One")
        let second = try await session(title: "Two")
        terminals.start(first, fresh: true)
        terminals.start(second, fresh: true)
        try hookWrites(first.id, "waiting", at: 1)
        try hookWrites(second.id, "working", at: 1)
        await center.poll()
        XCTAssertEqual(Set(center.statuses.keys), [first.id, second.id])
        processes.first?.exit(0)
        await center.poll()
        XCTAssertEqual(Set(center.statuses.keys), [second.id])
        XCTAssertEqual(log.reads.last, [second.id], "only live sessions are read")
    }

    func testAReadFailureKeepsTheLastMapOfLiveSessions() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "approval", at: 1)
        await center.poll()
        log.fail = true
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .needsApproval, "a failed read keeps the last map")
        processes.last?.exit(0)
        await center.poll()
        XCTAssertNil(center.statuses[row.id])
    }

    func testStartedAtIsSetOnStartAndReplacedOnRelaunch() async throws {
        let row = try await session()
        terminals.start(row, fresh: true)
        XCTAssertEqual(terminals.startedAt[row.id], started)
        XCTAssertEqual(terminals.liveClaudeIDs, [row.id])
        processes.last?.exit(0)
        XCTAssertEqual(terminals.liveClaudeIDs, [])
        terminals.now = { [started] in started.addingTimeInterval(60) }
        terminals.start(row, fresh: false)
        XCTAssertEqual(terminals.startedAt[row.id], started.addingTimeInterval(60))
        await terminals.close(sessionID: row.id)
        XCTAssertNil(terminals.startedAt[row.id], "forgotten with the session")
    }

    /// House rule: the poll lives on AppState, so a state change is still
    /// published while the owner is on another tab.
    func testTheCenterLivesOnAppStateAndPollsWithTheTabNotShown() async throws {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.terminalCenter.shell = { "/bin/zsh" }
        appState.terminalCenter.transcriptExists = { _ in true }
        appState.terminalCenter.now = { [started] in started }
        appState.initWorkbenches(dbPool: pool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier())
        defer {
            appState.sessionAgentStateCenter?.stop()
            appState.workbenchNotificationCenter?.stop()
        }
        let center = try XCTUnwrap(appState.sessionAgentStateCenter)
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        XCTAssertTrue(vm.agentStates === center, "the VM reads the AppState-owned center")

        appState.selectedDestination = .workbench
        let row = try await session()
        appState.terminalCenter.start(row, fresh: true)
        appState.selectedDestination = .inbox
        try hookWrites(row.id, "waiting", at: 1)
        await eventually("published with the Workbench tab not shown") {
            center.statuses[row.id]?.state == .waitingForOwner
        }
        appState.selectedDestination = .workbench
        XCTAssertEqual(vm.sessionState(row), .waitingForOwner)
    }

    // MARK: - Views

    func testThePanelRowShowsTheAgentStateOrTheAge() async throws {
        let created = try await session()
        let stampAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-(5 * 60 + 3)))
        let session = try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?",
                           arguments: [stampAgo, created.id])
            return try XCTUnwrap(TerminalSessionQueries.fetch(db, id: created.id))
        }
        let id = session.id
        let status = SessionAgentStatus(sessionID: id, workbenchID: session.projectID, workbenchName: "acme",
                                        title: session.title, state: .waitingForOwner, at: "t")
        let actions = SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in })

        let waiting = SessionSwitcherPresentation.rows([session], liveIDs: [id], statuses: [id: status], now: Date())[0]
        let live = TerminalSessionRow(row: waiting, actions: actions)
        XCTAssertNoThrow(try live.inspect().find(text: "waiting for you"))
        let dot = try live.inspect().find(SessionLiveDot.self)
        XCTAssertEqual(try dot.actualView().state, .waitingForOwner)
        XCTAssertEqual(try dot.find(ViewType.Image.self).foregroundStyleShapeStyle(Color.self), .orange)
        XCTAssertNoThrow(try live.inspect().find(viewWithAccessibilityLabel: "Waiting for you"))

        let dead = SessionSwitcherPresentation.rows([session], liveIDs: [], statuses: [id: status], now: Date())[0]
        let idle = TerminalSessionRow(row: dead, actions: actions)
        XCTAssertNoThrow(try idle.inspect().find(text: "not started · 5m"))
        XCTAssertThrowsError(try idle.inspect().find(text: "waiting for you"))
        XCTAssertNoThrow(try idle.inspect().find(viewWithAccessibilityLabel: "Not running"))
    }

    func testTheDotColourAndLabelPerState() throws {
        let expected: [(SessionSwitcherPresentation.State, Color, String)] = [
            (.running, .green, "Running"),
            (.working, .green, "Working"),
            (.waitingForOwner, .orange, "Waiting for you"),
            (.needsApproval, .orange, "Needs approval"),
            (.notStarted, .secondary, "Not running")
        ]
        for (state, color, label) in expected {
            let image = try SessionLiveDot(state: state).inspect().find(ViewType.Image.self)
            XCTAssertEqual(try image.foregroundStyleShapeStyle(Color.self), color, "\(state)")
            XCTAssertNoThrow(try SessionLiveDot(state: state).inspect().find(viewWithAccessibilityLabel: label))
        }
    }
}
