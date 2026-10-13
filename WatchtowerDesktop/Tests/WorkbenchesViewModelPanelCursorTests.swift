import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The sessions panel's keyboard as the view model serves it (board #480,
/// spec 2026-10-12-sessions-panel-design §4.4): the cursor, ⌘⌫ with or
/// without the confirmation, the neighbour after a delete, Esc and the
/// toast's batch. No subprocess is spawned: the terminal center runs fake
/// processes; the Undo window never ends on its own (cancelled in tearDown).
@MainActor
final class WorkbenchesViewModelPanelCursorTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var center: TerminalCenter!
    private var projectID: Int64 = 0
    private var models: [WorkbenchesViewModel] = []

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelPanelCursorTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt cursor \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        center = TerminalCenter { FakeTerminalSession(pid: 0) }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
        models = []
        let path = folder.appendingPathComponent("acme").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        projectID = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: path) }
    }

    override func tearDown() async throws {
        for vm in models { vm.deleteCommitTask?.cancel() }
        models = []
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
    }

    // MARK: - Harness

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        // The Undo window stays open for the whole test.
        vm.deleteSleep = { try? await Task.sleep(for: $0 * 720) }
        models.append(vm)
        return vm
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

    /// Three sessions not running, listed newest first: C, B, A.
    private func threeRows(_ vm: WorkbenchesViewModel) async throws -> (TerminalSession, TerminalSession, TerminalSession) {
        let a = try await insertSession("Session A")
        let b = try await insertSession("Session B")
        let c = try await insertSession("Session C")
        await page(vm)
        XCTAssertEqual(vm.panelSections(projectID: projectID).visibleOrder, [c.id, b.id, a.id])
        return (a, b, c)
    }

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

    // MARK: - Tests

    /// ⌘⌫, the ✕ and a confirmed Delete… all move the cursor to the next
    /// row, else the previous one, so the owner clears in a row.
    func testDeleteMovesThePanelCursorToTheNeighbour() async throws {
        let vm = makeVM()
        let (a, b, c) = try await threeRows(vm)
        vm.panelCursor = b.id

        let intent = await vm.deleteAtPanelCursor(projectID: projectID)
        XCTAssertEqual(intent, .quick, "not running: deleted at once")
        XCTAssertEqual(vm.panelCursor, a.id, "⌘⌫: the next row")

        XCTAssertTrue(vm.isQuickDelete(a), "the ✕ shows and deletes at once")
        await vm.delete(a)
        XCTAssertEqual(vm.panelCursor, c.id, "✕ on the last row: the previous one")

        await vm.delete(c) // Delete… confirmed
        XCTAssertNil(vm.panelCursor, "nothing left")
        XCTAssertEqual(vm.pendingDeleteToast, "3 sessions deleted")
        let none = await vm.deleteAtPanelCursor(projectID: projectID)
        XCTAssertNil(none, "no cursor: ⌘⌫ does nothing")
    }

    /// A live session whose agent may be working (no hook reported yet:
    /// running) is never deleted by ⌘⌫ alone: the page asks first.
    func testCommandDeleteOnAWorkingSessionAsksFirst() async throws {
        let vm = makeVM()
        let a = try await insertSession("Session A")
        await page(vm)
        await vm.showSession(id: a.id)
        XCTAssertTrue(center.liveIDs.contains(a.id))
        XCTAssertEqual(vm.sessionState(a).kind, .running)
        XCTAssertFalse(vm.isQuickDelete(a), "no ✕")
        vm.panelCursor = a.id

        let intent = await vm.deleteAtPanelCursor(projectID: projectID)
        guard case let .confirm(session)? = intent else { return XCTFail("expected the confirmation, got \(String(describing: intent))") }
        XCTAssertEqual(session.id, a.id)
        XCTAssertTrue(vm.pendingDeletes.batch.isEmpty, "nothing deleted before the owner confirms")
        XCTAssertTrue(center.liveIDs.contains(a.id), "the agent keeps running")
        XCTAssertEqual(vm.panelSections(projectID: projectID).visibleOrder, [a.id])
        XCTAssertEqual(vm.panelCursor, a.id)
    }

    /// ↑ ↓ only move the highlight, clamped at the ends: no session opens
    /// or starts (opening a finished one would resume its agent).
    func testCursorMovesNeverStartASession() async throws {
        let vm = makeVM()
        let (a, b, c) = try await threeRows(vm)
        let before = vm.layout(projectID: projectID)

        vm.movePanelCursor(1, projectID: projectID)
        XCTAssertEqual(vm.panelCursor, c.id, "no cursor yet: ↓ starts at the top")
        vm.movePanelCursor(1, projectID: projectID)
        vm.movePanelCursor(1, projectID: projectID)
        vm.movePanelCursor(1, projectID: projectID)
        XCTAssertEqual(vm.panelCursor, a.id, "clamped at the bottom")
        vm.movePanelCursor(-1, projectID: projectID)
        XCTAssertEqual(vm.panelCursor, b.id)

        XCTAssertTrue(center.liveIDs.isEmpty, "nothing started")
        XCTAssertEqual(vm.layout(projectID: projectID), before, "nothing opened")
    }

    /// The panel taking the keyboard starts the cursor on the session on
    /// screen; a cursor still listed is kept, one gone is replaced.
    func testEnteringThePanelPutsTheCursorOnTheSessionOnScreen() async throws {
        let vm = makeVM()
        let (a, b, _) = try await threeRows(vm)
        putOnScreen(b, vm)

        vm.enterPanelKeyboard(projectID: projectID)
        XCTAssertEqual(vm.panelCursor, b.id)
        vm.panelCursor = a.id
        vm.enterPanelKeyboard(projectID: projectID)
        XCTAssertEqual(vm.panelCursor, a.id, "a listed cursor is kept")
        vm.panelCursor = 9_999
        vm.enterPanelKeyboard(projectID: projectID)
        XCTAssertEqual(vm.panelCursor, b.id, "a cursor no longer listed restarts on screen")
        XCTAssertTrue(center.liveIDs.isEmpty)
    }

    /// Esc hands the keyboard to the terminal on screen; with none on
    /// screen it reports so (the panel just lets the keyboard go).
    func testEscHandsTheKeyboardToTheOnScreenTerminal() async throws {
        let vm = makeVM()
        let (a, _, _) = try await threeRows(vm)
        XCTAssertFalse(vm.returnKeyboardToTerminal(projectID: projectID), "no session on screen")

        putOnScreen(a, vm)
        XCTAssertTrue(vm.returnKeyboardToTerminal(projectID: projectID))
        XCTAssertNotNil(center.keyboardFocusSerial(for: a.id), "the terminal on screen takes the keyboard")
    }

    /// The toast counts the batch; Undo brings every row of it back and
    /// the toast goes.
    func testToastShowsBatchCountAndUndoRestores() async throws {
        let vm = makeVM()
        let (a, b, c) = try await threeRows(vm)
        XCTAssertNil(vm.pendingDeleteToast)

        await vm.delete(b)
        XCTAssertEqual(vm.pendingDeleteToast, "Session deleted")
        await vm.delete(a)
        XCTAssertEqual(vm.pendingDeleteToast, "2 sessions deleted")
        XCTAssertEqual(vm.panelSections(projectID: projectID).visibleOrder, [c.id])

        await vm.undoPendingDeletes()
        XCTAssertNil(vm.pendingDeleteToast)
        XCTAssertEqual(vm.panelSections(projectID: projectID).visibleOrder, [c.id, b.id, a.id])
    }
}
