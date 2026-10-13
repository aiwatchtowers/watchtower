import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The sessions panel's main list and "▸ N finished" group as the view
/// model serves them (board #480, spec 2026-10-12-sessions-panel-design
/// §3): the remembered fold, ⌘1…⌘9, the drag, the on-screen session that
/// never jumps, and the one order the switcher and ⌘K share. No subprocess
/// is spawned: the terminal center runs fake processes, the states come
/// from a fixed reader.
@MainActor
final class WorkbenchesViewModelPanelSectionsTests: XCTestCase {
    /// The rows the state center reads, set by the test.
    private final class StateRows: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SessionAgentStateRow] = []
        var value: [SessionAgentStateRow] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var center: TerminalCenter!
    private var rows: StateRows!
    private var agentStates: SessionAgentStateCenter!
    private var projectID: Int64 = 0

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelPanelSectionsTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt sections \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        center = TerminalCenter { FakeTerminalSession(pid: 0) }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
        let rows = StateRows()
        self.rows = rows
        agentStates = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: center, interval: .seconds(3600),
            notifier: RecordingSessionNotifier(), defaults: defaults, notificationCenter: NotificationCenter()
        ) { _ in rows.value }
        projectID = try await workbench("acme")
    }

    override func tearDown() async throws {
        agentStates.stop()
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
    }

    // MARK: - Harness

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center, agentStates: agentStates)
        vm.titleService = { _ in .init(title: "", written: false) }
        return vm
    }

    private func workbench(_ name: String) async throws -> Int64 {
        let path = folder.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: name, folder: path) }
    }

    private func insertSession(_ title: String) async throws -> TerminalSession {
        let projectID = projectID
        let folderPath = folder.path
        return try await pool.write {
            try TerminalSessionQueries.create($0, .init(
                projectID: projectID, kind: .claude, title: title, folderPath: folderPath,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    /// A state row; `finishedAt` set = finished (with no open ask: the group).
    private func stateRow(_ session: TerminalSession, finishedAt: String? = nil) -> SessionAgentStateRow {
        SessionAgentStateRow(id: session.id, projectID: projectID, title: session.title, agentState: nil,
                             agentStateAt: nil, workbenchName: "acme", finishedAt: finishedAt)
    }

    /// The states read now, as the poll would.
    private func setStates(_ next: [SessionAgentStateRow]) async {
        rows.value = next
        await agentStates.poll()
    }

    /// The workbench page with its list loaded.
    private func page(_ vm: WorkbenchesViewModel) async {
        await vm.reload()
        vm.selectedWorkbenchID = projectID
        await vm.loadSessions(projectID: projectID)
    }

    private func putOnScreen(_ session: TerminalSession, _ vm: WorkbenchesViewModel) {
        var layout = WorkspaceLayout.default
        layout.primary = .session(session.id)
        vm.setLayout(layout, projectID: projectID)
    }

    private func onScreen(_ vm: WorkbenchesViewModel) -> WorkspacePane? {
        vm.layout(projectID: projectID).visiblePanes.first
    }

    // MARK: - Tests

    func testFinishedFoldIsRememberedPerWorkbench() async throws {
        let other = try await workbench("beta")
        let vm = makeVM()
        XCTAssertFalse(vm.isFinishedGroupExpanded(projectID: projectID), "folded until the owner opens it")
        vm.setFinishedGroupExpanded(true, projectID: projectID)
        XCTAssertTrue(vm.isFinishedGroupExpanded(projectID: projectID))
        XCTAssertTrue(vm.panelSections(projectID: projectID).expanded)
        XCTAssertFalse(vm.isFinishedGroupExpanded(projectID: other), "per workbench")

        let relaunched = makeVM()
        XCTAssertTrue(relaunched.isFinishedGroupExpanded(projectID: projectID), "remembered across launches")
        XCTAssertFalse(relaunched.isFinishedGroupExpanded(projectID: other))
        relaunched.setFinishedGroupExpanded(false, projectID: projectID)
        XCTAssertFalse(makeVM().isFinishedGroupExpanded(projectID: projectID))
    }

    /// ⌘2 is the second main row; a folded group's rows have no number,
    /// an open group's follow the main list.
    func testShortcutOpensTheNumberedRowWithTheGroupFolded() async throws {
        let done = try await insertSession("Session A")
        let second = try await insertSession("Session B")
        let first = try await insertSession("Session C")
        let vm = makeVM()
        await page(vm)
        await setStates([stateRow(done, finishedAt: "2026-10-12T10:00:00.000Z")])
        XCTAssertEqual(vm.panelSections(projectID: projectID).shortcutOrder, [first.id, second.id])

        await vm.openSession(atShortcut: 2)
        XCTAssertEqual(onScreen(vm), .session(second.id))
        await vm.openSession(atShortcut: 3)
        XCTAssertEqual(onScreen(vm), .session(second.id), "a folded group's row is unreachable by ⌘N")

        vm.setFinishedGroupExpanded(true, projectID: projectID)
        await vm.openSession(atShortcut: 3)
        XCTAssertEqual(onScreen(vm), .session(done.id), "the open group is numbered after the main list")
    }

    /// A drag in the main list keeps a group session's saved slot: once it
    /// leaves the group it is back where it was.
    func testDragInMainKeepsAGroupSessionsSlot() async throws {
        let a = try await insertSession("Session A")
        let b = try await insertSession("Session B")
        let c = try await insertSession("Session C")
        let vm = makeVM()
        await page(vm)
        vm.moveSessions(vm.orderedSessions(projectID: projectID), projectID: projectID, from: [0], to: 3)
        XCTAssertEqual(vm.orderedSessions(projectID: projectID).map(\.id), [b.id, a.id, c.id])

        await setStates([stateRow(a, finishedAt: "2026-10-12T10:00:00.000Z")])
        let main = vm.panelSections(projectID: projectID).main.map(\.session)
        XCTAssertEqual(main.map(\.id), [b.id, c.id])
        vm.moveSessions(main, projectID: projectID, from: [1], to: 0)
        XCTAssertEqual(vm.panelSections(projectID: projectID).main.map(\.id), [c.id, b.id])

        await setStates([stateRow(a)])
        XCTAssertEqual(vm.panelSections(projectID: projectID).main.map(\.id), [c.id, a.id, b.id],
                       "resumed: back in its own slot, not on top")
    }

    /// §3.3: the session on screen finishing stays in its main-list slot;
    /// once another session comes on screen it moves to the group.
    func testSessionFinishingOnScreenStaysInMainUntilSwitchedAway() async throws {
        let a = try await insertSession("Session A")
        let b = try await insertSession("Session B")
        let vm = makeVM()
        await page(vm)
        putOnScreen(a, vm)
        await setStates([stateRow(a), stateRow(b)])
        XCTAssertEqual(vm.panelSections(projectID: projectID).main.map(\.id), [b.id, a.id])

        await setStates([stateRow(a, finishedAt: "2026-10-12T10:00:00.000Z"), stateRow(b)])
        let kept = vm.panelSections(projectID: projectID)
        XCTAssertEqual(kept.main.map(\.id), [b.id, a.id], "does not jump under the owner's eyes")
        XCTAssertEqual(kept.finishedCount, 0)

        putOnScreen(b, vm)
        let moved = vm.panelSections(projectID: projectID)
        XCTAssertEqual(moved.main.map(\.id), [b.id])
        XCTAssertEqual(moved.finishedCount, 1)
        XCTAssertNil(moved.pinned, "not on screen: nothing pinned")

        putOnScreen(a, vm)
        let pinned = vm.panelSections(projectID: projectID)
        XCTAssertEqual(pinned.pinned?.id, a.id, "back on screen from the folded group: pinned under its header")
        XCTAssertEqual(pinned.main.map(\.id), [b.id])
    }

    func testGoToCurrentSectionListsMainThenFinished() async throws {
        let a = try await insertSession("Session A")
        let b = try await insertSession("Session B")
        let c = try await insertSession("Session C")
        let vm = makeVM()
        await page(vm)
        await setStates([
            stateRow(a, finishedAt: "2026-10-12T09:00:00.000Z"), stateRow(c, finishedAt: "2026-10-12T10:00:00.000Z")
        ])
        await vm.loadGoToPalette()
        let current = try XCTUnwrap(vm.goToSections(query: "").first)
        XCTAssertEqual(current.kind, .currentSessions)
        XCTAssertEqual(current.items.map(\.id), ["session-\(b.id)", "session-\(c.id)", "session-\(a.id)"],
                       "the main list, then the group newest finished first — folded or not")
    }

    func testSwitcherListsFinishedAfterTheMainRows() async throws {
        let a = try await insertSession("Session A")
        let b = try await insertSession("Session B")
        let c = try await insertSession("Session C")
        let vm = makeVM()
        await page(vm)
        await setStates([stateRow(b, finishedAt: "2026-10-12T10:00:00.000Z")])
        let sections = vm.panelSections(projectID: projectID)
        XCTAssertEqual(sections.main.map(\.id), [c.id, a.id])
        XCTAssertEqual(sections.groupRows.map(\.id), [b.id], "listed by the switcher while folded in the panel")
        XCTAssertEqual(sections.searchRows.map(\.shortcut), [1, 2, nil])
        XCTAssertEqual(vm.panelOrderedSessions(projectID: projectID).map(\.id), [c.id, a.id, b.id])
    }
}
