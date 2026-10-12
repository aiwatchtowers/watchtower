import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// The page's active code root (board #565 WT3, #568; PROJ-03 as amended
/// 2026-10-12, owner approved in ask #188): each worktree keeps its own
/// tabs and buffers, a switch hands the editor's unsent edits to the old
/// root, and a removed worktree is never written again.
@MainActor
final class CodeFilesCenterRootTests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var worktreeA: URL!
    private var worktreeB: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var project: Workbench!
    private var main: CodeRoot { project.mainCodeRoot }
    private var rootA: CodeRoot { CodeRoot(workbenchID: project.id, worktree: worktreeA) }
    private var rootB: CodeRoot { CodeRoot(workbenchID: project.id, worktree: worktreeB) }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("roots-\(UUID().uuidString)")
        folder = base.appendingPathComponent("acme")
        worktreeA = folder.appendingPathComponent(".claude/worktrees/mobile-a")
        worktreeB = folder.appendingPathComponent(".claude/worktrees/mobile-b")
        for dir in [folder, worktreeA, worktreeB].compactMap({ $0 }) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "all:\n".write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
            try "package main\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        }
        suite = "CodeFilesCenterRootTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        project = Workbench(row: Row(["id": 7, "name": "acme", "folder_path": folder.path]))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    private func makeCenter(gitRead: @escaping (URL) async -> GitStatusRead = { _ in .noRepository }) -> CodeFilesCenter {
        CodeFilesCenter(defaults: defaults, trash: { _ in }, gitRead: gitRead, gitMinInterval: .zero, watchesFolders: false)
    }

    private func data(_ dir: URL, _ path: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(path))
    }

    private func text(_ dir: URL, _ path: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    private func eventually(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Guards (PROJ-03)

    func testProj03_ABufferNeverWritesIntoAnotherWorktree() async throws {
        let center = makeCenter()
        center.open("Makefile", root: main, preview: false)
        center.open("Makefile", root: rootA, preview: false)
        let mainBuffer = center.buffer(for: main, relPath: "Makefile")
        let bufferA = center.buffer(for: rootA, relPath: "Makefile")
        mainBuffer.loadIfNeeded()
        bufferA.loadIfNeeded()
        let mainBefore = try data(folder, "Makefile")
        let bBefore = try data(worktreeB, "Makefile")

        center.edited(bufferA, text: "all: worktree a\n", base: 0, now: true)
        let refusals = await center.close(["Makefile"], root: rootA)

        XCTAssertTrue(refusals.isEmpty)
        XCTAssertEqual(try text(worktreeA, "Makefile"), "all: worktree a\n")
        XCTAssertEqual(try data(folder, "Makefile"), mainBefore, "the main folder's file is byte-identical")
        XCTAssertEqual(try data(worktreeB, "Makefile"), bBefore, "another worktree's file is byte-identical")
        XCTAssertEqual(mainBuffer.text, "all:\n", "the main folder's buffer took nothing")
        XCTAssertEqual(center.tabs(for: main).paths, ["Makefile"], "closing in A leaves the main folder's tab")
    }

    func testProj03_UnsentEditsLandInTheOldWorktreeOnASessionSwitch() async throws {
        let center = makeCenter()
        center.open("Makefile", root: rootA, preview: true)
        center.open("Makefile", root: rootB, preview: true)
        let bufferA = center.buffer(for: rootA, relPath: "Makefile")
        let bufferB = center.buffer(for: rootB, relPath: "Makefile")
        bufferA.loadIfNeeded()
        bufferB.loadIfNeeded()
        let bBefore = try data(worktreeB, "Makefile")
        let mainBefore = try data(folder, "Makefile")
        // The editor page still holds A's last keystrokes when the session
        // on screen moves to B.
        let page = PendingPage(edits: [CodeEditorPendingEdit(id: bufferA.id, text: "all: typed in a\n", base: 0)])
        center.register(page, for: rootA)

        await center.activate(root: rootB, previous: rootA)

        XCTAssertEqual(page.asked, 1, "the page was asked once, during the switch")
        XCTAssertEqual(try text(worktreeA, "Makefile"), "all: typed in a\n", "written to A's file")
        XCTAssertEqual(try data(worktreeB, "Makefile"), bBefore, "B untouched")
        XCTAssertEqual(try data(folder, "Makefile"), mainBefore, "the main folder untouched")
        XCTAssertFalse(bufferB.isDirty)
        XCTAssertEqual(center.tabs(for: rootA).tabs.first?.isPreview, false, "A's own preview tab was kept")
        XCTAssertEqual(center.tabs(for: rootB).tabs.first?.isPreview, true, "B's preview tab is not touched")

        // The page now answers for B: a later pull asks it there.
        page.edits = [CodeEditorPendingEdit(id: bufferB.id, text: "all: typed in b\n", base: 0)]
        await center.pullPending(rootB)
        XCTAssertEqual(page.asked, 2)
        XCTAssertEqual(bufferB.text, "all: typed in b\n")
        XCTAssertEqual(try text(worktreeA, "Makefile"), "all: typed in a\n", "A keeps its edit")
    }

    func testProj03_ARemovedWorktreeIsNeverWritten() async throws {
        let center = makeCenter()
        center.startWatching(rootA)
        center.open("Makefile", root: rootA, preview: false)
        center.open("main.go", root: rootA, preview: false)
        let dirty = center.buffer(for: rootA, relPath: "Makefile")
        let clean = center.buffer(for: rootA, relPath: "main.go")
        dirty.loadIfNeeded()
        clean.loadIfNeeded()
        center.edited(dirty, text: "all: unsaved\n", base: 0)
        XCTAssertTrue(dirty.isDirty)

        try FileManager.default.removeItem(at: worktreeA)
        center.handle(FolderWatcher.Batch(mustRescan: true), root: rootA)

        XCTAssertEqual(center.orphanedEdits(workbenchID: project.id).map(\.buffer.relPath), ["Makefile"])
        XCTAssertNil(center.existingBuffer(rootA, "main.go"), "a clean buffer is dropped")
        XCTAssertNil(defaults.data(forKey: CodeTabs.key(root: rootA)), "the saved tabs key is dropped")
        XCTAssertTrue(center.isRemoved(rootA))
        XCTAssertFalse(dirty.saveNow(), "an autosave-style save is refused")
        XCTAssertFalse(dirty.saveNow(explicit: true), "Cmd+S is refused")
        dirty.keepMine()
        center.flushAll()
        await center.flushEverything()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeA.path), "no folder was recreated")

        // The folder coming back (a worktree added at the same path) does
        // not make the old edits writable.
        try FileManager.default.createDirectory(at: worktreeA, withIntermediateDirectories: true)
        XCTAssertFalse(dirty.saveNow(explicit: true))
        center.edited(dirty, text: "all: still unsaved\n", base: 0, now: true, explicit: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeA.appendingPathComponent("Makefile").path))
        XCTAssertEqual(dirty.unsavedReason, CodeFileBuffer.lockedReason)

        center.discardOrphanedEdit(id: dirty.id)
        XCTAssertTrue(center.orphanedEdits(workbenchID: project.id).isEmpty, "Discard drops them")
    }

    // MARK: Switching

    func testOpenInAThenBThenBackKeepsAsTabs() async throws {
        let center = makeCenter()
        center.open("Makefile", root: rootA, preview: false)
        center.open("main.go", root: rootA, preview: false)
        center.activate("Makefile", root: rootA)

        await center.activate(root: rootB, previous: rootA)
        center.open("main.go", root: rootB, preview: false)
        XCTAssertEqual(center.tabs(for: rootB).paths, ["main.go"], "B starts with its own set")

        await center.activate(root: rootA, previous: rootB)
        XCTAssertEqual(center.tabs(for: rootA).paths, ["Makefile", "main.go"], "A's tabs are where they were")
        XCTAssertEqual(center.tabs(for: rootA).active, "Makefile")
        XCTAssertEqual(center.tabs(for: rootB).paths, ["main.go"], "B's set is not lost")
        XCTAssertTrue(center.tabs(for: main).paths.isEmpty, "the main folder's set is its own")

        let relaunched = makeCenter()
        XCTAssertEqual(relaunched.tabs(for: rootA).paths, ["Makefile", "main.go"])
        XCTAssertEqual(relaunched.tabs(for: rootB).paths, ["main.go"])
    }

    func testTheEditorKeepsTheOtherRootsModels() {
        let center = makeCenter()
        center.open("Makefile", root: rootA, preview: false)
        center.open("Makefile", root: main, preview: false)
        let bufferA = center.buffer(for: rootA, relPath: "Makefile")
        let mainBuffer = center.buffer(for: main, relPath: "Makefile")
        XCTAssertEqual(center.openBufferIDs(workbenchID: project.id, except: main), [bufferA.id])
        XCTAssertEqual(center.openBufferIDs(workbenchID: project.id, except: rootA), [mainBuffer.id])
        XCTAssertTrue(center.openBufferIDs(workbenchID: 99, except: main).isEmpty)
    }

    func testASwitchToAnotherWorkbenchMovesNothing() async {
        let center = makeCenter()
        let page = PendingPage(edits: [])
        center.register(page, for: rootA)
        let other = Workbench(row: Row(["id": 8, "name": "other", "folder_path": worktreeB.path])).mainCodeRoot
        await center.activate(root: other, previous: rootA)
        XCTAssertEqual(page.asked, 0, "a page that changed workbench is not the old root's switch")
    }

    func testRemovedWorktreeFallsBackToMainWithoutError() async throws {
        let center = makeCenter()
        center.open("Makefile", root: rootA, preview: false)
        let buffer = center.buffer(for: rootA, relPath: "Makefile")
        buffer.loadIfNeeded()
        let page = PendingPage(edits: [CodeEditorPendingEdit(id: buffer.id, text: "all: last keys\n", base: 0)])
        center.register(page, for: rootA)
        try FileManager.default.removeItem(at: worktreeA)

        await center.activate(root: main, previous: rootA)

        XCTAssertTrue(center.isRemoved(rootA))
        XCTAssertNil(center.editorErrors[main])
        XCTAssertNil(center.editorErrors[rootA])
        XCTAssertEqual(buffer.text, "all: last keys\n", "the late keystrokes reached the locked buffer")
        XCTAssertEqual(center.orphanedEdits(workbenchID: project.id).map(\.id), [buffer.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeA.path), "nothing was written")
        XCTAssertTrue(center.tabs(for: rootA).paths.isEmpty)
    }

    // MARK: Watching a hidden worktree

    func testAHiddenWorktreeIsNotWatchedAndIsReadAgainWhenItShows() throws {
        let center = makeCenter()
        center.startWatching(rootA)
        let buffer = center.buffer(for: rootA, relPath: "Makefile")
        buffer.loadIfNeeded()
        center.stopShowing(rootA)

        try "all: agent\n".write(to: worktreeA.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        center.handle(FolderWatcher.Batch(paths: ["Makefile"]), root: rootA)
        XCTAssertEqual(buffer.text, "all:\n", "hidden: its FSEvents are not handled")

        center.startWatching(rootA)
        XCTAssertEqual(buffer.text, "all: agent\n", "shown again: the disk is read again")
    }

    func testAGitRunOfAWorktreeHiddenMeanwhileLandsNothing() async throws {
        let gate = RootGate()
        let center = makeCenter { _ in
            await gate.wait()
            return .snapshot(GitStatusSnapshot(files: ["Makefile": .modified]))
        }
        center.startWatching(rootA)
        await eventually { await gate.waiting }
        center.stopShowing(rootA)
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(center.git(for: rootA).files.isEmpty, "the answer came after the root was hidden")

        center.startWatching(rootA)
        await eventually { !center.git(for: rootA).files.isEmpty }
        XCTAssertEqual(center.git(for: rootA).files, ["Makefile": .modified], "shown again: git read afresh")
    }

    func testTheMainRootStaysWatchedWhileHidden() throws {
        let center = makeCenter()
        center.startWatching(main)
        let buffer = center.buffer(for: main, relPath: "Makefile")
        buffer.loadIfNeeded()
        center.stopShowing(main)
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        center.handle(FolderWatcher.Batch(paths: ["Makefile"]), root: main)
        XCTAssertEqual(buffer.text, "all: agent\n")
    }
}

/// The page's active root, from the layout and the sessions' places.
@MainActor
final class CodeFilesActiveRootTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var base: URL!
    private var worktree: URL!
    private var project: Workbench!
    private var sessionID: Int64 = 0

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "CodeFilesActiveRootTests-\(UUID().uuidString)"))
        base = FileManager.default.temporaryDirectory.appendingPathComponent("active-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("acme")
        worktree = folder.appendingPathComponent(".claude/worktrees/mobile-a")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let cwd = worktree.path
        (project, sessionID) = try await pool.write { db -> (Workbench, Int64) in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder.path)
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: id, kind: .claude, title: "s", folderPath: folder.path, claudeSessionID: "uuid-1"
            ))
            try db.execute(
                sql: "UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = ? WHERE id = ?",
                arguments: [cwd, "2026-10-12 10:00:00.000", row.id]
            )
            return (try XCTUnwrap(WorkbenchQueries.fetch(db, id: id)), row.id)
        }
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
        try? FileManager.default.removeItem(at: base)
    }

    private func makeVM() -> WorkbenchesViewModel {
        let runner = SessionPlaceViewModelTests.RoutingRunner(workbenchID: project.id)
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.makeGitWatcher = { _, _, onChange in SessionPlaceViewModelTests.FakeWatcher(onChange: onChange) }
        vm.gitPollSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        vm.gitNotificationCenter = NotificationCenter()
        return vm
    }

    private func layout(_ pane: WorkspacePane) -> WorkspaceLayout {
        var layout = WorkspaceLayout.default
        layout.primary = pane
        return layout
    }

    private func placed(_ vm: WorkbenchesViewModel) async {
        await vm.startGitWatching(project: project)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if case .worktree = vm.sessionPlaces.currentPlace(sessionID: sessionID) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        vm.stopGitWatching(projectID: project.id)
    }

    func testBoardOnlyPageUsesTheMainFolder() async {
        let vm = makeVM()
        await placed(vm)
        vm.setLayout(layout(.board), projectID: project.id)
        XCTAssertEqual(vm.activeCodeRoot(project: project), project.mainCodeRoot, "no session on the page")
        vm.setLayout(layout(.files), projectID: project.id)
        XCTAssertEqual(vm.activeCodeRoot(project: project), project.mainCodeRoot, "the Files pane alone")
    }

    func testASessionInAWorktreePutsThePageThere() async {
        let vm = makeVM()
        await placed(vm)
        vm.setLayout(layout(.session(sessionID)), projectID: project.id)
        let root = vm.activeCodeRoot(project: project)
        XCTAssertFalse(root.isMain)
        XCTAssertEqual(root, CodeRoot(workbenchID: project.id, worktree: worktree))
        XCTAssertEqual(root.filesCaption, "FILES — ⑂ mobile-a")
    }

    func testAnUnreadPlaceUsesTheMainFolder() {
        let vm = makeVM()
        vm.setLayout(layout(.session(sessionID)), projectID: project.id)
        XCTAssertEqual(vm.activeCodeRoot(project: project), project.mainCodeRoot, "unknown place: main folder")
    }

    func testARemovedWorktreeFallsBackToTheMainFolder() async throws {
        let vm = makeVM()
        await placed(vm)
        vm.setLayout(layout(.session(sessionID)), projectID: project.id)
        let root = vm.activeCodeRoot(project: project)
        XCTAssertFalse(root.isMain)
        try FileManager.default.removeItem(at: worktree)
        vm.codeFiles.rootRemoved(root)
        XCTAssertEqual(vm.activeCodeRoot(project: project), project.mainCodeRoot)
    }
}

/// An editor page holding unsent edits; counts how often it was asked.
@MainActor
private final class PendingPage: CodeEditorBridge {
    var edits: [CodeEditorPendingEdit]
    private(set) var asked = 0

    init(edits: [CodeEditorPendingEdit]) {
        self.edits = edits
    }

    func takePending() async -> [CodeEditorPendingEdit]? {
        asked += 1
        defer { edits = [] }
        return edits
    }
}

private actor RootGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    var waiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
