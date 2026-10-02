import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The collapsible sessions panel and the collapsed title row's switchers
/// (board #251, variant H): the panel's persisted visibility, ⌘1…⌘9, ⌘T,
/// the session in focus, and which title the row shows.
@MainActor
final class WorkbenchHeaderSwitcherTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchHeaderSwitcherTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt header \(UUID().uuidString)", isDirectory: true)
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

    private func session(_ projectID: Int64, _ title: String, lastActiveAt: String, targetID: Int64? = nil) async throws
        -> TerminalSession {
        try await pool.write { db in
            let dir = try XCTUnwrap(WorkbenchQueries.fetch(db, id: projectID)).folderPath
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: title, folderPath: dir,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ?, target_id = ? WHERE id = ?",
                           arguments: [lastActiveAt, targetID, row.id])
            return try XCTUnwrap(TerminalSessionQueries.fetch(db, id: row.id))
        }
    }

    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    // MARK: - Panel visibility

    func testThePanelIsVisibleByDefault() {
        XCTAssertTrue(makeVM().panelVisible)
        XCTAssertNil(defaults.object(forKey: "projects.panelVisible"), "nothing is written until the owner toggles")
    }

    /// The owner-required test: the choice is kept under the key the view's
    /// `@AppStorage` used, and a new VM (the next launch) reads it back.
    func testPanelVisibilityPersistsUnderTheLegacyKeyAndSurvivesANewVM() {
        let vm = makeVM()
        vm.panelVisible = false
        XCTAssertEqual(defaults.object(forKey: "projects.panelVisible") as? Bool, false)
        XCTAssertFalse(makeVM().panelVisible)

        vm.panelVisible = true
        XCTAssertEqual(defaults.object(forKey: "projects.panelVisible") as? Bool, true)
        XCTAssertTrue(makeVM().panelVisible)
    }

    func testAHiddenPanelStoredByAnEarlierBuildIsRead() {
        defaults.set(false, forKey: "projects.panelVisible")
        XCTAssertFalse(makeVM().panelVisible)
    }

    func testShowAllWorkbenchesGoesToLevelOneAndShowsThePanel() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        vm.panelVisible = false

        vm.showAllWorkbenches()

        XCTAssertNil(vm.drilledWorkbenchID)
        XCTAssertEqual(vm.selectedWorkbenchID, a, "the page stays")
        XCTAssertTrue(vm.panelVisible)
        XCTAssertEqual(defaults.object(forKey: "projects.panelVisible") as? Bool, true)
    }

    // MARK: - ⌘1…⌘9

    /// Three sessions in a dragged order: ⌘N follows the panel's order,
    /// not recency.
    func testAShortcutOpensTheNthSessionInPanelOrder() async throws {
        let a = try await workbench("alpha")
        _ = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        _ = try await session(a, "two", lastActiveAt: "2026-09-02T10:00:00Z")
        _ = try await session(a, "three", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.loadSessions(projectID: a)
        let loaded = vm.drilledSessions
        vm.moveSessions(loaded, projectID: a, from: [2], to: 0)
        let ordered = vm.orderedSessions(projectID: a)
        XCTAssertEqual(ordered.map(\.id), [loaded[2], loaded[0], loaded[1]].map(\.id))

        await vm.openSession(atShortcut: 2)

        XCTAssertEqual(vm.panelSelection, .session(ordered[1].id))
        XCTAssertEqual(center.liveIDs, [ordered[1].id])
        XCTAssertEqual(launches.count, 1)
    }

    func testAShortcutOutOfRangeDoesNothing() async throws {
        let a = try await workbench("alpha")
        _ = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        _ = try await session(a, "two", lastActiveAt: "2026-09-02T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)

        for n in [0, 3, 9, 10, -1] {
            await vm.openSession(atShortcut: n)
        }

        XCTAssertNil(vm.panelSelection)
        XCTAssertTrue(launches.isEmpty)
    }

    func testShortcutsNeedAWorkbenchPage() async throws {
        let a = try await workbench("alpha")
        _ = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        XCTAssertFalse(vm.hasWorkbenchPage, "the empty state")

        await vm.openSession(atShortcut: 1)
        await vm.newPanelSession()
        XCTAssertTrue(launches.isEmpty)

        await vm.newStandalone(kind: .shell, folder: folder)
        XCTAssertFalse(vm.hasWorkbenchPage, "a standalone terminal")
        let before = launches.count
        await vm.openSession(atShortcut: 1)
        XCTAssertEqual(launches.count, before, "no workbench session opens over a standalone terminal")

        vm.drill(into: a)
        XCTAssertTrue(vm.hasWorkbenchPage)
    }

    /// With the panel hidden nothing read the list: the shortcut reads it.
    func testAShortcutReadsTheSessionsWhenNothingDidYet() async throws {
        let a = try await workbench("alpha")
        let only = try await session(a, "only", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        vm.terminalSessions[a] = nil

        await vm.openSession(atShortcut: 1)

        XCTAssertEqual(vm.panelSelection, .session(only.id))
    }

    /// The panel at level 1 with a page on screen (hidden there, or not):
    /// ⌘N and ⌘T still act on that page; the panel stays at level 1.
    func testShortcutsWorkWithThePanelAtLevelOne() async throws {
        let a = try await workbench("alpha")
        let only = try await session(a, "only", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        vm.showAllWorkbenches()
        vm.panelVisible = false

        await vm.openSession(atShortcut: 1)
        XCTAssertEqual(vm.headerSession?.id, only.id)
        XCTAssertEqual(center.liveIDs, [only.id])

        await vm.newPanelSession()
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: a) }
        XCTAssertEqual(rows.count, 2, "⌘T creates a session in the page's workbench")
        XCTAssertNil(vm.drilledWorkbenchID)
    }

    /// The owner presses ⌘2 on A, then moves to B while A's sessions are
    /// still being read: A's session must not open over B.
    func testAShortcutDuringTheReadOpensNothingAfterTheOwnerMovesOn() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        _ = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        _ = try await session(a, "two", lastActiveAt: "2026-09-02T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        vm.terminalSessions[a] = nil
        let gate = holdFirstRead(of: a, vm)

        let pressing = Task { await vm.openSession(atShortcut: 2) }
        try await yieldUntil { gate.continuation != nil }
        vm.drill(into: b)
        let layoutB = vm.layout(projectID: b)
        gate.continuation?.resume()
        await pressing.value

        XCTAssertEqual(vm.selectedWorkbenchID, b)
        XCTAssertEqual(vm.layout(projectID: b), layoutB)
        XCTAssertTrue(launches.isEmpty, "A's session is not started")
        XCTAssertEqual(vm.sessionActionErrors, [:], "a dropped press reports nothing, on B least of all")
    }

    /// A pick whose row is not loaded yet reads the list first; a move to
    /// another page meanwhile drops it.
    func testAPickDuringTheReadOpensNothingAfterTheOwnerMovesOn() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        let row = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        vm.terminalSessions[a] = nil
        let gate = holdFirstRead(of: a, vm)

        let picking = Task { await vm.showFromPanel(sessionID: row.id) }
        try await yieldUntil { gate.continuation != nil }
        vm.drill(into: b)
        let layoutB = vm.layout(projectID: b)
        gate.continuation?.resume()
        await picking.value

        XCTAssertEqual(vm.layout(projectID: b), layoutB)
        XCTAssertTrue(launches.isEmpty, "A's session is not started")
        XCTAssertNil(vm.sessionActionErrors[a], "a dropped pick reports nothing")
    }

    private final class ReadGate {
        var continuation: CheckedContinuation<Void, Never>?
        var held = false
    }

    /// Holds only the first read of `projectID`'s sessions; later reads pass.
    private func holdFirstRead(of projectID: Int64, _ vm: WorkbenchesViewModel) -> ReadGate {
        let gate = ReadGate()
        let db: DatabasePool = pool
        vm.readWorkbenchSessions = { id in
            if id == projectID, !gate.held {
                gate.held = true
                await withCheckedContinuation { gate.continuation = $0 }
            }
            return try await db.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        }
        return gate
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

    // MARK: - The session in focus

    func testTheHeaderSessionIsTheVisibleOneElseTheActiveOne() async throws {
        let a = try await workbench("alpha")
        let one = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        XCTAssertNil(vm.headerSession, "nothing opened yet")

        await vm.showFromPanel(sessionID: one.id)
        XCTAssertEqual(vm.headerSession?.id, one.id)

        vm.layout.show(.board)
        XCTAssertEqual(vm.headerSession?.id, one.id, "the board on screen: the active session")
    }

    // MARK: - Views

    private func titleRow(_ vm: WorkbenchesViewModel) -> WorkbenchTitleRow {
        WorkbenchTitleRow(vm: vm, switcherActions: WorkbenchSwitcherActions(newWorkbench: {}, showAll: {}))
    }

    func testAHiddenPanelPutsTheSwitchersInTheTitleRow() async throws {
        let a = try await workbench("alpha")
        let one = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.showFromPanel(sessionID: one.id)
        vm.panelVisible = false

        let row = titleRow(vm)
        XCTAssertEqual(try row.inspect().find(WorkbenchSwitcherButton.self).actualView().name, "alpha")
        XCTAssertEqual(try row.inspect().find(SessionSwitcherButton.self).actualView().title, "one")
        XCTAssertNoThrow(try row.inspect().find(viewWithAccessibilityLabel: "Show Sessions Panel"))
    }

    func testAShownPanelKeepsThePlainTitle() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)

        let row = titleRow(vm)
        XCTAssertNoThrow(try row.inspect().find(text: "alpha"))
        XCTAssertThrowsError(try row.inspect().find(WorkbenchSwitcherButton.self))
        XCTAssertThrowsError(try row.inspect().find(SessionSwitcherButton.self))
        XCTAssertNoThrow(try row.inspect().find(viewWithAccessibilityLabel: "Hide Sessions Panel"))
    }

    func testAHiddenPanelOverAStandaloneTerminalKeepsThePlainTitle() async throws {
        let vm = makeVM()
        await vm.newStandalone(kind: .shell, folder: folder)
        vm.panelVisible = false
        let title = try XCTUnwrap(vm.selectedStandalone?.title)

        let row = titleRow(vm)
        XCTAssertNoThrow(try row.inspect().find(text: title))
        XCTAssertThrowsError(try row.inspect().find(WorkbenchSwitcherButton.self))
    }

    func testTheSessionButtonSaysNoSessionWithoutOne() throws {
        var taps = 0
        let button = SessionSwitcherButton(title: nil, isLive: false) { taps += 1 }
        XCTAssertNoThrow(try button.inspect().find(text: "No session"))
        XCTAssertThrowsError(try button.inspect().find(viewWithAccessibilityLabel: "Running"))
        try button.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(taps, 1)

        XCTAssertNoThrow(try button.inspect().find(viewWithAccessibilityLabel: "No session"))

        // VoiceOver hears the state with the title, not as a separate element.
        let live = SessionSwitcherButton(title: "one", isLive: true) {}
        XCTAssertNoThrow(try live.inspect().find(viewWithAccessibilityLabel: "Session one, running"))
        let idle = SessionSwitcherButton(title: "one", isLive: false) {}
        XCTAssertNoThrow(try idle.inspect().find(viewWithAccessibilityLabel: "Session one, not running"))
    }

    func testASessionRowShowsItsBadgeCaptionAndShortcut() async throws {
        let a = try await workbench("alpha")
        let first = try await session(a, "first", lastActiveAt: "2026-09-03T10:00:00Z")
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: a, text: "Ship it") }
        let second = try await session(a, "second", lastActiveAt: "2026-09-03T10:00:00Z", targetID: target)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T10:00:00Z"))
        let rows = SessionSwitcherPresentation.rows([first, second], liveIDs: [first.id], now: now)

        var picked = 0
        let running = SessionSwitcherRow(row: rows[0], isCurrent: true) { picked += 1 }
        XCTAssertNoThrow(try running.inspect().find(text: "⌘1"))
        XCTAssertNoThrow(try running.inspect().find(viewWithAccessibilityLabel: "Running"))
        try running.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(picked, 1)

        let idle = SessionSwitcherRow(row: rows[1], isCurrent: false) {}
        XCTAssertNoThrow(try idle.inspect().find(text: "#\(target)"))
        XCTAssertNoThrow(try idle.inspect().find(text: "not started · 1d"))
        XCTAssertNoThrow(try idle.inspect().find(text: "⌘2"))
    }

    func testThePopoverSaysNoSessionsYetOnlyAfterASuccessfulRead() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        let project = try XCTUnwrap(vm.selectedWorkbench)
        let popover = SessionSwitcherPopover(
            vm: vm, project: project, currentID: nil, onSelect: { _ in }, onNewSession: {}, onShowPanel: {}
        )

        vm.terminalSessions[a] = nil
        XCTAssertThrowsError(try popover.inspect().find(text: "No sessions yet."), "the first read is in flight")

        vm.terminalSessions[a] = []
        vm.sessionLoadErrors[a] = "Could not load terminal sessions: boom"
        XCTAssertThrowsError(try popover.inspect().find(text: "No sessions yet."), "the read failed")
        XCTAssertNoThrow(try popover.inspect().find(text: "Could not load terminal sessions: boom"))

        vm.sessionLoadErrors[a] = nil
        XCTAssertNoThrow(try popover.inspect().find(text: "No sessions yet."))
    }
}
