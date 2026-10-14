import GRDB
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// The code viewer's center: tabs that survive navigation and relaunch,
/// closes that never lose an edit, file operations from the tree, the
/// FSEvents path and git refresh coalescing.
@MainActor
final class CodeFilesCenterTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var trashed: [URL] = []
    private var project: Workbench!
    private var root: CodeRoot { project.mainCodeRoot }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("center-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("cmd"), withIntermediateDirectories: true)
        try "package main\n".write(to: folder.appendingPathComponent("cmd/main.go"), atomically: true, encoding: .utf8)
        try "all:\n".write(to: folder.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        suite = "CodeFilesCenterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        project = Workbench(row: Row(["id": 7, "name": "acme", "folder_path": folder.path]))
        trashed = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeCenter(gitRead: @escaping (URL) async -> GitStatusRead = { _ in .noRepository }) -> CodeFilesCenter {
        CodeFilesCenter(
            defaults: defaults,
            trash: { [weak self] url in
                self?.trashed.append(url)
                try FileManager.default.removeItem(at: url)
            },
            gitRead: gitRead,
            gitMinInterval: .zero,
            watchesFolders: false
        )
    }

    /// Waits on state, not on a wall-clock margin.
    private func eventually(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Tabs

    func testTabsSurviveANewCenterAndDropDeletedFiles() async throws {
        let first = makeCenter()
        first.open("cmd/main.go", root: root, preview: false)
        first.open("Makefile", root: root, preview: false)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Makefile"))
        let second = makeCenter()
        let tabs = second.tabs(for: root)
        XCTAssertEqual(tabs.paths, ["cmd/main.go"])
        XCTAssertEqual(tabs.active, "cmd/main.go")
    }

    func testUnreadableSavedTabsAreKeptAsideNotLost() {
        defaults.set(Data("not json".utf8), forKey: CodeTabs.key(workbenchID: 7))
        let center = makeCenter()
        XCTAssertTrue(center.tabs(for: root).tabs.isEmpty)
        XCTAssertEqual(defaults.data(forKey: CodeTabs.key(workbenchID: 7) + ".unreadable"), Data("not json".utf8))
    }

    func testOpeningRightAfterTheFirstReadKeepsTheChange() async {
        let center = makeCenter()
        _ = center.tabs(for: root)
        center.open("Makefile", root: root, preview: false)
        await Task.yield()
        XCTAssertEqual(center.tabs(for: root).paths, ["Makefile"])
    }

    func testABufferSurvivesThePaneGoingAway() {
        let center = makeCenter()
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        buffer.edited("all: build\n", base: 0)
        XCTAssertTrue(center.buffer(for: root, relPath: "Makefile") === buffer)
        XCTAssertEqual(center.buffer(for: root, relPath: "Makefile").text, "all: build\n")
    }

    // MARK: Close

    func testCloseSavesAnEditThePageHadNotSentYet() async throws {
        let center = makeCenter()
        center.open("Makefile", root: root, preview: false)
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        let page = FakeBridge(edits: [CodeEditorPendingEdit(id: buffer.id, text: "all: last keystroke\n", base: 0)])
        center.register(page, for: root)
        let refusals = await center.close(["Makefile"], root: root)
        XCTAssertEqual(refusals, [])
        XCTAssertEqual(try text("Makefile"), "all: last keystroke\n")
        XCTAssertNil(center.existingBuffer(root, "Makefile"))
        XCTAssertTrue(center.tabs(for: root).tabs.isEmpty)
    }

    func testCloseOfAConflictedTabIsRefusedWithItsReason() async throws {
        let center = makeCenter()
        center.open("Makefile", root: root, preview: false)
        center.open("cmd/main.go", root: root, preview: false)
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        buffer.edited("all: mine\n", base: 0)
        let refusals = await center.close(["Makefile", "cmd/main.go"], root: root)
        XCTAssertEqual(refusals.map(\.path), ["Makefile"])
        XCTAssertEqual(refusals.first?.reason, CodeFileBuffer.Problem.conflict.message)
        XCTAssertEqual(center.tabs(for: root).paths, ["Makefile"], "the clean one closed, the refused one stays")
        XCTAssertEqual(try text("Makefile"), "all: agent\n")
        XCTAssertEqual(center.existingBuffer(root, "Makefile")?.text, "all: mine\n")
    }

    func testDiscardAndCloseLeavesTheDiskAlone() throws {
        let center = makeCenter()
        center.open("Makefile", root: root, preview: false)
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        buffer.edited("all: mine\n", base: 0)
        center.discardAndClose(["Makefile"], root: root)
        XCTAssertEqual(try text("Makefile"), "all:\n")
        XCTAssertNil(center.existingBuffer(root, "Makefile"))
    }

    // MARK: File operations

    func testCreateFileMakesItsFoldersAndOpensAKeptTab() throws {
        let center = makeCenter()
        let path = try center.createFile("internal/foo/bar.go", in: "", root: root)
        XCTAssertEqual(path, "internal/foo/bar.go")
        XCTAssertEqual(try text(path), "")
        let tabs = center.tabs(for: root)
        XCTAssertEqual(tabs.active, path)
        XCTAssertEqual(tabs.tabs.first?.isPreview, false)
    }

    func testCreateRefusesAnExistingNameAndABadOne() {
        let center = makeCenter()
        XCTAssertThrowsError(try center.createFile("main.go", in: "cmd", root: root)) {
            XCTAssertEqual($0 as? CodeFilesCenter.OperationError, .exists("cmd/main.go"))
        }
        XCTAssertThrowsError(try center.createFolder("cmd", in: "", root: root))
        XCTAssertThrowsError(try center.createFile("../../outside.go", in: "cmd", root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("outside.go").path))
    }

    func testRenameSavesFirstAndTheTabAndBufferFollow() async throws {
        let center = makeCenter()
        center.open("cmd/main.go", root: root, preview: false)
        let buffer = center.buffer(for: root, relPath: "cmd/main.go")
        buffer.loadIfNeeded()
        buffer.edited("package app\n", base: 0)
        let newPath = try await center.rename("cmd/main.go", to: "app.go", root: root)
        XCTAssertEqual(newPath, "cmd/app.go")
        XCTAssertEqual(try text("cmd/app.go"), "package app\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cmd/main.go").path))
        XCTAssertEqual(center.tabs(for: root).paths, ["cmd/app.go"])
        XCTAssertTrue(center.existingBuffer(root, "cmd/app.go") === buffer, "the same buffer — the page keeps its undo")
        XCTAssertEqual(buffer.relPath, "cmd/app.go")
    }

    func testRenamingAFolderMovesEveryTabUnderIt() async throws {
        let center = makeCenter()
        center.open("cmd/main.go", root: root, preview: false)
        center.open("Makefile", root: root, preview: false)
        _ = center.buffer(for: root, relPath: "cmd/main.go")
        try await center.rename("cmd", to: "tools", root: root)
        XCTAssertEqual(center.tabs(for: root).paths, ["tools/main.go", "Makefile"])
        XCTAssertEqual(center.existingBuffer(root, "tools/main.go")?.relPath, "tools/main.go")
    }

    func testRenameIsRefusedWhileAnEditCannotBeSaved() async throws {
        let center = makeCenter()
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        buffer.edited("all: mine\n", base: 0)
        do {
            try await center.rename("Makefile", to: "GNUmakefile", root: root)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? CodeFilesCenter.OperationError, .unsaved("Makefile"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Makefile").path))
    }

    func testCaseOnlyRename() async throws {
        let center = makeCenter()
        try await center.rename("Makefile", to: "makefile", root: root)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains("makefile"))
        XCTAssertFalse(names.contains("Makefile"))
    }

    func testMoveToTrashClosesTheTabsUnderIt() async throws {
        let center = makeCenter()
        center.open("cmd/main.go", root: root, preview: false)
        center.open("Makefile", root: root, preview: false)
        try await center.moveToTrash("cmd", root: root)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["cmd"])
        XCTAssertEqual(center.tabs(for: root).paths, ["Makefile"])
        XCTAssertNil(center.existingBuffer(root, "cmd/main.go"))
    }

    func testRenameAndTrashNeverTouchAnotherWorkbenchsFileOfTheSameName() async throws {
        let otherFolder = FileManager.default.temporaryDirectory.appendingPathComponent("center-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherFolder) }
        try "all: other\n".write(to: otherFolder.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let other = Workbench(row: Row(["id": 8, "name": "other", "folder_path": otherFolder.path]))
        let center = makeCenter()
        center.open("Makefile", root: other.mainCodeRoot, preview: false)
        let theirs = center.buffer(for: other.mainCodeRoot, relPath: "Makefile")
        theirs.loadIfNeeded()
        theirs.edited("all: other edited\n", base: 0)
        _ = center.buffer(for: root, relPath: "Makefile")

        try await center.rename("Makefile", to: "GNUmakefile", root: root)
        XCTAssertTrue(center.existingBuffer(other.mainCodeRoot, "Makefile") === theirs)
        XCTAssertEqual(theirs.url, otherFolder.appendingPathComponent("Makefile"))
        XCTAssertTrue(theirs.isDirty, "not saved by the other workbench's rename")

        try await center.moveToTrash("GNUmakefile", root: root)
        XCTAssertTrue(center.existingBuffer(other.mainCodeRoot, "Makefile") === theirs, "not forgotten by the other workbench's trash")
        XCTAssertEqual(center.tabs(for: other.mainCodeRoot).paths, ["Makefile"])
    }

    func testTwoRootsOfOneWorkbenchKeepSeparateTabsAndBuffers() async throws {
        let worktreeFolder = FileManager.default.temporaryDirectory.appendingPathComponent("center-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktreeFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktreeFolder) }
        try "all: worktree\n".write(to: worktreeFolder.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let worktree = CodeRoot(workbenchID: project.id, worktree: worktreeFolder)
        let worktreePath = worktree.folder.path
        let center = makeCenter { url in
            url.path == worktreePath ? .failed("worktree index broken") : .snapshot(GitStatusSnapshot(files: ["Makefile": .modified]))
        }
        center.open("cmd/main.go", root: root, preview: false)
        center.open("Makefile", root: worktree, preview: false)

        let mine = center.buffer(for: root, relPath: "Makefile")
        let theirs = center.buffer(for: worktree, relPath: "Makefile")
        XCTAssertFalse(mine === theirs, "one buffer per root, whatever the path")
        XCTAssertEqual(theirs.url.path, worktreeFolder.appendingPathComponent("Makefile").path)
        theirs.loadIfNeeded()
        theirs.edited("all: worktree edited\n", base: 0)
        XCTAssertTrue(theirs.saveNow())
        XCTAssertEqual(try text("Makefile"), "all:\n", "the main folder's file is untouched")
        XCTAssertEqual(try String(contentsOf: worktreeFolder.appendingPathComponent("Makefile"), encoding: .utf8), "all: worktree edited\n")

        mine.loadIfNeeded()
        mine.edited("all: main edited\n", base: 0)
        XCTAssertTrue(mine.saveNow())
        XCTAssertEqual(try text("Makefile"), "all: main edited\n")
        XCTAssertEqual(
            try String(contentsOf: worktreeFolder.appendingPathComponent("Makefile"), encoding: .utf8),
            "all: worktree edited\n", "the worktree's file is untouched"
        )

        center.editorErrors[worktree] = "worktree only"
        XCTAssertNil(center.editorErrors[root], "editor errors are kept per root")
        center.startWatching(root)
        center.startWatching(worktree)
        await eventually { center.git(for: root).files["Makefile"] != nil && center.gitErrors[worktree] != nil }
        XCTAssertEqual(center.git(for: root).files["Makefile"], .modified)
        XCTAssertNil(center.gitErrors[root])
        XCTAssertTrue(center.git(for: worktree).files.isEmpty, "the main folder's marks stay off the worktree")
        XCTAssertEqual(center.gitErrors[worktree], "worktree index broken")

        let relaunched = makeCenter()
        XCTAssertEqual(relaunched.tabs(for: root).paths, ["cmd/main.go"])
        XCTAssertEqual(relaunched.tabs(for: worktree).paths, ["Makefile"], "each root keeps its own saved tabs")
        XCTAssertNotNil(defaults.data(forKey: CodeTabs.key(root: worktree)))
    }

    func testRenameOntoAnOpenTabIsRefused() async throws {
        let center = makeCenter()
        try "x".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        center.open("b.txt", root: root, preview: false)
        let open = center.buffer(for: root, relPath: "b.txt")
        open.loadIfNeeded()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("b.txt"))
        do {
            try await center.rename("Makefile", to: "b.txt", root: root)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? CodeFilesCenter.OperationError, .exists("b.txt"))
        }
        XCTAssertTrue(center.existingBuffer(root, "b.txt") === open)
        XCTAssertEqual(center.tabs(for: root).paths, ["b.txt"])
    }

    func testTrashSavesUnsavedEditsFirstSoTheTrashKeepsThem() async throws {
        var saved = ""
        let recording = CodeFilesCenter(
            defaults: defaults,
            trash: { url in
                saved = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try FileManager.default.removeItem(at: url)
            },
            gitRead: { _ in .noRepository }, gitMinInterval: .zero, watchesFolders: false
        )
        recording.open("Makefile", root: root, preview: false)
        let buffer = recording.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        let page = FakeBridge(edits: [CodeEditorPendingEdit(id: buffer.id, text: "all: unsent\n", base: 0)])
        recording.register(page, for: root)
        try await recording.moveToTrash("Makefile", root: root)
        XCTAssertEqual(saved, "all: unsent\n")
        XCTAssertTrue(recording.tabs(for: root).tabs.isEmpty)
    }

    func testTrashIsRefusedWhileAnEditCannotBeSaved() async throws {
        let center = makeCenter()
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        buffer.edited("all: mine\n", base: 0)
        do {
            try await center.moveToTrash("Makefile", root: root)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? CodeFilesCenter.OperationError, .unsaved("Makefile"))
        }
        XCTAssertTrue(trashed.isEmpty)
    }

    func testCaseOnlyRenameMovesItsTabAndBuffer() async throws {
        let center = makeCenter()
        center.open("Makefile", root: root, preview: false)
        let buffer = center.buffer(for: root, relPath: "Makefile")
        try await center.rename("Makefile", to: "makefile", root: root)
        XCTAssertEqual(center.tabs(for: root).paths, ["makefile"])
        XCTAssertTrue(center.existingBuffer(root, "makefile") === buffer)
    }

    func testAReplacedCleanPreviewLetsItsBufferGoADirtyOneIsKept() {
        let center = makeCenter()
        center.open("Makefile", root: root, preview: true)
        let clean = center.buffer(for: root, relPath: "Makefile")
        clean.loadIfNeeded()
        center.open("cmd/main.go", root: root, preview: true)
        XCTAssertNil(center.existingBuffer(root, "Makefile"))
        let dirty = center.buffer(for: root, relPath: "cmd/main.go")
        dirty.loadIfNeeded()
        center.edited(dirty, text: "package edited\n", base: 0)
        XCTAssertEqual(center.tabs(for: root).tabs.first?.isPreview, false, "the first edit keeps the tab")
        center.open("Makefile", root: root, preview: true)
        XCTAssertTrue(center.existingBuffer(root, "cmd/main.go") === dirty)
        XCTAssertEqual(center.tabs(for: root).paths, ["cmd/main.go", "Makefile"])
    }

    func testAPageThatCannotBeAskedIsShown() async {
        let center = makeCenter()
        let page = BrokenBridge()
        center.register(page, for: root)
        await center.pullPending(root)
        XCTAssertNotNil(center.editorErrors[root])
    }

    func testGitRunsOnlyForAWorkbenchOnScreenAndRefreshesWhenItShowsAgain() async throws {
        let runs = Counter()
        let center = makeCenter { _ in
            await runs.increment()
            return .snapshot(GitStatusSnapshot())
        }
        center.startWatching(root)
        await eventually { await runs.value == 1 }
        center.stopShowing(root)
        center.handle(FolderWatcher.Batch(gitChanged: true), root: root)
        try await Task.sleep(for: .milliseconds(100))
        let hidden = await runs.value
        XCTAssertEqual(hidden, 1, "no git run while nothing shows the workbench")
        center.startWatching(root)
        await eventually { await runs.value == 2 }
        let shown = await runs.value
        XCTAssertEqual(shown, 2, "shown again: refreshed")
    }

    func testShowCountsWhileTheTaskRunsAndStopsWhenCancelled() async throws {
        let runs = Counter()
        let center = makeCenter { _ in
            await runs.increment()
            return .snapshot(GitStatusSnapshot())
        }
        let task = Task { await center.show(root) }
        await eventually { await runs.value == 1 }
        task.cancel()
        await task.value
        center.handle(FolderWatcher.Batch(gitChanged: true), root: root)
        try await Task.sleep(for: .milliseconds(100))
        let count = await runs.value
        XCTAssertEqual(count, 1)
    }

    func testANestedWorkbenchKeepsItsOwnBufferAndTheParentsEditIsSavedAndMoved() async throws {
        let nested = Workbench(row: Row(["id": 9, "name": "nested", "folder_path": folder.appendingPathComponent("cmd").path]))
        let center = makeCenter()
        // The nested workbench opens the file first…
        let theirs = center.buffer(for: nested.mainCodeRoot, relPath: "main.go")
        theirs.loadIfNeeded()
        // …then the parent opens and edits the same file.
        center.open("cmd/main.go", root: root, preview: false)
        let mine = center.buffer(for: root, relPath: "cmd/main.go")
        XCTAssertFalse(mine === theirs, "one buffer per workbench")
        mine.loadIfNeeded()
        mine.edited("package edited\n", base: 0)

        try await center.rename("cmd", to: "tools", root: root)

        XCTAssertEqual(try text("tools/main.go"), "package edited\n", "saved before the move")
        XCTAssertTrue(center.existingBuffer(root, "tools/main.go") === mine)
        XCTAssertEqual(mine.url, folder.appendingPathComponent("tools/main.go"))
        XCTAssertEqual(theirs.relPath, "main.go", "the nested workbench's buffer is its own business")
    }

    // MARK: Watching and git

    func testAChangedFileReloadsItsCleanBufferAndRefreshesItsFolder() throws {
        let center = makeCenter()
        center.startWatching(root)
        let tree = center.tree(for: root)
        tree.loadIfNeeded()
        let buffer = center.buffer(for: root, relPath: "Makefile")
        buffer.loadIfNeeded()
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        center.handle(FolderWatcher.Batch(paths: ["Makefile", "new.txt"]), root: root)
        XCTAssertEqual(buffer.text, "all: agent\n")
        XCTAssertTrue(tree.rows.contains { $0.entry.relPath == "new.txt" })
    }

    func testAMovedWorkbenchFolderDropsTheOldMainRootsWatchAndTree() throws {
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("center-moved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moved) }
        let newRoot = Workbench(row: Row(["id": project.id, "name": "acme", "folder_path": moved.path])).mainCodeRoot
        let worktree = CodeRoot(workbenchID: project.id, worktree: moved.appendingPathComponent("wt"))
        let center = makeCenter()
        center.startWatching(root)
        let oldTree = center.tree(for: root)
        let oldBuffer = center.buffer(for: root, relPath: "Makefile")
        oldBuffer.loadIfNeeded()

        center.startWatching(worktree)
        XCTAssertTrue(center.tree(for: root) === oldTree, "a worktree root never drops the main root")
        center.startWatching(newRoot)

        XCTAssertFalse(center.tree(for: root) === oldTree, "the stale main root's tree is gone")
        try "all: moved\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        center.handle(FolderWatcher.Batch(paths: ["Makefile"]), root: root)
        XCTAssertEqual(oldBuffer.text, "all:\n", "the stale root is no longer watched")
        XCTAssertTrue(center.buffer(for: root, relPath: "Makefile") === oldBuffer, "its buffers stay for a pending save")
    }

    func testARescanReloadsEveryOpenBuffer() throws {
        let center = makeCenter()
        center.startWatching(root)
        let buffer = center.buffer(for: root, relPath: "cmd/main.go")
        buffer.loadIfNeeded()
        try "package checkout\n".write(to: folder.appendingPathComponent("cmd/main.go"), atomically: false, encoding: .utf8)
        center.handle(FolderWatcher.Batch(mustRescan: true), root: root)
        XCTAssertEqual(buffer.text, "package checkout\n")
    }

    func testGitRunsOneAtATimeAndQueuesOneMore() async throws {
        let runs = Counter()
        let gate = Gate()
        let center = makeCenter { _ in
            await runs.increment()
            await gate.wait()
            return .snapshot(GitStatusSnapshot(files: ["Makefile": .modified]))
        }
        center.startWatching(root)
        await eventually { await runs.value == 1 }
        for _ in 0 ..< 3 { center.handle(FolderWatcher.Batch(gitChanged: true), root: root) }
        await gate.open()
        await eventually { await runs.value == 2 && center.git(for: root).files == ["Makefile": .modified] }
        try await Task.sleep(for: .milliseconds(100))
        let count = await runs.value
        XCTAssertEqual(count, 2, "the first run, then exactly one queued")
        XCTAssertEqual(center.git(for: root).files, ["Makefile": .modified])
    }

    func testAFailedGitRunKeepsTheLastMarksAndSaysSo() async throws {
        let results = Results([.snapshot(GitStatusSnapshot(files: ["Makefile": .modified])), .failed("git exited 128: boom")])
        let center = makeCenter { _ in await results.next() }
        center.startWatching(root)
        await eventually { !center.git(for: root).files.isEmpty }
        center.handle(FolderWatcher.Batch(gitChanged: true), root: root)
        await eventually { center.gitErrors[root] != nil }
        XCTAssertEqual(center.git(for: root).files, ["Makefile": .modified])
        XCTAssertEqual(center.gitErrors[root], "git exited 128: boom")
    }
}

@MainActor
private final class FakeBridge: CodeEditorBridge {
    var edits: [CodeEditorPendingEdit]

    init(edits: [CodeEditorPendingEdit]) {
        self.edits = edits
    }

    func takePending() async -> [CodeEditorPendingEdit]? {
        defer { edits = [] }
        return edits
    }
}

@MainActor
private final class BrokenBridge: CodeEditorBridge {
    func takePending() async -> [CodeEditorPendingEdit]? { nil }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor Results {
    private var queue: [GitStatusRead]

    init(_ queue: [GitStatusRead]) {
        self.queue = queue
    }

    func next() -> GitStatusRead {
        queue.isEmpty ? .noRepository : queue.removeFirst()
    }
}
