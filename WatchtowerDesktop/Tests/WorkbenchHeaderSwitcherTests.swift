import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The collapsible sessions panel and the collapsed title row's switcher
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
        let loaded = vm.panelSections(projectID: a).main.map(\.session)
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
        await vm.newSessionOnPage()
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

        await vm.newSessionOnPage()
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

        let picking = Task { await vm.showSession(id: row.id) }
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

        await vm.showSession(id: one.id)
        XCTAssertEqual(vm.headerSession?.id, one.id)

        vm.layout.show(.board)
        XCTAssertEqual(vm.headerSession?.id, one.id, "the board on screen: the active session")
    }

    // MARK: - Views

    /// The panel-hidden back button, found by its help (ViewInspector reads
    /// a Button's help, not its accessibility label, on this SDK).
    private static func isBackButton(_ button: InspectableView<ViewType.Button>) throws -> Bool {
        try button.help().string() == "All Workbenches (⌘[)"
    }

    private func titleRow(_ vm: WorkbenchesViewModel) -> WorkbenchTitleRow<EmptyView> {
        WorkbenchTitleRow(vm: vm, switcherActions: WorkbenchSwitcherActions(openFolder: {}, showAll: {})) {}
    }

    /// Spec 2026-10-20 calls 5 and 11: with the panel hidden the title row
    /// carries the workbench switcher only; the session's switcher is the
    /// sessions menu on its pane's strip.
    func testHiddenPanelTitleRowHasTheWorkbenchSwitcherAndNoSessionSwitcher() async throws {
        let a = try await workbench("alpha")
        let one = try await session(a, "one", lastActiveAt: "2026-09-03T10:00:00Z")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        await vm.showSession(id: one.id)
        vm.panelVisible = false

        let row = titleRow(vm)
        XCTAssertEqual(try row.inspect().find(WorkbenchSwitcherButton.self).actualView().name, "alpha")
        XCTAssertThrowsError(try row.inspect().find(WorkbenchSessionsMenu.self))
        XCTAssertThrowsError(try row.inspect().find(text: "one"), "no session in the title row")
        XCTAssertThrowsError(try row.inspect().find(ViewType.Image.self) { try $0.actualImage().name() == "chevron.right" },
                             "no workbench › session chevron")
        XCTAssertNoThrow(try row.inspect().find(ViewType.Button.self) { try $0.help().string() == "Show Sessions Panel (⌥⌘S)" })
    }

    /// Board #743: with the panel hidden the list is one click away in the
    /// title row; with it shown, the panel's own header has the button.
    func testAHiddenPanelPutsTheBackButtonInTheTitleRow() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)
        var shown = 0
        let actions = WorkbenchSwitcherActions(openFolder: {}, showAll: { shown += 1 })

        XCTAssertThrowsError(
            try WorkbenchTitleRow(vm: vm, switcherActions: actions) {}.inspect()
                .find(ViewType.Button.self, where: Self.isBackButton)
        )

        vm.panelVisible = false
        let back = try WorkbenchTitleRow(vm: vm, switcherActions: actions) {}.inspect()
            .find(ViewType.Button.self, where: Self.isBackButton)
        try back.tap()
        XCTAssertEqual(shown, 1)

        // Over a standalone terminal too: the list is still one click away.
        await vm.newStandalone(kind: .shell, folder: folder)
        XCTAssertNoThrow(
            try WorkbenchTitleRow(vm: vm, switcherActions: actions) {}.inspect()
                .find(ViewType.Button.self, where: Self.isBackButton)
        )
    }

    /// ⌘[ (board #743, the Workbench menu since issue #288): on while the
    /// list is off screen, off under the Go to… palette.
    func testCommandBracketGoesBackWhileTheListIsOffScreen() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.panelVisible = true
        func canGoBack(paletteOpen: Bool = false) -> Bool {
            WorkbenchMenuContext(vm: vm, paletteOpen: paletteOpen) {}.canGoBack
        }

        XCTAssertFalse(canGoBack(), "level 1 on screen")

        vm.drill(into: a)
        XCTAssertTrue(canGoBack())
        XCTAssertFalse(canGoBack(paletteOpen: true), "nothing changes the page behind the palette")

        vm.showAllWorkbenches()
        vm.panelVisible = false
        XCTAssertTrue(canGoBack(), "a hidden panel hides the list")
    }

    func testAShownPanelKeepsThePlainTitle() async throws {
        let a = try await workbench("alpha")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: a)

        let row = titleRow(vm)
        XCTAssertNoThrow(try row.inspect().find(text: "alpha"))
        XCTAssertThrowsError(try row.inspect().find(WorkbenchSwitcherButton.self))
        XCTAssertNoThrow(try row.inspect().find(ViewType.Button.self) { try $0.help().string() == "Hide Sessions Panel (⌥⌘S)" })
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

    /// The state label (the panel row's, the report line's): the state's
    /// glyph and caption, the ask count by the glyph, never a 0 beside
    /// `person.2.fill`.
    func testTheStateLabelShowsTheGlyphCaptionAndAskCount() throws {
        let waiting = SessionStateLabel(state: SessionSwitcherPresentation.State(
            kind: .waitingOnAsk, live: false, openAsks: 1, oldestAskID: 12
        ))
        XCTAssertNoThrow(try waiting.inspect().find(text: "Waiting for you · ask #12"))
        XCTAssertEqual(try waiting.inspect().find(ViewType.Image.self).actualImage().name(), "questionmark")

        let working = SessionStateLabel(state: .live(.working, openAsks: 2, oldestAskID: 4))
        XCTAssertNoThrow(try working.inspect().find(text: "2"), "the ask count by the glyph")
        XCTAssertNoThrow(try working.inspect().find(text: "Working · 2 asks open"))

        let background = SessionStateLabel(state: .live(.background, backgroundAgents: 3))
        XCTAssertNoThrow(try background.inspect().find(text: "3 agents working"))
        XCTAssertEqual(try background.inspect().find(ViewType.Image.self).actualImage().name(), "person.2.fill")
        XCTAssertThrowsError(try background.inspect().find(text: "0"), "no ask count beside person.2.fill")
        let backgroundAsks = SessionStateLabel(
            state: .live(.background, openAsks: 2, oldestAskID: 4, backgroundAgents: 1)
        )
        XCTAssertEqual(try backgroundAsks.inspect().find(ViewType.Image.self).actualImage().name(), "questionmark")
        XCTAssertNoThrow(try backgroundAsks.inspect().find(text: "2"), "the ask count by the glyph")
        XCTAssertNoThrow(try backgroundAsks.inspect().find(text: "1 agent working · 2 asks open"))
    }
}
