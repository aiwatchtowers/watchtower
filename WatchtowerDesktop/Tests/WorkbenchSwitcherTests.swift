import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The workbench switcher in the sessions panel's header (board #250,
/// variant F): what picking a workbench opens, "All Workbenches", the live
/// counts, and the header it replaces Back in.
@MainActor
final class WorkbenchSwitcherTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchSwitcherTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt switcher \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        center = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        return vm
    }

    private func workbench(_ name: String) async throws -> Int64 {
        let dir = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: name, folder: dir.path) }
    }

    private func session(_ projectID: Int64, _ title: String, lastActiveAt: String) async throws -> TerminalSession {
        try await pool.write { db in
            // A session starts only in a folder that exists: its workbench's.
            let dir = try XCTUnwrap(WorkbenchQueries.fetch(db, id: projectID)).folderPath
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: title, folderPath: dir,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?",
                           arguments: [lastActiveAt, row.id])
            return row
        }
    }

    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    // MARK: - switchTo

    func testSwitchingDrillsInAndResumesTheLatestActiveSession() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        _ = try await session(b, "older", lastActiveAt: "2026-09-01T10:00:00Z")
        let newer = try await session(b, "newer", lastActiveAt: "2026-09-02T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)

        await vm.switchTo(workbenchID: b)

        XCTAssertEqual(vm.selectedWorkbenchID, b)
        XCTAssertEqual(vm.drilledWorkbenchID, b)
        XCTAssertEqual(vm.panelSelection, .session(newer.id))
        XCTAssertEqual(center.liveIDs, [newer.id])
        XCTAssertEqual(launches.last?.args.last, "exec claude --resume \(try XCTUnwrap(newer.claudeSessionID))")
    }

    /// The live session the owner focused last wins over a newer one not running.
    func testSwitchingPrefersTheLiveFocusedSession() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        let focused = try await session(b, "focused", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: b)
        await vm.showFromPanel(sessionID: focused.id)
        center.focus(focused.id)
        let later = try await session(b, "later", lastActiveAt: "2099-01-01T00:00:00Z")
        vm.drill(into: a)

        await vm.switchTo(workbenchID: b)

        XCTAssertEqual(vm.panelSelection, .session(focused.id))
        XCTAssertFalse(center.liveIDs.contains(later.id), "the newer session is not started")
        XCTAssertEqual(launches.count, 1)
    }

    func testSwitchingToAWorkbenchWithoutSessionsStartsNothing() async throws {
        let a = try await workbench("alpha")
        let empty = try await workbench("empty")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)

        await vm.switchTo(workbenchID: empty)

        XCTAssertEqual(vm.drilledWorkbenchID, empty)
        XCTAssertNil(vm.panelSelection)
        XCTAssertTrue(launches.isEmpty)
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: empty) }
        XCTAssertTrue(rows.isEmpty, "no session is created")
    }

    /// The owner picks B, then moves to C while B's sessions are still being
    /// read: B's session must not open over C.
    func testSwitchingAwayDuringTheReadOpensNothing() async throws {
        let b = try await workbench("beta")
        let c = try await workbench("gamma")
        let stale = try await session(b, "beta work", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        var gate: CheckedContinuation<Void, Never>?
        var held = false
        // Only the switch's own read is held; a later read (an open's) passes.
        let db: DatabasePool = pool
        vm.readWorkbenchSessions = { projectID in
            if projectID == b, !held {
                held = true
                await withCheckedContinuation { gate = $0 }
            }
            return try await db.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: projectID) }
        }

        let switching = Task { await vm.switchTo(workbenchID: b) }
        try await yieldUntil { gate != nil }
        vm.drill(into: c)
        let selection = vm.panelSelection
        gate?.resume()
        await switching.value

        XCTAssertEqual(vm.drilledWorkbenchID, c)
        XCTAssertEqual(vm.panelSelection, selection)
        XCTAssertTrue(launches.isEmpty, "B's session is not started")
        XCTAssertFalse(center.liveIDs.contains(stale.id))
    }

    private func yieldUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within 5 s", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    func testPickingTheCurrentWorkbenchLeavesTheScreen() async throws {
        let a = try await workbench("alpha")
        _ = try await session(a, "one", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        vm.layout.show(.board)

        await vm.switchTo(workbenchID: a)

        XCTAssertEqual(vm.layout.visiblePanes, [.board])
        XCTAssertTrue(launches.isEmpty)
    }

    // MARK: - All workbenches, live counts, summaries

    func testShowAllWorkbenchesGoesToLevelOneAndKeepsThePage() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)

        vm.showAllWorkbenches()

        XCTAssertNil(vm.drilledWorkbenchID)
        XCTAssertEqual(vm.selectedWorkbenchID, a)
    }

    func testLiveCountsComeFromTheTerminalCenter() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        let one = try await session(a, "one", lastActiveAt: "2026-09-01T10:00:00Z")
        let two = try await session(a, "two", lastActiveAt: "2026-09-01T11:00:00Z")
        _ = try await session(b, "idle", lastActiveAt: "2026-09-01T12:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.showFromPanel(sessionID: one.id)
        await vm.showFromPanel(sessionID: two.id)
        XCTAssertEqual(vm.liveSessionCount(workbenchID: a), 2)
        XCTAssertEqual(vm.liveSessionCount(workbenchID: b), 0, "a session in the DB only is not live")

        processes.first?.exit(0)
        XCTAssertEqual(vm.liveSessionCount(workbenchID: a), 1, "an exited process no longer counts")
        XCTAssertEqual(WorkbenchesViewModel(dbPool: pool, cli: nil).liveSessionCount(workbenchID: a), 0,
                       "no terminal center, nothing live")
    }

    func testSwitcherSummariesLoadWithTheSessionCounts() async throws {
        let a = try await workbench("alpha")
        _ = try await workbench("beta")
        _ = try await session(a, "one", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()

        await vm.loadSwitcherSummaries()

        XCTAssertEqual(vm.switcherSummaries.map(\.project.name), ["alpha", "beta"])
        XCTAssertEqual(vm.switcherSummaries.first?.sessionCount, 1)
        XCTAssertNil(vm.switcherError)
    }

    // MARK: - Views

    private func panel(_ vm: WorkbenchesViewModel, _ project: Workbench) -> WorkbenchSessionsPanel {
        WorkbenchSessionsPanel(
            vm: vm, project: project,
            actions: SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in }),
            switcherActions: WorkbenchSwitcherActions(newWorkbench: {}, showAll: {})
        )
    }

    func testTheHeaderHasTheSwitcherAndNewSessionButNoBack() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        let project = try XCTUnwrap(vm.drilledWorkbench)
        let view = panel(vm, project)

        XCTAssertThrowsError(try view.inspect().find(viewWithAccessibilityLabel: "Back to Workbenches"))
        XCTAssertEqual(try view.inspect().find(WorkbenchSwitcherButton.self).actualView().name, "alpha")
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "New session"))
    }

    func testTheSwitcherButtonShowsTheNameAndCallsItsAction() throws {
        var taps = 0
        let button = WorkbenchSwitcherButton(name: "alpha") { taps += 1 }
        XCTAssertNoThrow(try button.inspect().find(text: "alpha"))
        try button.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(taps, 1)
    }

    func testARowChecksTheCurrentWorkbenchAndDrawsTheSegmentsAndTheLiveDot() async throws {
        let a = try await workbench("alpha")
        _ = try await session(a, "one", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.loadSwitcherSummaries()
        let row = try XCTUnwrap(vm.switcherSummaries.first)
        let segments = WorkbenchSwitcherPresentation.stateSegments(
            summary: row, newComments: 2, liveCount: 1, now: Date()
        )

        var picked = 0
        let current = WorkbenchSwitcherRow(row: row, isCurrent: true, segments: segments, isLive: true) { picked += 1 }
        XCTAssertNoThrow(try current.inspect().find(text: "alpha"))
        XCTAssertNoThrow(try current.inspect().find(text: "2 new comments"))
        XCTAssertNoThrow(try current.inspect().find(text: "1 session · 1 running"))
        XCTAssertNoThrow(try current.inspect().find(viewWithAccessibilityLabel: "Running"))
        try current.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(picked, 1)

        let other = WorkbenchSwitcherRow(row: row, isCurrent: false, segments: [], isLive: false) {}
        XCTAssertThrowsError(try other.inspect().find(viewWithAccessibilityLabel: "Running"))
    }
}
