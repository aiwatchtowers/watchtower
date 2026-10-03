import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The ⌘K go-to palette (board #252): ⌘↵ beside the focused pane, a
/// session of another workbench opened there, a move away during that
/// open, and the palette's sections.
@MainActor
final class WorkbenchGoToPaletteTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchGoToPaletteTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt goto \(UUID().uuidString)", isDirectory: true)
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
            let dir = try XCTUnwrap(WorkbenchQueries.fetch(db, id: projectID)).folderPath
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: title, folderPath: dir,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?",
                           arguments: [lastActiveAt, row.id])
            return try XCTUnwrap(TerminalSessionQueries.fetch(db, id: row.id))
        }
    }

    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    /// The palette's item for `session` (as ↵ would get it).
    private func item(for session: TerminalSession, in vm: WorkbenchesViewModel) throws -> GoToItem {
        try XCTUnwrap(vm.goToSections(query: "").flatMap(\.items).first { $0.id == "session-\(session.id)" })
    }

    // MARK: - ⌘↵

    func testOpenInSplitSplitsASinglePaneWithTheChosenSessionSecond() async throws {
        let a = try await workbench("alpha")
        let one = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let two = try await session(a, "two", lastActiveAt: "2026-09-02T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.showSession(id: one.id)
        XCTAssertFalse(vm.layout.isSplit)

        await vm.openInSplit(session: two)

        XCTAssertEqual(vm.layout.visiblePanes, [.session(one.id), .session(two.id)], "the focused one kept first")
        XCTAssertEqual(center.focusOrder.last, two.id)
        XCTAssertEqual(center.liveIDs, [one.id, two.id])
        XCTAssertEqual(center.keyboardFocusRequest?.sessionID, two.id, "the keyboard follows into it")
    }

    func testOpenInSplitReplacesTheUnfocusedPane() async throws {
        let a = try await workbench("alpha")
        let one = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let two = try await session(a, "two", lastActiveAt: "2026-09-02T10:00:00Z")
        let three = try await session(a, "three", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.showSession(id: one.id)
        vm.toggleSplit(projectID: a)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(one.id), .board])

        await vm.openInSplit(session: two)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(one.id), .session(two.id)], "the board was not in focus")

        // Two is focused now: one goes.
        await vm.openInSplit(session: three)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(three.id), .session(two.id)])
        XCTAssertEqual(center.focusOrder.last, three.id)
    }

    func testOpenInSplitOfASessionOnScreenOnlyFocusesIt() async throws {
        let a = try await workbench("alpha")
        let one = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let two = try await session(a, "two", lastActiveAt: "2026-09-02T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.showSession(id: one.id)
        await vm.openInSplit(session: two)
        let layout = vm.layout

        await vm.openInSplit(session: one)

        XCTAssertEqual(vm.layout, layout)
        XCTAssertEqual(center.focusOrder.last, one.id)
        XCTAssertEqual(center.keyboardFocusRequest?.sessionID, one.id,
                       "its terminal is attached already: only the request moves the keyboard back")
        XCTAssertEqual(launches.count, 2, "nothing restarts")
    }

    func testOpenInSplitIgnoresASessionOfAnotherWorkbench() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        let other = try await session(b, "other", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        let layout = vm.layout

        await vm.openInSplit(session: other)

        XCTAssertEqual(vm.layout, layout)
        XCTAssertEqual(vm.layout(projectID: b), .default)
        XCTAssertTrue(launches.isEmpty)
    }

    /// ↵ on the session already on screen: nothing moves, the keyboard
    /// goes back into its terminal.
    func testGoingToTheSessionOnScreenAsksForTheKeyboardBack() async throws {
        let a = try await workbench("alpha")
        let one = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.showSession(id: one.id)
        await vm.loadGoToPalette()
        let layout = vm.layout
        XCTAssertNil(center.keyboardFocusRequest)

        await vm.goTo(try item(for: one, in: vm))

        XCTAssertEqual(vm.layout, layout)
        XCTAssertEqual(center.keyboardFocusRequest?.sessionID, one.id)
    }

    /// A workbench row whose page shows the board only: no terminal to
    /// give the keyboard to.
    func testNoKeyboardRequestWithoutATerminalOnScreen() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.loadGoToPalette()
        let row = try XCTUnwrap(vm.goToSections(query: "").flatMap(\.items).first { $0.id == "workbench-\(b)" })

        await vm.goTo(row)

        XCTAssertEqual(vm.selectedWorkbenchID, b)
        XCTAssertNil(center.keyboardFocusRequest)
    }

    // MARK: - ↵ on another workbench

    func testGoingToASessionOfAnotherWorkbenchDrillsIntoItAndOpensTheSession() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        _ = try await session(b, "newer", lastActiveAt: "2026-09-03T10:00:00Z")
        let older = try await session(b, "older", lastActiveAt: "2026-09-02T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.loadGoToPalette()

        await vm.goTo(try item(for: older, in: vm))

        XCTAssertEqual(vm.selectedWorkbenchID, b)
        XCTAssertEqual(vm.drilledWorkbenchID, b)
        XCTAssertEqual(vm.panelSelection, .session(older.id), "the chosen row, not the most recent one")
        XCTAssertEqual(center.liveIDs, [older.id])
        XCTAssertEqual(center.keyboardFocusRequest?.sessionID, older.id)
    }

    func testGoingToAWorkbenchRowSwitchesToIt() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        let latest = try await session(b, "latest", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.loadGoToPalette()
        let row = try XCTUnwrap(vm.goToSections(query: "").flatMap(\.items).first { $0.id == "workbench-\(b)" })

        await vm.goTo(row)

        XCTAssertEqual(vm.selectedWorkbenchID, b)
        XCTAssertEqual(vm.panelSelection, .session(latest.id), "its most recent session (switchTo)")
        XCTAssertEqual(center.keyboardFocusRequest?.sessionID, latest.id)
    }

    /// The owner picks B's session while on A, then moves to C before B's
    /// sessions are read: nothing opens, on C least of all.
    func testGoingToAnotherWorkbenchOpensNothingAfterTheOwnerMovesOn() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        let c = try await workbench("gamma")
        let row = try await session(b, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.loadGoToPalette()
        let picked = try item(for: row, in: vm)
        let gate = holdFirstRead(of: b, vm)

        let going = Task { await vm.goTo(picked) }
        try await yieldUntil { gate.continuation != nil }
        XCTAssertEqual(vm.selectedWorkbenchID, b, "B's page shows while its sessions are read")
        vm.drill(into: c)
        let layoutC = vm.layout(projectID: c)
        gate.continuation?.resume()
        await going.value

        XCTAssertEqual(vm.selectedWorkbenchID, c)
        XCTAssertEqual(vm.layout(projectID: c), layoutC)
        XCTAssertEqual(vm.layout(projectID: b), .default, "B's layout is left alone")
        XCTAssertTrue(launches.isEmpty, "B's session is not started")
        XCTAssertEqual(vm.sessionActionErrors, [:])
        XCTAssertNil(center.keyboardFocusRequest, "the keyboard is not pulled into B")
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

    // MARK: - Data

    /// The page's sessions in the panel's (dragged) order, then the other
    /// workbenches; standalone terminals are not listed.
    func testTheSectionsFollowThePanelOrderAndLeaveStandaloneTerminalsOut() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        _ = try await session(a, "a-one", lastActiveAt: "2026-09-03T10:00:00Z")
        _ = try await session(a, "a-two", lastActiveAt: "2026-09-02T10:00:00Z")
        let bOne = try await session(b, "b-one", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.newStandalone(kind: .shell, folder: folder)
        await vm.reload()
        vm.drill(into: a)
        await vm.loadGoToPalette()
        let loaded = vm.orderedSessions(projectID: a)
        vm.moveSessions(loaded, projectID: a, from: [1], to: 0)

        let sections = vm.goToSections(query: "")
        XCTAssertEqual(sections.map(\.kind), [.currentSessions, .otherWorkbenches])
        XCTAssertEqual(sections[0].items.map(\.id), ["session-\(loaded[1].id)", "session-\(loaded[0].id)"])
        XCTAssertEqual(sections[1].items.map(\.id), ["workbench-\(b)", "session-\(bOne.id)"])

        XCTAssertEqual(vm.goToSections(query: "b-one").flatMap(\.items).map(\.id), ["session-\(bOne.id)"])
    }

    // MARK: - Views

    func testThePaletteShowsBothSectionsAndTheKeyHints() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        _ = try await session(a, "a-one", lastActiveAt: "2026-09-03T10:00:00Z")
        _ = try await session(b, "b-one", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.loadGoToPalette()

        let palette = GoToPalette(vm: vm) {}
        XCTAssertNoThrow(try palette.inspect().find(text: "SESSIONS · ALPHA"))
        XCTAssertNoThrow(try palette.inspect().find(text: "a-one"))
        XCTAssertNoThrow(try palette.inspect().find(text: "OTHER WORKBENCHES"))
        XCTAssertNoThrow(try palette.inspect().find(text: "beta"))
        XCTAssertNoThrow(try palette.inspect().find(text: "beta › b-one"))
        XCTAssertNoThrow(try palette.inspect().find(text: "↑↓ select   ↵ open   ⌘↵ open in split   esc close"))
        XCTAssertEqual(try palette.inspect().findAll(ViewType.Text.self) { try $0.string() == "↵" }.count, 1,
                       "only the selected row")
    }

    /// No workbench page (the empty state): no first section.
    func testWithoutAWorkbenchPageThePaletteListsOnlyOtherWorkbenches() async throws {
        let b = try await workbench("beta")
        _ = try await session(b, "b-one", lastActiveAt: "2026-09-01T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        await vm.loadGoToPalette()

        let palette = GoToPalette(vm: vm) {}
        XCTAssertThrowsError(try palette.inspect().find(ViewType.Text.self) { try $0.string().hasPrefix("SESSIONS") })
        XCTAssertNoThrow(try palette.inspect().find(text: "OTHER WORKBENCHES"))
        XCTAssertNoThrow(try palette.inspect().find(text: "beta › b-one"))
    }

    func testTheTitleRowOffersGoTo() async throws {
        let vm = makeVM()
        var opened = 0
        let row = WorkbenchTitleRow(
            vm: vm, switcherActions: WorkbenchSwitcherActions(newWorkbench: {}, showAll: {})
        ) { opened += 1 }

        try row.inspect().find(viewWithAccessibilityLabel: "Go to…").button().tap()

        XCTAssertEqual(opened, 1)
    }

    func testTheTitleRowShortcutsAreOffUnderThePalette() async throws {
        let vm = makeVM()
        let actions = WorkbenchSwitcherActions(newWorkbench: {}, showAll: {})

        let open = try WorkbenchTitleRow(vm: vm, switcherActions: actions, paletteOpen: true) {}
            .inspect().findAll(ViewType.Button.self)
        let closed = try WorkbenchTitleRow(vm: vm, switcherActions: actions, paletteOpen: false) {}
            .inspect().findAll(ViewType.Button.self)

        // The toggle, Go to…, ⌘T and ⌘1…⌘9 (⇧⌘O is Open Quickly's, R26).
        XCTAssertEqual(open.count, 3 + SessionSwitcherPresentation.maxShortcut)
        let goTo = { (button: InspectableView<ViewType.Button>) in
            (try? button.accessibilityLabel().string()) == "Go to…"
        }
        XCTAssertTrue(open.filter { !goTo($0) }.allSatisfy { $0.isDisabled() }, "nothing changes the page behind it")
        XCTAssertFalse(open.first(where: goTo)?.isDisabled() ?? true)
        // Closed: the toggle and Go to… work; the session keys need a page.
        let toggle = try XCTUnwrap(closed.first { (try? $0.accessibilityLabel().string()) == "Hide Sessions Panel" })
        XCTAssertFalse(toggle.isDisabled())
        XCTAssertEqual(closed.filter { !$0.isDisabled() }.count, 2)
    }

    // MARK: - Failed reads

    func testAFailedReadKeepsTheRowsBesideItsErrorsUntilTheNextSuccess() async throws {
        let a = try await workbench("alpha")
        let b = try await workbench("beta")
        _ = try await session(a, "a-one", lastActiveAt: "2026-09-03T10:00:00Z")
        _ = try await session(b, "b-one", lastActiveAt: "2026-09-02T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.loadGoToPalette()
        XCTAssertEqual(vm.goToErrors, [])
        let sessions = vm.goToSessions.map(\.id)

        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions RENAME TO terminal_sessions_away") }
        await vm.loadGoToPalette()

        // Its sessions, the switcher's rows and the page's own list all failed.
        XCTAssertEqual(vm.goToErrors.count, 3, "\(vm.goToErrors)")
        XCTAssertEqual(vm.goToSessions.map(\.id), sessions, "the last rows stay")
        XCTAssertEqual(vm.switcherSummaries.count, 2)
        let palette = GoToPalette(vm: vm) {}
        XCTAssertNoThrow(try palette.inspect().find(text: vm.goToErrors.joined(separator: "\n")))

        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions_away RENAME TO terminal_sessions") }
        await vm.loadGoToPalette()

        XCTAssertEqual(vm.goToErrors, [])
    }
}
