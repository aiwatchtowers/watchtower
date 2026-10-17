import AppKit
import GRDB
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board #731: the UI pollers skip their refreshes while no window is on
/// screen and refresh once on the way back; what the window shows never
/// waits a whole tick after it returns.
@MainActor
final class BackgroundRefreshTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() async throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: dbPath)
    }

    private var pool: DatabasePool { dbManager.dbPool }

    // MARK: - UIVisibilityCenter

    func testVisibilityFollowsTheWindowNotifications() async {
        let center = NotificationCenter()
        var windows = [UIVisibilityPolicy.Window(canBecomeMain: true, isVisible: true, isMiniaturized: false, isOccluded: false)]
        var evaluations = 0
        let visibility = UIVisibilityCenter(notificationCenter: center, windows: {
            evaluations += 1
            return windows
        }, appHidden: { false })
        var changes: [Bool] = []
        visibility.onChange = { changes.append($0) }
        visibility.start()
        XCTAssertTrue(visibility.isOnScreen)
        XCTAssertEqual(changes, [], "on screen from the start: no change")

        windows = [UIVisibilityPolicy.Window(canBecomeMain: true, isVisible: false, isMiniaturized: false, isOccluded: true)]
        center.post(name: NSWindow.willCloseNotification, object: nil)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await settle { !visibility.isOnScreen }
        XCTAssertEqual(changes, [false])
        XCTAssertEqual(evaluations, 2, "the start's, then one for two notifications in one turn")

        windows[0].isVisible = true
        windows[0].isOccluded = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await settle { visibility.isOnScreen }
        XCTAssertEqual(changes, [false, true])

        visibility.stop()
        let evaluated = evaluations
        windows = []
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await settle { false }
        XCTAssertEqual(evaluations, evaluated, "stopped: no longer follows")
        XCTAssertTrue(visibility.isOnScreen)
    }

    // MARK: - CalendarViewModel

    func testCalendarSkipsItsPollOffScreenAndLoadsOnTheWayBack() async throws {
        let vm = CalendarViewModel(dbPool: pool, historyDays: 1)
        vm.stopObserving()
        XCTAssertTrue(vm.dailyEvents.isEmpty)
        vm.setOnScreen(false)
        try await insertEventToday()

        await vm.pollTick()
        XCTAssertTrue(vm.dailyEvents.isEmpty, "off screen: the tick reads nothing")

        vm.setOnScreen(true)
        await vm.onScreenRefresh?.value
        XCTAssertEqual(vm.todayEvents.map(\.id), ["evt-today"])
        XCTAssertTrue(vm.isConnected)
    }

    func testCalendarOnScreenPollLoads() async throws {
        let vm = CalendarViewModel(dbPool: pool, historyDays: 1)
        vm.stopObserving()
        try await insertEventToday()
        await vm.pollTick()
        XCTAssertEqual(vm.todayEvents.map(\.id), ["evt-today"])
    }

    private func insertEventToday() async throws {
        let fmt = ISO8601DateFormatter()
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        try await pool.write { db in
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-today",
                startTime: fmt.string(from: start), endTime: fmt.string(from: start.addingTimeInterval(1800))
            )
        }
    }

    // MARK: - IdeasViewModel

    func testIdeasSkipItsPollOffScreenAndLoadOnTheWayBack() async throws {
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        vm.setOnScreen(false)
        try await pool.write { try TestDatabase.insertIdea($0, title: "Mined while away", status: "proposed") }

        await vm.pollTick()
        XCTAssertTrue(vm.reviewItems.isEmpty, "off screen: the tick reads nothing")

        vm.setOnScreen(true)
        await vm.onScreenRefresh?.value
        XCTAssertEqual(vm.reviewItems.map(\.title), ["Mined while away"])
    }

    // MARK: - WorkbenchesViewModel

    func testTheWorkbenchListSkipsThePollOffScreenAndReloadsOnTheWayBack() async throws {
        let p = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let suite = "BackgroundRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.reload()
        vm.setOnScreen(false)
        try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: p) }

        await vm.refreshOnPoll()
        XCTAssertEqual(vm.badgeCount, 0, "off screen: the poll does not reload the list")

        vm.setOnScreen(true)
        await vm.onScreenRefresh?.value
        XCTAssertEqual(vm.badgeCount, 1)
    }

    /// Off screen a workbench deleted elsewhere (the CLI) is still torn
    /// down at the next poll: its terminals close.
    func testAWorkbenchDeletedOffScreenIsStillTornDown() async throws {
        let p = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let suite = "BackgroundRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        var closed: [Int64] = []
        vm.closeTerminal = { closed.append($0) }
        await vm.reload()
        vm.setOnScreen(false)

        await vm.refreshOnPoll()
        XCTAssertEqual(closed, [], "nothing vanished: no reload")
        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [p]) }
        await vm.refreshOnPoll()
        XCTAssertEqual(closed, [p])
        XCTAssertTrue(vm.summaries.isEmpty)
    }

    // MARK: - AppState wiring

    /// What `AppState` hands the pollers: off screen they skip, back on
    /// screen each one refreshes.
    func testAppStateHandsTheVisibilityToEveryPoller() async throws {
        let appState = AppState.isolated()
        appState.initCalendar(dbPool: pool)
        appState.initIdeas(dbManager: dbManager)
        appState.initWorkbenches(
            dbPool: pool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        let calendar = try XCTUnwrap(appState.calendarViewModel)
        let ideas = try XCTUnwrap(appState.ideasViewModel)
        let workbenches = try XCTUnwrap(appState.workbenchesViewModel)
        defer {
            calendar.stopObserving()
            appState.workbenchNotificationCenter?.stop()
        }
        appState.applyUIVisibility(false)
        XCTAssertFalse(workbenches.codeFiles.isOnScreen)
        await calendar.pollTick()
        await ideas.pollTick()
        await workbenches.refreshOnPoll()
        appState.applyUIVisibility(true)
        XCTAssertTrue(workbenches.codeFiles.isOnScreen)

        XCTAssertNotNil(calendar.onScreenRefresh)
        XCTAssertNotNil(ideas.onScreenRefresh)
        XCTAssertNotNil(workbenches.onScreenRefresh)
        await calendar.onScreenRefresh?.value
        await ideas.onScreenRefresh?.value
        await workbenches.onScreenRefresh?.value
    }

    // MARK: - CodeFilesCenter

    func testFolderBatchesWaitOffScreenAndAreHandledOnceBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "all:\n".write(to: folder.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let suite = "BackgroundRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = Workbench(row: Row(["id": 7, "name": "acme", "folder_path": folder.path])).mainCodeRoot
        let center = CodeFilesCenter(defaults: defaults, gitRead: { _ in .noRepository }, gitMinInterval: .zero, watchesFolders: false)
        center.startWatching(root)
        let tree = center.tree(for: root)
        tree.loadIfNeeded()
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()

        center.setOnScreen(false)
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        center.receive(FolderWatcher.Batch(paths: ["Makefile"]), root: root)
        center.receive(FolderWatcher.Batch(paths: ["new.txt"]), root: root)
        XCTAssertEqual(buffer.text, "all:\n", "off screen: the batch waits")
        XCTAssertFalse(tree.rows.contains { $0.entry.relPath == "new.txt" })

        center.setOnScreen(true)
        XCTAssertEqual(buffer.text, "all: agent\n")
        XCTAssertTrue(tree.rows.contains { $0.entry.relPath == "new.txt" })
    }

    func testHeldBatchesMergeAndABusyFolderTurnsIntoARescan() {
        let merged = CodeFilesCenter.merge(
            FolderWatcher.Batch(paths: ["a"]), FolderWatcher.Batch(paths: ["b"], gitChanged: true)
        )
        XCTAssertEqual(merged, FolderWatcher.Batch(paths: ["a", "b"], gitChanged: true))
        let many = FolderWatcher.Batch(paths: Set((0 ... CodeFilesCenter.heldPathCap).map { "f\($0)" }))
        XCTAssertEqual(CodeFilesCenter.merge(merged, many), FolderWatcher.Batch(gitChanged: true, mustRescan: true))
    }

    /// Waits on state, not on a wall-clock margin.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0 ..< 20 where !condition() {
            await Task.yield()
        }
    }
}
