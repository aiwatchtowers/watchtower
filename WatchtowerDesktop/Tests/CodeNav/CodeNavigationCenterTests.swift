import AppKit
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Go to definition and the back/forward history (spec §8.2): one candidate
/// opens a kept tab with the cursor on the name; several ask through the
/// menu with "Show All Usages…" last; none fall back to the text-search
/// heuristic, then a beep and "No definition of `w`" for 2 s; ⌃⌘← returns
/// to the exact line and column a jump left from.
@MainActor
final class CodeNavigationCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var project: Workbench!
    private var menu: RecordingMenu!
    private var searches: DefinitionSearches!
    private var beeps = 0

    override func setUpWithError() throws {
        (pool, dbPath) = try TestDatabase.createPool()
        suite = "CodeNavigationCenterTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src/views"), withIntermediateDirectories: true)
        for path in ["src/views/list.swift", "src/store.swift", "lib/other.pl", "src/run.pl"] {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: url, atomically: true, encoding: .utf8)
        }
        project = Workbench(row: Row(["id": 9, "name": "acme", "folder_path": folder.path]))
        menu = RecordingMenu()
        searches = DefinitionSearches()
        beeps = 0
    }

    override func tearDownWithError() throws {
        pool = nil
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private let saveInStore = CodeSymbol(name: "save", kind: .method, path: "src/store.swift", line: 12, col: 10, endLine: 20, container: "Store")
    private let saveInList = CodeSymbol(name: "save", kind: .function, path: "src/views/list.swift", line: 3, col: 6, endLine: 5)
    private let loadInStore = CodeSymbol(name: "load", kind: .method, path: "src/store.swift", line: 30, col: 10, endLine: 32, container: "Store")

    private func makeCenter(symbols: [CodeSymbol]) -> (CodeNavigationCenter, WorkbenchesViewModel) {
        let codeIndex = CodeIndexCenter { nil }
        let center = CodeNavigationCenter(
            codeIndex: codeIndex, menu: menu, startSearch: searches.start,
            beep: { [weak self] in self?.beeps += 1 }, noticeDuration: .milliseconds(80)
        )
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        center.workbenches = vm
        vm.codeFiles.navigation = center
        // Swift files are indexed (even with no symbol); the Perl ones are
        // workbench files in a language the index does not read.
        var byFile = Dictionary(grouping: symbols, by: \.path)
        for path in ["src/views/list.swift", "src/store.swift"] where byFile[path] == nil { byFile[path] = [] }
        let swiftFiles: [CodeIndexLine] = byFile.map { path, symbols in
            .file(CodeIndexFileResult(file: path, lang: "swift", symbols: symbols))
        }
        let perlFiles: [CodeIndexLine] = ["src/run.pl", "lib/other.pl"].map { .file(CodeIndexFileResult(file: $0, lang: "", symbols: [])) }
        codeIndex.index(for: project.id).applyIndexLines(swiftFiles + perlFiles, from: .update)
        return (center, vm)
    }

    private func request(_ word: String, at path: String, _ line: Int, _ col: Int, req: Int = 1) -> CodeDefinitionRequest {
        CodeDefinitionRequest(req: req, word: word, origin: CodeNavLocation(path: path, line: line, col: col))
    }

    // MARK: Candidates

    func testOneCandidateOpensAKeptTabWithTheCursorOnTheName() async {
        let (center, vm) = makeCenter(symbols: [saveInStore, loadInStore])
        vm.codeFiles.open("src/views/list.swift", project: project, preview: true)
        await center.goToDefinition(request("save", at: "src/views/list.swift", 7, 4), project: project, anchor: nil)

        let tabs = vm.codeFiles.tabs(for: project)
        XCTAssertEqual(tabs.active, "src/store.swift")
        XCTAssertEqual(tabs.tabs.first { $0.path == "src/store.swift" }?.isPreview, false, "a kept tab, not a preview")
        XCTAssertTrue(tabs.contains("src/views/list.swift"), "the preview tab it left stays")
        let reveal = vm.codeFiles.reveals[project.id]
        XCTAssertEqual(reveal?.path, "src/store.swift")
        XCTAssertEqual(reveal?.line, 12)
        XCTAssertEqual(reveal?.col, 10)
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files), "the Files pane is on screen")
        XCTAssertTrue(menu.asked.isEmpty)
        XCTAssertTrue(searches.started.isEmpty, "no text search when the index knows the word")
        XCTAssertTrue(center.canGoBack(workbenchID: project.id))
        XCTAssertEqual(beeps, 0)
    }

    func testSeveralCandidatesAskWithEveryOneNearestFirstAndUsagesLast() async {
        let (center, vm) = makeCenter(symbols: [saveInStore, saveInList])
        menu.answer = .choice(1)
        let anchor = DefinitionMenuAnchor(view: nil, point: NSPoint(x: 40, y: 80))
        await center.goToDefinition(request("save", at: "src/views/edit.swift", 2, 9), project: project, anchor: anchor)

        XCTAssertEqual(menu.asked.count, 1)
        let asked = menu.asked.first
        XCTAssertEqual(asked?.header, "save — 2 definitions")
        XCTAssertEqual(asked?.choices.map(\.title), ["save", "Store.save"], "the same folder first")
        XCTAssertEqual(asked?.choices.map(\.location), ["src/views/list.swift:3", "src/store.swift:12"])
        XCTAssertEqual(asked?.choices.map(\.kind), [.function, .method])
        XCTAssertEqual(asked?.point, NSPoint(x: 40, y: 80))
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.path, "src/store.swift", "the picked one opens")
        XCTAssertEqual(vm.codeFiles.tabs(for: project).tabs.first?.isPreview, false)
    }

    func testShowAllUsagesFromTheMenuReachesTheUsagesHook() async {
        let (center, vm) = makeCenter(symbols: [saveInStore, saveInList])
        var usages: [String] = []
        center.onShowUsages = { word, _ in usages.append(word) }
        menu.answer = .showAllUsages
        await center.goToDefinition(request("save", at: "src/run.pl", 1, 1), project: project, anchor: nil)
        XCTAssertEqual(usages, ["save"])
        XCTAssertNil(vm.codeFiles.reveals[project.id])
        XCTAssertFalse(center.canGoBack(workbenchID: project.id), "no jump, no history")
    }

    func testDismissingTheMenuGoesNowhere() async {
        let (center, vm) = makeCenter(symbols: [saveInStore, saveInList])
        menu.answer = .dismissed
        await center.goToDefinition(request("save", at: "src/run.pl", 1, 1), project: project, anchor: nil)
        XCTAssertNil(vm.codeFiles.reveals[project.id])
        XCTAssertTrue(vm.codeFiles.tabs(for: project).tabs.isEmpty)
        XCTAssertFalse(center.canGoBack(workbenchID: project.id))
    }

    // MARK: Heuristic and nothing found

    func testNoCandidateSearchesTheWordAndJumpsToTheOneDefinitionLookingLine() async {
        let (center, vm) = makeCenter(symbols: [])
        let task = Task { await center.goToDefinition(request("frob", at: "src/run.pl", 4, 3), project: project, anchor: nil) }
        let started = await eventually { self.searches.started.count == 1 }
        XCTAssertTrue(started)
        let options = searches.started.first?.options
        XCTAssertEqual(options?.query, "frob")
        XCTAssertEqual(options?.word, true)
        XCTAssertEqual(options?.caseSensitive, true)
        XCTAssertEqual(options?.regex, false)
        XCTAssertEqual(searches.started.first?.folder.path, project.folderURL.path)
        searches.started.first?.onMatch(match("src/run.pl", 4, col: 3, "  frob($x);"))
        searches.started.first?.onMatch(match("lib/other.pl", 7, col: 5, "sub frob {"))
        searches.started.first?.onDone(.finished(CodeSearchDone(files: 2, matches: 2, truncated: false)))
        await task.value

        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.path, "lib/other.pl")
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.line, 7)
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.col, 5)
        XCTAssertTrue(menu.asked.isEmpty, "the clicked occurrence is not a choice")
        XCTAssertEqual(beeps, 0)
    }

    /// Ruling R31: in a language the index reads, a miss is a miss — no
    /// folder-wide text search.
    func testAMissInAnIndexedLanguageBeepsWithoutSearching() async {
        let (center, vm) = makeCenter(symbols: [loadInStore])
        await center.goToDefinition(request("frob", at: "src/store.swift", 30, 12), project: project, anchor: nil)
        XCTAssertTrue(searches.started.isEmpty, "no text search for an indexed file")
        XCTAssertEqual(beeps, 1)
        XCTAssertEqual(center.notice(for: project.id), "No definition of `frob`")
        XCTAssertNil(vm.codeFiles.reveals[project.id])
    }

    func testAFileTheIndexHasNotSeenFallsBackToTheTextSearch() async {
        let (center, _) = makeCenter(symbols: [])
        let task = Task { await center.goToDefinition(request("frob", at: "new/file.swift", 1, 1), project: project, anchor: nil) }
        let started = await eventually { self.searches.started.count == 1 }
        XCTAssertTrue(started, "not in the index yet: its language is not known")
        searches.started.first?.onDone(.finished(CodeSearchDone(files: 0, matches: 0, truncated: false)))
        await task.value
    }

    func testSeveralTextMatchesAskWithDefinitionLooksFirst() async {
        let (center, _) = makeCenter(symbols: [])
        menu.answer = .dismissed
        let task = Task { await center.goToDefinition(request("frob", at: "src/run.pl", 1, 1), project: project, anchor: nil) }
        _ = await eventually { self.searches.started.count == 1 }
        searches.started.first?.onMatch(match("lib/other.pl", 2, "frob();"))
        searches.started.first?.onMatch(match("lib/other.pl", 9, "sub frob {"))
        searches.started.first?.onDone(.finished(CodeSearchDone(files: 1, matches: 2, truncated: false)))
        await task.value
        XCTAssertEqual(menu.asked.first?.header, "frob — 2 text matches")
        XCTAssertEqual(menu.asked.first?.choices.map(\.location), ["lib/other.pl:9", "lib/other.pl:2"])
    }

    func testNothingAnywhereBeepsAndSaysSoForAWhile() async {
        let (center, vm) = makeCenter(symbols: [])
        let task = Task { await center.goToDefinition(request("frob", at: "src/run.pl", 1, 1), project: project, anchor: nil) }
        _ = await eventually { self.searches.started.count == 1 }
        searches.started.first?.onMatch(match("src/run.pl", 1, "frob"))
        searches.started.first?.onDone(.finished(CodeSearchDone(files: 1, matches: 1, truncated: false)))
        await task.value

        XCTAssertEqual(beeps, 1)
        XCTAssertEqual(center.notice(for: project.id), "No definition of `frob`")
        XCTAssertNil(vm.codeFiles.reveals[project.id])
        let cleared = await eventually { center.notice(for: self.project.id) == nil }
        XCTAssertTrue(cleared, "the notice goes after its time")
    }

    func testAFailedTextSearchSaysWhy() async {
        let (center, _) = makeCenter(symbols: [])
        let task = Task { await center.goToDefinition(request("frob", at: "src/run.pl", 1, 1), project: project, anchor: nil) }
        _ = await eventually { self.searches.started.count == 1 }
        searches.started.first?.onDone(.failed("code search exited 2: boom"))
        await task.value
        XCTAssertEqual(beeps, 1)
        XCTAssertEqual(center.notice(for: project.id), "No definition of `frob` — text search failed: code search exited 2: boom")
    }

    func testANewRequestCancelsTheSearchInFlightAndTheOldOneEnds() async {
        let (center, vm) = makeCenter(symbols: [saveInStore])
        let first = Task { await center.goToDefinition(request("frob", at: "src/run.pl", 1, 1, req: 1), project: project, anchor: nil) }
        _ = await eventually { self.searches.started.count == 1 }
        await center.goToDefinition(request("save", at: "src/run.pl", 1, 1, req: 2), project: project, anchor: nil)
        let ended = await finishes(first)
        XCTAssertTrue(ended, "the superseded request returns")
        XCTAssertEqual(searches.started.first?.handle.cancelled, true, "the old search is killed")
        searches.started.first?.onMatch(match("lib/other.pl", 9, "sub frob {"))
        searches.started.first?.onDone(.finished(CodeSearchDone(files: 1, matches: 1, truncated: false)))
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.path, "src/store.swift", "only the newer request lands")
        XCTAssertEqual(beeps, 0)
    }

    func testThePageGoingAwayCancelsItsSearch() async {
        let (center, _) = makeCenter(symbols: [])
        let page = FakeDefinitionPage(answer: true)
        center.registerPage(page, for: project.id)
        let task = Task { await center.goToDefinition(request("frob", at: "src/run.pl", 1, 1), project: project, anchor: nil) }
        _ = await eventually { self.searches.started.count == 1 }
        center.unregisterPage(page, for: project.id)
        let ended = await finishes(task)
        XCTAssertTrue(ended, "the request returns once its page went")
        XCTAssertEqual(searches.started.first?.handle.cancelled, true)
        XCTAssertEqual(beeps, 0, "a cancelled search is not a miss")
    }

    // MARK: Go to Definition (⌃⌘J)

    func testTheMenuCommandAsksThePageForTheWordAtTheCursor() async {
        let (center, _) = makeCenter(symbols: [])
        await center.goToDefinitionAtCursor(project: project)
        XCTAssertEqual(beeps, 1, "no editor page: nothing to ask")
        let page = FakeDefinitionPage(answer: false)
        center.registerPage(page, for: project.id)
        await center.goToDefinitionAtCursor(project: project)
        XCTAssertEqual(page.asked, 1)
        XCTAssertEqual(beeps, 2, "no word at the cursor")
        page.answer = true
        await center.goToDefinitionAtCursor(project: project)
        XCTAssertEqual(beeps, 2, "the page posts definition itself")
        center.unregisterPage(FakeDefinitionPage(answer: true), for: project.id)
        await center.goToDefinitionAtCursor(project: project)
        XCTAssertEqual(page.asked, 3, "another page's unregister leaves this one")
    }

    // MARK: History

    func testBackAfterAJumpReturnsToTheExactLineAndColumnAndForwardComesBack() async {
        let (center, vm) = makeCenter(symbols: [saveInStore])
        vm.codeFiles.open("src/views/list.swift", project: project, preview: true)
        await center.goToDefinition(request("save", at: "src/views/list.swift", 7, 4), project: project, anchor: nil)
        // The page reports the cursor where the reveal put it.
        vm.codeFiles.cursorMoved(CodeNavLocation(path: "src/store.swift", line: 12, col: 10), workbenchID: project.id)
        XCTAssertFalse(center.canGoForward(workbenchID: project.id))

        center.goBack(project: project)
        let back = vm.codeFiles.reveals[project.id]
        XCTAssertEqual(back.map { CodeNavLocation(path: $0.path, line: $0.line ?? 0, col: $0.col) },
                       CodeNavLocation(path: "src/views/list.swift", line: 7, col: 4))
        let tabs = vm.codeFiles.tabs(for: project)
        XCTAssertEqual(tabs.active, "src/views/list.swift")
        XCTAssertEqual(tabs.tabs.first { $0.path == "src/views/list.swift" }?.isPreview, true, "back activates the tab, keeps it as it was")
        XCTAssertFalse(center.canGoBack(workbenchID: project.id))
        XCTAssertTrue(center.canGoForward(workbenchID: project.id))

        vm.codeFiles.cursorMoved(CodeNavLocation(path: "src/views/list.swift", line: 7, col: 4), workbenchID: project.id)
        center.goForward(project: project)
        let forward = vm.codeFiles.reveals[project.id]
        XCTAssertEqual(forward?.path, "src/store.swift")
        XCTAssertEqual(forward?.line, 12)
        XCTAssertEqual(forward?.col, 10)
    }

    func testBackReopensAClosedFileAsAKeptTab() async {
        let (center, vm) = makeCenter(symbols: [saveInStore])
        vm.codeFiles.open("src/views/list.swift", project: project, preview: false)
        await center.goToDefinition(request("save", at: "src/views/list.swift", 2, 2), project: project, anchor: nil)
        await vm.codeFiles.close(["src/views/list.swift"], project: project)
        center.goBack(project: project)
        let tabs = vm.codeFiles.tabs(for: project)
        XCTAssertEqual(tabs.active, "src/views/list.swift")
        XCTAssertEqual(tabs.tabs.first { $0.path == "src/views/list.swift" }?.isPreview, false)
    }

    func testHistoryIsPerWorkbenchAndOutlivesThePage() async {
        let (center, _) = makeCenter(symbols: [saveInStore])
        let page = FakeDefinitionPage(answer: true)
        center.registerPage(page, for: project.id)
        await center.goToDefinition(request("save", at: "src/run.pl", 1, 1), project: project, anchor: nil)
        center.unregisterPage(page, for: project.id)
        XCTAssertTrue(center.canGoBack(workbenchID: project.id), "the Files pane going away keeps its history")
        XCTAssertFalse(center.canGoBack(workbenchID: 1234))
        XCTAssertFalse(center.canGoBack(workbenchID: nil))
    }

    /// Whether `task` ends within `eventually`'s wait — a failure, not a
    /// hung run, when a cancelled search never answers its caller.
    private func finishes(_ task: Task<Void, Never>) async -> Bool {
        var done = false
        Task { @MainActor in
            await task.value
            done = true
        }
        return await eventually { done }
    }

    private func match(_ path: String, _ line: Int, col: Int = 1, _ text: String) -> CodeSearchMatch {
        CodeSearchMatch(path: path, line: line, col: col, text: text, textCol: col, before: [], after: [])
    }
}

@MainActor
private final class RecordingMenu: DefinitionMenuPresenting {
    struct Asked {
        let header: String
        let choices: [DefinitionChoice]
        let point: NSPoint?
    }

    var asked: [Asked] = []
    var answer: DefinitionMenuPick = .dismissed

    func pickDefinition(header: String, choices: [DefinitionChoice], at anchor: DefinitionMenuAnchor?) async -> DefinitionMenuPick {
        asked.append(Asked(header: header, choices: choices, point: anchor?.point))
        return answer
    }
}

@MainActor
private final class FakeDefinitionPage: CodeDefinitionPage {
    var answer: Bool
    var asked = 0

    init(answer: Bool) {
        self.answer = answer
    }

    func requestDefinitionAtCursor() async -> Bool {
        asked += 1
        return answer
    }
}

@MainActor
private final class DefinitionSearches {
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
