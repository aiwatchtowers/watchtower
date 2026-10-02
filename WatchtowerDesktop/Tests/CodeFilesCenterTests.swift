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
        first.open("cmd/main.go", project: project, preview: false)
        first.open("Makefile", project: project, preview: false)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Makefile"))
        let second = makeCenter()
        let tabs = second.tabs(for: project)
        XCTAssertEqual(tabs.paths, ["cmd/main.go"])
        XCTAssertEqual(tabs.active, "cmd/main.go")
    }

    func testUnreadableSavedTabsAreKeptAsideNotLost() {
        defaults.set(Data("not json".utf8), forKey: CodeTabs.key(workbenchID: 7))
        let center = makeCenter()
        XCTAssertTrue(center.tabs(for: project).tabs.isEmpty)
        XCTAssertEqual(defaults.data(forKey: CodeTabs.key(workbenchID: 7) + ".unreadable"), Data("not json".utf8))
    }

    func testOpeningRightAfterTheFirstReadKeepsTheChange() async {
        let center = makeCenter()
        _ = center.tabs(for: project)
        center.open("Makefile", project: project, preview: false)
        await Task.yield()
        XCTAssertEqual(center.tabs(for: project).paths, ["Makefile"])
    }

    func testABufferSurvivesThePaneGoingAway() {
        let center = makeCenter()
        let buffer = center.buffer(for: project, relPath: "Makefile")
        buffer.loadIfNeeded()
        buffer.edited("all: build\n", base: 0)
        XCTAssertTrue(center.buffer(for: project, relPath: "Makefile") === buffer)
        XCTAssertEqual(center.buffer(for: project, relPath: "Makefile").text, "all: build\n")
    }

    // MARK: Close

    func testCloseSavesAnEditThePageHadNotSentYet() async throws {
        let center = makeCenter()
        center.open("Makefile", project: project, preview: false)
        let buffer = center.buffer(for: project, relPath: "Makefile")
        buffer.loadIfNeeded()
        let page = FakeBridge(edits: [CodeEditorPendingEdit(id: buffer.id, text: "all: last keystroke\n", base: 0)])
        center.register(page, for: project.id)
        let refusals = await center.close(["Makefile"], project: project)
        XCTAssertEqual(refusals, [])
        XCTAssertEqual(try text("Makefile"), "all: last keystroke\n")
        XCTAssertNil(center.existingBuffer(project, "Makefile"))
        XCTAssertTrue(center.tabs(for: project).tabs.isEmpty)
    }

    func testCloseOfAConflictedTabIsRefusedWithItsReason() async throws {
        let center = makeCenter()
        center.open("Makefile", project: project, preview: false)
        center.open("cmd/main.go", project: project, preview: false)
        let buffer = center.buffer(for: project, relPath: "Makefile")
        buffer.loadIfNeeded()
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        buffer.edited("all: mine\n", base: 0)
        let refusals = await center.close(["Makefile", "cmd/main.go"], project: project)
        XCTAssertEqual(refusals.map(\.path), ["Makefile"])
        XCTAssertEqual(refusals.first?.reason, CodeFileBuffer.Problem.conflict.message)
        XCTAssertEqual(center.tabs(for: project).paths, ["Makefile"], "the clean one closed, the refused one stays")
        XCTAssertEqual(try text("Makefile"), "all: agent\n")
        XCTAssertEqual(center.existingBuffer(project, "Makefile")?.text, "all: mine\n")
    }

    func testDiscardAndCloseLeavesTheDiskAlone() throws {
        let center = makeCenter()
        center.open("Makefile", project: project, preview: false)
        let buffer = center.buffer(for: project, relPath: "Makefile")
        buffer.loadIfNeeded()
        buffer.edited("all: mine\n", base: 0)
        center.discardAndClose(["Makefile"], project: project)
        XCTAssertEqual(try text("Makefile"), "all:\n")
        XCTAssertNil(center.existingBuffer(project, "Makefile"))
    }

    // MARK: File operations

    func testCreateFileMakesItsFoldersAndOpensAKeptTab() throws {
        let center = makeCenter()
        let path = try center.createFile("internal/foo/bar.go", in: "", project: project)
        XCTAssertEqual(path, "internal/foo/bar.go")
        XCTAssertEqual(try text(path), "")
        let tabs = center.tabs(for: project)
        XCTAssertEqual(tabs.active, path)
        XCTAssertEqual(tabs.tabs.first?.isPreview, false)
    }

    func testCreateRefusesAnExistingNameAndABadOne() {
        let center = makeCenter()
        XCTAssertThrowsError(try center.createFile("main.go", in: "cmd", project: project)) {
            XCTAssertEqual($0 as? CodeFilesCenter.OperationError, .exists("cmd/main.go"))
        }
        XCTAssertThrowsError(try center.createFolder("cmd", in: "", project: project))
        XCTAssertThrowsError(try center.createFile("../outside.go", in: "cmd", project: project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("outside.go").path))
    }

    func testRenameSavesFirstAndTheTabAndBufferFollow() async throws {
        let center = makeCenter()
        center.open("cmd/main.go", project: project, preview: false)
        let buffer = center.buffer(for: project, relPath: "cmd/main.go")
        buffer.loadIfNeeded()
        buffer.edited("package app\n", base: 0)
        let newPath = try await center.rename("cmd/main.go", to: "app.go", project: project)
        XCTAssertEqual(newPath, "cmd/app.go")
        XCTAssertEqual(try text("cmd/app.go"), "package app\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cmd/main.go").path))
        XCTAssertEqual(center.tabs(for: project).paths, ["cmd/app.go"])
        XCTAssertTrue(center.existingBuffer(project, "cmd/app.go") === buffer, "the same buffer — the page keeps its undo")
        XCTAssertEqual(buffer.relPath, "cmd/app.go")
    }

    func testRenamingAFolderMovesEveryTabUnderIt() async throws {
        let center = makeCenter()
        center.open("cmd/main.go", project: project, preview: false)
        center.open("Makefile", project: project, preview: false)
        _ = center.buffer(for: project, relPath: "cmd/main.go")
        try await center.rename("cmd", to: "tools", project: project)
        XCTAssertEqual(center.tabs(for: project).paths, ["tools/main.go", "Makefile"])
        XCTAssertEqual(center.existingBuffer(project, "tools/main.go")?.relPath, "tools/main.go")
    }

    func testRenameIsRefusedWhileAnEditCannotBeSaved() async throws {
        let center = makeCenter()
        let buffer = center.buffer(for: project, relPath: "Makefile")
        buffer.loadIfNeeded()
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        buffer.edited("all: mine\n", base: 0)
        do {
            try await center.rename("Makefile", to: "GNUmakefile", project: project)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? CodeFilesCenter.OperationError, .unsaved("Makefile"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Makefile").path))
    }

    func testCaseOnlyRename() async throws {
        let center = makeCenter()
        try await center.rename("Makefile", to: "makefile", project: project)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains("makefile"))
        XCTAssertFalse(names.contains("Makefile"))
    }

    func testMoveToTrashClosesTheTabsUnderIt() throws {
        let center = makeCenter()
        center.open("cmd/main.go", project: project, preview: false)
        center.open("Makefile", project: project, preview: false)
        try center.moveToTrash("cmd", project: project)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["cmd"])
        XCTAssertEqual(center.tabs(for: project).paths, ["Makefile"])
        XCTAssertNil(center.existingBuffer(project, "cmd/main.go"))
    }

    // MARK: Watching and git

    func testAChangedFileReloadsItsCleanBufferAndRefreshesItsFolder() throws {
        let center = makeCenter()
        center.startWatching(project)
        let tree = center.tree(for: project)
        tree.loadIfNeeded()
        let buffer = center.buffer(for: project, relPath: "Makefile")
        buffer.loadIfNeeded()
        try "all: agent\n".write(to: folder.appendingPathComponent("Makefile"), atomically: false, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        center.handle(FolderWatcher.Batch(paths: ["Makefile", "new.txt"]), projectID: project.id)
        XCTAssertEqual(buffer.text, "all: agent\n")
        XCTAssertTrue(tree.rows.contains { $0.entry.relPath == "new.txt" })
    }

    func testARescanReloadsEveryOpenBuffer() throws {
        let center = makeCenter()
        center.startWatching(project)
        let buffer = center.buffer(for: project, relPath: "cmd/main.go")
        buffer.loadIfNeeded()
        try "package checkout\n".write(to: folder.appendingPathComponent("cmd/main.go"), atomically: false, encoding: .utf8)
        center.handle(FolderWatcher.Batch(mustRescan: true), projectID: project.id)
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
        center.startWatching(project)
        await eventually { await runs.value == 1 }
        for _ in 0 ..< 3 { center.handle(FolderWatcher.Batch(gitChanged: true), projectID: project.id) }
        await gate.open()
        await eventually { await runs.value == 2 && center.git(for: project).files == ["Makefile": .modified] }
        try await Task.sleep(for: .milliseconds(100))
        let count = await runs.value
        XCTAssertEqual(count, 2, "the first run, then exactly one queued")
        XCTAssertEqual(center.git(for: project).files, ["Makefile": .modified])
    }

    func testAFailedGitRunKeepsTheLastMarksAndSaysSo() async throws {
        let results = Results([.snapshot(GitStatusSnapshot(files: ["Makefile": .modified])), .failed("git exited 128: boom")])
        let center = makeCenter { _ in await results.next() }
        center.startWatching(project)
        await eventually { !center.git(for: project).files.isEmpty }
        center.handle(FolderWatcher.Batch(gitChanged: true), projectID: project.id)
        await eventually { center.gitErrors[project.id] != nil }
        XCTAssertEqual(center.git(for: project).files, ["Makefile": .modified])
        XCTAssertEqual(center.gitErrors[project.id], "git exited 128: boom")
    }
}

@MainActor
private final class FakeBridge: CodeEditorBridge {
    var edits: [CodeEditorPendingEdit]

    init(edits: [CodeEditorPendingEdit]) {
        self.edits = edits
    }

    func takePending() async -> [CodeEditorPendingEdit] {
        defer { edits = [] }
        return edits
    }
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
