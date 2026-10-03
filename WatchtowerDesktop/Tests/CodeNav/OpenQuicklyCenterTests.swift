import AppKit
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Open Quickly's center and session (spec §8.1): only with a workbench on
/// screen, ⇧⌘F opens on Text, the panel keeps the index shown (R25), ↩ / ⌥↩
/// open at the line (beside, splitting), ⌘↩ reaches the Ask AI hook, Esc and
/// the page leaving close it; the Text scope's `code search` restarts 120 ms
/// after the last keystroke and the previous one is cancelled at once.
@MainActor
final class OpenQuicklyCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var project: Workbench!
    private var presenter: RecordingPresenter!
    private var searches: FakeSearches!

    override func setUpWithError() throws {
        (pool, dbPath) = try TestDatabase.createPool()
        suite = "OpenQuicklyCenterTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        let source = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
        for path in ["src/save.swift", "README.md"] {
            try source.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        project = Workbench(row: Row(["id": 5, "name": "acme", "folder_path": folder.path]))
        presenter = RecordingPresenter()
        searches = FakeSearches()
    }

    override func tearDownWithError() throws {
        pool = nil
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private let save = CodeSymbol(name: "saveNow", kind: .method, path: "src/save.swift", line: 12, col: 10, endLine: 20, container: "Buffer")

    /// A center over an index with no CLI (its run fails at once); the
    /// index is filled by hand.
    private func makeCenter() -> (OpenQuicklyCenter, WorkbenchesViewModel) {
        let codeIndex = CodeIndexCenter { nil }
        let center = OpenQuicklyCenter(codeIndex: codeIndex, presenter: presenter, startSearch: searches.start)
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        center.workbenches = vm
        let index = codeIndex.index(for: project.id)
        index.applyIndexLines([
            .file(CodeIndexFileResult(file: "src/save.swift", lang: "swift", symbols: [save])),
            .file(CodeIndexFileResult(file: "README.md", lang: "", symbols: []))
        ], from: .update)
        return (center, vm)
    }

    // MARK: Presenting

    func testNothingOpensWithoutAWorkbenchOnScreen() {
        let (center, _) = makeCenter()
        XCTAssertFalse(center.canPresent, "the menu commands are disabled")
        center.present(scope: .all)
        XCTAssertNil(center.session)
        XCTAssertEqual(presenter.presented, 0)

        center.pageAppeared(project, window: nil)
        XCTAssertTrue(center.canPresent)
        center.pageDisappeared(workbenchID: project.id)
        XCTAssertFalse(center.canPresent)
        center.present(scope: .text)
        XCTAssertEqual(presenter.presented, 0)
    }

    func testShiftCommandFOpensOnTextAndSwitchesAnOpenPanelToIt() {
        let (center, _) = makeCenter()
        center.pageAppeared(project, window: nil)
        center.present(scope: .text)
        XCTAssertEqual(center.session?.model.scope, .text)
        center.dismiss(restoringFocus: true)
        XCTAssertEqual(presenter.dismissals, [true])

        center.present(scope: .all)
        let session = center.session
        session?.updateQuery("save")
        center.present(scope: .text)
        XCTAssertTrue(center.session === session, "the open panel is reused")
        XCTAssertEqual(session?.model.scope, .text)
        XCTAssertEqual(session?.model.query, "save", "the query stays")
        XCTAssertEqual(presenter.presented, 3)
    }

    func testThePageLeavingClosesThePanel() {
        let (center, _) = makeCenter()
        center.pageAppeared(project, window: nil)
        center.present(scope: .all)
        center.pageDisappeared(workbenchID: 99)
        XCTAssertNotNil(center.session, "another workbench's page is not this one")
        center.pageDisappeared(workbenchID: project.id)
        XCTAssertNil(center.session)
        XCTAssertEqual(presenter.dismissals, [false])
    }

    /// Ruling R25: the panel counts as showing the workbench, so its index
    /// is built for it and outlives the panel only by the idle TTL.
    func testThePanelKeepsTheIndexShownUntilItCloses() async throws {
        let stub = try CodeCLIStub()
        defer { stub.remove() }
        let clock = TestNow()
        let env = stub.environment(["STUB_FILES": "one.swift"])
        let codeIndex = CodeIndexCenter(resolveExecutable: { stub.executable.path }, environment: { env }, clock: { clock.now })
        let center = OpenQuicklyCenter(codeIndex: codeIndex, presenter: presenter, startSearch: searches.start)
        center.pageAppeared(project, window: nil)

        center.present(scope: .all)
        let index = codeIndex.index(for: project.id)
        let ready = await eventually { index.state == .ready }
        XCTAssertTrue(ready, "the panel started the index")
        XCTAssertEqual(stub.fullRuns, 1)
        clock.now += 600
        codeIndex.releaseIdleIndexes()
        XCTAssertTrue(codeIndex.index(for: project.id) === index, "kept while the panel is up")

        center.dismiss(restoringFocus: false)
        clock.now += 600
        codeIndex.releaseIdleIndexes()
        XCTAssertFalse(codeIndex.index(for: project.id) === index, "released once the panel went and the TTL passed")
        codeIndex.stopAll()
        await stub.assertAllGroupsReaped()
    }

    // MARK: Keys

    func testReturnOpensAPreviewTabAtTheSymbolsLineAndCloses() async {
        let (center, vm) = makeCenter()
        center.pageAppeared(project, window: nil)
        center.present(scope: .all)
        let session = try? XCTUnwrap(center.session)
        session?.updateQuery("savenow")
        XCTAssertEqual(session?.model.selectedRow?.target, OpenQuicklyTarget(path: "src/save.swift", line: 12, col: 10))

        center.perform(session?.activateSelection(option: false, command: false) ?? .none)
        XCTAssertNil(center.session)
        XCTAssertEqual(presenter.dismissals, [false], "an open leaves the keyboard to the editor")
        let opened = await eventually { vm.codeFiles.reveals[self.project.id] != nil }
        XCTAssertTrue(opened)
        let tabs = vm.codeFiles.tabs(for: project)
        XCTAssertEqual(tabs.active, "src/save.swift")
        XCTAssertEqual(tabs.tabs.first?.isPreview, true, "a preview tab")
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.line, 12)
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.col, 10)
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files))
        XCTAssertFalse(vm.layout(projectID: project.id).isSplit)
        XCTAssertEqual(vm.codeFiles.recentFiles(for: project), ["src/save.swift"], "a recently opened file")
    }

    func testOptionReturnOpensBesideThePaneOnScreenCreatingTheSplit() async {
        let (center, vm) = makeCenter()
        var single = WorkspaceLayout.default
        single.primary = .session(41)
        vm.setLayout(single, projectID: project.id)
        center.pageAppeared(project, window: nil)
        center.present(scope: .files)
        center.session?.updateQuery("readme")

        center.perform(center.session?.activateSelection(option: true, command: false) ?? .none)
        let split = await eventually { vm.layout(projectID: self.project.id).isSplit }
        XCTAssertTrue(split)
        let layout = vm.layout(projectID: project.id)
        XCTAssertEqual(layout.primary, .session(41), "the terminal stays")
        XCTAssertEqual(layout.secondary, .files)
        XCTAssertEqual(vm.codeFiles.tabs(for: project).active, "README.md")
        XCTAssertNil(vm.codeFiles.reveals[project.id]?.line, "a file row keeps its cursor")

        // Files already beside it: nothing moves.
        center.present(scope: .files)
        center.session?.updateQuery("save")
        center.perform(center.session?.activateSelection(option: true, command: false) ?? .none)
        _ = await eventually { vm.codeFiles.tabs(for: self.project).active == "src/save.swift" }
        XCTAssertEqual(vm.layout(projectID: project.id), layout)
    }

    func testCommandReturnAndTheAskRowReachTheAskHookAndKeepThePanel() {
        let (center, _) = makeCenter()
        var asked: [String] = []
        center.onAskAI = { query, project in
            XCTAssertEqual(project.id, 5)
            asked.append(query)
        }
        center.pageAppeared(project, window: nil)
        center.present(scope: .all)
        let session = center.session
        session?.updateQuery("why save")
        center.perform(session?.activateSelection(option: false, command: true) ?? .none)
        session?.select(OpenQuicklyRow.askAI(query: "why save").id)
        center.perform(session?.activateSelection(option: false, command: false) ?? .none)
        XCTAssertEqual(asked, ["why save", "why save"])
        XCTAssertNotNil(center.session)
    }

    // MARK: Text search

    func testTextSearchStartsAfterTheDebounceAndTypingCancelsThePreviousOne() async {
        let (center, _) = makeCenter()
        center.pageAppeared(project, window: nil)
        center.present(scope: .text)
        let session = center.session
        session?.updateQuery("sa")
        session?.updateQuery("sav")
        XCTAssertEqual(searches.started.count, 0, "nothing before 120 ms")
        let first = await eventually { self.searches.started.count == 1 }
        XCTAssertTrue(first)
        XCTAssertEqual(searches.started.first?.options.query, "sav", "only the last keystroke's query")
        XCTAssertEqual(searches.started.first?.options.context, 1)
        XCTAssertEqual(searches.started.first?.folder, project.folderURL)

        searches.started[0].onMatch(CodeSearchMatch(path: "a.go", line: 2, col: 1, text: "sav", textCol: 1, before: [], after: []))
        _ = await eventually { session?.model.textMatches.count == 1 }
        session?.updateQuery("save")
        XCTAssertTrue(searches.started[0].handle.cancelled, "the previous search is killed at the keystroke")
        XCTAssertEqual(session?.model.textMatches, [], "its matches go")
        let second = await eventually { self.searches.started.count == 2 }
        XCTAssertTrue(second)
        searches.started[1].onDone(.finished(CodeSearchDone(files: 3, matches: 0, truncated: false)))
        XCTAssertEqual(session?.model.textStatus, .finished(truncated: false))

        center.dismiss(restoringFocus: true)
        session?.updateQuery("late")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(searches.started.count, 2, "a closed panel starts no search")
    }

    func testFilesAndSymbolsDoNotSearchTextUntilAScopeShowsIt() async {
        let (center, _) = makeCenter()
        center.pageAppeared(project, window: nil)
        center.present(scope: .symbols)
        let session = center.session
        session?.updateQuery("save")
        XCTAssertEqual(session?.model.rows.map(\.id), [CodeQuickResult(item: .symbol(save), score: 0, titleMatches: [], pathMatches: []).id])
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(searches.started.count, 0)
        session?.updateScope(.all)
        let started = await eventually { self.searches.started.count == 1 }
        XCTAssertTrue(started, "All shows text: the query is searched now")
        session?.updateScope(.text)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(searches.started.count, 1, "the same query is not searched twice")
    }

    /// The real `CodeSearchRun` against the stub CLI: a keystroke kills the
    /// running child's process group.
    func testTypingKillsTheRunningSearchChild() async throws {
        let stub = try CodeCLIStub()
        defer { stub.remove() }
        let env = stub.environment()
        let center = OpenQuicklyCenter(
            codeIndex: CodeIndexCenter { nil }, presenter: presenter
        ) { folder, options, onMatch, onDone in
            CodeSearchRun.start(
                folder: folder, options: options, executable: stub.executable.path, environment: env,
                onMatch: onMatch, onDone: onDone
            )
        }
        center.pageAppeared(project, window: nil)
        center.present(scope: .text)
        let session = try XCTUnwrap(center.session)
        session.updateQuery("hit")
        let matched = await eventually { session.model.textMatches.count == 1 }
        XCTAssertTrue(matched, "the stub's match arrived")
        let pid = try XCTUnwrap(stub.startedPIDs.first)
        XCTAssertEqual(killpg(pid, 0), 0, "the search is still running (the stub sleeps)")

        session.updateQuery("hits")
        let killed = await eventually { killpg(pid, 0) != 0 }
        XCTAssertTrue(killed, "the keystroke killed the previous search")
        center.dismiss(restoringFocus: false)
        await stub.assertAllGroupsReaped()
    }

    // MARK: Preview

    func testThePreviewReadsTwelveLinesFromTheSymbol() async {
        let (center, _) = makeCenter()
        center.pageAppeared(project, window: nil)
        center.present(scope: .all)
        let session = center.session
        await session?.loadPreview(path: "src/save.swift", line: 12)
        let preview = session?.previews[OpenQuicklySession.previewKey(path: "src/save.swift", line: 12)]
        XCTAssertEqual(preview?.lines.map(\.number), Array(12 ... 23))
        XCTAssertEqual(preview?.lines.first?.text, "line 12")
        await session?.loadPreview(path: "gone.swift", line: 1)
        XCTAssertNotNil(session?.previews[OpenQuicklySession.previewKey(path: "gone.swift", line: 1)]?.error)
    }

    // MARK: Recently opened

    func testRecentlyOpenedFilesPersistPerWorkbenchWithoutGoneFiles() throws {
        let files = CodeFilesCenter(defaults: defaults, watchesFolders: false)
        files.open("README.md", project: project, preview: true)
        files.open("src/save.swift", project: project, preview: false)
        files.activate("README.md", project: project)
        XCTAssertEqual(files.recentFiles(for: project), ["README.md", "src/save.swift"])

        try FileManager.default.removeItem(at: folder.appendingPathComponent("src/save.swift"))
        let relaunched = CodeFilesCenter(defaults: defaults, watchesFolders: false)
        XCTAssertEqual(relaunched.recentFiles(for: project), ["README.md"], "a gone file is pruned")
        let other = Workbench(row: Row(["id": 6, "name": "other", "folder_path": folder.path]))
        XCTAssertEqual(relaunched.recentFiles(for: other), [], "per workbench")
    }
}

@MainActor
private final class RecordingPresenter: OpenQuicklyPresenting {
    var presented = 0
    var dismissals: [Bool] = []

    func presentPanel(_ session: OpenQuicklySession, center: OpenQuicklyCenter, over window: NSWindow?) {
        presented += 1
    }

    func dismissPanel(restoringFocus: Bool) {
        dismissals.append(restoringFocus)
    }
}

@MainActor
private final class FakeSearches {
    final class Handle: CodeSearchCancelling {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    struct Started {
        let folder: URL
        let options: CodeSearchOptions
        let handle: Handle
        let onMatch: @MainActor (CodeSearchMatch) -> Void
        let onDone: @MainActor (CodeSearchRun.Outcome) -> Void
    }

    var started: [Started] = []

    func start(
        _ folder: URL,
        _ options: CodeSearchOptions,
        _ onMatch: @escaping @MainActor (CodeSearchMatch) -> Void,
        _ onDone: @escaping @MainActor (CodeSearchRun.Outcome) -> Void
    ) -> CodeSearchCancelling {
        let handle = Handle()
        started.append(Started(folder: folder, options: options, handle: handle, onMatch: onMatch, onDone: onDone))
        return handle
    }
}

private final class TestNow: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 2_000_000)
}
