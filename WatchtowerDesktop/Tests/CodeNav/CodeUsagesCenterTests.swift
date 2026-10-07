import Darwin
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Usages (spec §8.3): ⇧⌘U on the word at the cursor, the editor's context
/// menu and the definition menu's "Show All Usages…" all start
/// `code search --word --case` for the name and put the inspector on its
/// Usages tab; matches stream into groups; a new name cancels the search
/// before it; a row click opens the file at the line; the Files pane going
/// away stops (and reaps) the search.
@MainActor
final class CodeUsagesCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var project: Workbench!
    private var searches: UsagesSearches!
    private var beeps = 0

    override func setUpWithError() throws {
        (pool, dbPath) = try TestDatabase.createPool()
        suite = "CodeUsagesCenterTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("usages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        for path in ["src/store.swift", "src/list.swift"] {
            try "x\n".write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        project = Workbench(row: Row(["id": 9, "name": "acme", "folder_path": folder.path]))
        searches = UsagesSearches()
        beeps = 0
    }

    override func tearDownWithError() throws {
        pool = nil
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeCenter(startSearch: CodeSearchStarter? = nil) -> (CodeUsagesCenter, WorkbenchesViewModel) {
        let center = CodeUsagesCenter(defaults: defaults, startSearch: startSearch ?? searches.start) { [weak self] in self?.beeps += 1 }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        center.workbenches = vm
        vm.codeFiles.usages = center
        return (center, vm)
    }

    private func hit(_ path: String, _ line: Int, _ text: String = "save()", col: Int = 1) -> CodeSearchMatch {
        CodeSearchMatch(path: path, line: line, col: col, text: text, textCol: col, before: [], after: [])
    }

    // MARK: Search

    func testShowUsagesSearchesTheWholeWordCaseSensitiveAndShowsTheUsagesTab() {
        let (center, _) = makeCenter()
        center.selectInspectorTab(.questions, workbenchID: project.id)
        center.showUsages(of: "save", project: project)
        XCTAssertEqual(searches.started.count, 1)
        let started = searches.started[0]
        XCTAssertEqual(started.folder, project.folderURL)
        XCTAssertEqual(started.options.query, "save")
        XCTAssertTrue(started.options.word, "--word")
        XCTAssertTrue(started.options.caseSensitive, "--case")
        XCTAssertFalse(started.options.regex)
        XCTAssertTrue(center.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .usages)
        XCTAssertEqual(center.usages(for: project.id)?.header, "Usages — save · 0")
        XCTAssertEqual(center.usages(for: project.id)?.status, .searching)
    }

    func testMatchesStreamIntoGroupsAndTheEndIsShown() {
        let (center, _) = makeCenter()
        center.showUsages(of: "save", project: project)
        let started = searches.started[0]
        started.onMatch(hit("src/store.swift", 3))
        XCTAssertEqual(center.usages(for: project.id)?.header, "Usages — save · 1", "a match shows before the search ends")
        started.onMatch(hit("src/list.swift", 1))
        started.onMatch(hit("src/store.swift", 9))
        started.onDone(.finished(CodeSearchDone(files: 2, matches: 3, truncated: false)))
        let model = center.usages(for: project.id)
        XCTAssertEqual(model?.groups.map(\.path), ["src/store.swift", "src/list.swift"])
        XCTAssertEqual(model?.header, "Usages — save · 3")
        XCTAssertEqual(model?.status, .finished(truncated: false))
    }

    func testAFailedSearchSaysWhy() {
        let (center, _) = makeCenter()
        center.showUsages(of: "save", project: project)
        searches.started[0].onDone(.failed("exit status 2: no such folder"))
        XCTAssertEqual(center.usages(for: project.id)?.statusText, "The search failed: exit status 2: no such folder")
    }

    func testANewNameClearsTheListAndCancelsTheSearchBefore() {
        let (center, _) = makeCenter()
        center.showUsages(of: "save", project: project)
        let first = searches.started[0]
        first.onMatch(hit("src/store.swift", 3))
        center.setCollapsed(true, path: "src/store.swift", workbenchID: project.id)
        center.showUsages(of: "load", project: project)
        XCTAssertTrue(first.handle.cancelled, "the old run is cancelled")
        XCTAssertFalse(searches.started[1].handle.cancelled)
        XCTAssertEqual(center.usages(for: project.id)?.header, "Usages — load · 0", "the list starts over")
        XCTAssertEqual(center.usages(for: project.id)?.isCollapsed("src/store.swift"), false)
        // A late callback of the old run changes nothing.
        first.onMatch(hit("src/list.swift", 1))
        first.onDone(.finished(CodeSearchDone(files: 1, matches: 1, truncated: false)))
        XCTAssertEqual(center.usages(for: project.id)?.count, 0)
        XCTAssertEqual(center.usages(for: project.id)?.status, .searching)
    }

    func testCollapsingAGroupSurvivesNewArrivals() {
        let (center, _) = makeCenter()
        center.showUsages(of: "save", project: project)
        let started = searches.started[0]
        started.onMatch(hit("src/store.swift", 3))
        center.setCollapsed(true, path: "src/store.swift", workbenchID: project.id)
        started.onMatch(hit("src/store.swift", 9))
        started.onMatch(hit("src/list.swift", 1))
        XCTAssertEqual(center.usages(for: project.id)?.isCollapsed("src/store.swift"), true)
        XCTAssertEqual(center.usages(for: project.id)?.count, 3)
    }

    func testWorkbenchesKeepTheirOwnLists() {
        let (center, _) = makeCenter()
        let other = Workbench(row: Row(["id": 10, "name": "other", "folder_path": folder.path]))
        center.showUsages(of: "save", project: project)
        center.showUsages(of: "load", project: other)
        XCTAssertFalse(searches.started[0].handle.cancelled, "another workbench's search goes on")
        XCTAssertEqual(center.usages(for: project.id)?.word, "save")
        XCTAssertEqual(center.usages(for: other.id)?.word, "load")
    }

    func testAnEmptyWordBeepsAndSearchesNothing() {
        let (center, _) = makeCenter()
        center.showUsages(of: "", project: project)
        XCTAssertEqual(searches.started.count, 0)
        XCTAssertEqual(beeps, 1)
        XCTAssertNil(center.usages(for: project.id))
    }

    // MARK: Triggers

    func testShiftCommandUAsksThePageForTheWordAtTheCursor() async {
        let (center, _) = makeCenter()
        let page = FakeUsagesPage(answer: true)
        center.registerPage(page, for: project.id)
        await center.showUsagesAtCursor(project: project)
        XCTAssertEqual(page.asked, 1)
        XCTAssertEqual(beeps, 0, "the page posts `usages`; the Files pane hands the word to showUsages")
    }

    func testShiftCommandUWithoutAWordOrAnEditorBeeps() async {
        let (center, _) = makeCenter()
        await center.showUsagesAtCursor(project: project)
        XCTAssertEqual(beeps, 1, "no editor")
        let page = FakeUsagesPage(answer: false)
        center.registerPage(page, for: project.id)
        await center.showUsagesAtCursor(project: project)
        XCTAssertEqual(page.asked, 1)
        XCTAssertEqual(beeps, 2, "no word at the cursor")
        XCTAssertEqual(searches.started.count, 0)
    }

    func testShowAllUsagesFromTheDefinitionMenuStartsTheSameSearch() async {
        let (center, vm) = makeCenter()
        let menu = PickingMenu()
        let codeIndex = CodeIndexCenter(resolveExecutable: { nil }, rulesFile: CodeIndexCenter.testRulesFile)
        let navigation = CodeNavigationCenter(codeIndex: codeIndex, menu: menu, startSearch: searches.start) {}
        navigation.workbenches = vm
        navigation.usages = center
        let symbols = [
            CodeSymbol(name: "save", kind: .method, path: "src/store.swift", line: 12, col: 10, endLine: 20, container: "Store"),
            CodeSymbol(name: "save", kind: .function, path: "src/list.swift", line: 3, col: 6, endLine: 5)
        ]
        let index: [CodeIndexLine] = symbols.map { .file(CodeIndexFileResult(file: $0.path, lang: "swift", symbols: [$0])) }
        codeIndex.index(for: project.id).applyIndexLines(index, from: .update)
        let request = CodeDefinitionRequest(req: 1, word: "save", origin: CodeNavLocation(path: "src/store.swift", line: 1, col: 1))
        await navigation.goToDefinition(request, project: project, anchor: nil)
        XCTAssertEqual(menu.asked, 1)
        XCTAssertEqual(searches.started.map(\.options.query), ["save"])
        XCTAssertTrue(searches.started[0].options.word && searches.started[0].options.caseSensitive)
        XCTAssertTrue(center.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .usages)
    }

    // MARK: Rows

    func testARowClickOpensTheFileAtTheLine() async throws {
        let (center, vm) = makeCenter()
        center.showUsages(of: "save", project: project)
        searches.started[0].onMatch(hit("src/list.swift", 1, "  save()", col: 3))
        let row = try XCTUnwrap(center.usages(for: project.id)?.groups.first?.rows.first)
        await center.openUsage(row, project: project)
        XCTAssertEqual(vm.codeFiles.tabs(for: project).active, "src/list.swift")
        let reveal = vm.codeFiles.reveals[project.id]
        XCTAssertEqual(reveal?.path, "src/list.swift")
        XCTAssertEqual(reveal?.line, 1)
        XCTAssertEqual(reveal?.col, 3)
        XCTAssertEqual(vm.layout(projectID: project.id).visiblePanes.contains(.files), true, "the Files pane is on screen")
    }

    /// Ruling R33: a row click is a navigation jump — the cursor it left
    /// goes on the pane's Back history, as a definition jump's does.
    func testARowClickIsAJumpThatBackReturnsFrom() async throws {
        let (center, vm) = makeCenter()
        let navigation = makeNavigation(vm: vm, usages: center)
        vm.codeFiles.open("src/store.swift", project: project, preview: false)
        let before = CodeNavLocation(path: "src/store.swift", line: 5, col: 2)
        vm.codeFiles.cursorMoved(before, workbenchID: project.id)
        center.showUsages(of: "save", project: project)
        searches.started[0].onMatch(hit("src/list.swift", 1, "save()", col: 1))
        let row = try XCTUnwrap(center.usages(for: project.id)?.groups.first?.rows.first)
        await center.openUsage(row, project: project)
        XCTAssertTrue(navigation.canGoBack(workbenchID: project.id))
        navigation.goBack(project: project)
        XCTAssertEqual(vm.codeFiles.tabs(for: project).active, "src/store.swift")
        let reveal = vm.codeFiles.reveals[project.id]
        XCTAssertEqual(reveal?.path, "src/store.swift")
        XCTAssertEqual(reveal?.line, 5)
        XCTAssertEqual(reveal?.col, 2)
    }

    func testRowClicksFromTheSamePlaceRecordItOnce() async throws {
        let (center, vm) = makeCenter()
        let navigation = makeNavigation(vm: vm, usages: center)
        vm.codeFiles.open("src/list.swift", project: project, preview: false)
        let place = CodeNavLocation(path: "src/list.swift", line: 1, col: 1)
        let usage = CodeNavLocation(path: "src/list.swift", line: 3, col: 1)
        vm.codeFiles.cursorMoved(place, workbenchID: project.id)
        center.showUsages(of: "save", project: project)
        searches.started[0].onMatch(hit("src/list.swift", 3, "save()", col: 1))
        let row = try XCTUnwrap(center.usages(for: project.id)?.groups.first?.rows.first)
        await center.openUsage(row, project: project)
        // Back at the same place in the same file, the row again.
        vm.codeFiles.cursorMoved(place, workbenchID: project.id)
        await center.openUsage(row, project: project)
        vm.codeFiles.cursorMoved(usage, workbenchID: project.id)
        navigation.goBack(project: project)
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.line, 1, "Back lands on the place the clicks left")
        XCTAssertFalse(navigation.canGoBack(workbenchID: project.id), "one entry, not two")
    }

    func testARowClickWithNoKnownCursorRecordsNothing() async throws {
        let (center, vm) = makeCenter()
        let navigation = makeNavigation(vm: vm, usages: center)
        center.showUsages(of: "save", project: project)
        searches.started[0].onMatch(hit("src/list.swift", 1, "save()", col: 1))
        let row = try XCTUnwrap(center.usages(for: project.id)?.groups.first?.rows.first)
        await center.openUsage(row, project: project)
        XCTAssertFalse(navigation.canGoBack(workbenchID: project.id))
        XCTAssertEqual(vm.codeFiles.tabs(for: project).active, "src/list.swift", "the row still opens")
    }

    private func makeNavigation(vm: WorkbenchesViewModel, usages: CodeUsagesCenter) -> CodeNavigationCenter {
        let codeIndex = CodeIndexCenter(resolveExecutable: { nil }, rulesFile: CodeIndexCenter.testRulesFile)
        let navigation = CodeNavigationCenter(codeIndex: codeIndex, startSearch: searches.start) {}
        navigation.workbenches = vm
        vm.codeFiles.navigation = navigation
        usages.navigation = navigation
        return navigation
    }

    // MARK: Inspector

    func testTheInspectorIsPerWorkbenchAndRemembersItsTab() {
        let (center, _) = makeCenter()
        XCTAssertFalse(center.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .usages)
        center.setInspectorShown(true, workbenchID: project.id)
        center.selectInspectorTab(.questions, workbenchID: project.id)
        XCTAssertTrue(center.isInspectorShown(workbenchID: project.id))
        XCTAssertFalse(center.isInspectorShown(workbenchID: 10))
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .questions)
        center.setInspectorShown(false, workbenchID: project.id)
        XCTAssertFalse(center.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .questions)
    }

    func testTheInspectorAndItsTabSurviveANewCenter() {
        let (center, _) = makeCenter()
        center.setInspectorShown(true, workbenchID: project.id)
        center.selectInspectorTab(.questions, workbenchID: project.id)
        center.setInspectorShown(true, workbenchID: 10)
        center.setInspectorShown(false, workbenchID: 10)

        let (relaunched, _) = makeCenter()
        XCTAssertTrue(relaunched.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(relaunched.inspectorTab(workbenchID: project.id), .questions)
        XCTAssertFalse(relaunched.isInspectorShown(workbenchID: 10), "a closed inspector stays closed")
        XCTAssertEqual(relaunched.inspectorTab(workbenchID: 10), .usages)
    }

    func testShowUsagesKeepsTheInspectorOpenOnUsagesAcrossLaunches() {
        let (center, _) = makeCenter()
        center.selectInspectorTab(.questions, workbenchID: project.id)
        center.showUsages(of: "save", project: project)

        let (relaunched, _) = makeCenter()
        XCTAssertTrue(relaunched.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(relaunched.inspectorTab(workbenchID: project.id), .usages)
    }

    func testAnInspectorStoredByAnEarlierRunIsRead() {
        defaults.set(["/ws/a.db": [Int64(project.id)]], forKey: CodeUsagesCenter.shownInspectorsKey)
        defaults.set(
            ["/ws/a.db": ["\(project.id)": "questions", "12": "bogus"]], forKey: CodeUsagesCenter.inspectorTabsKey
        )
        let (center, _) = makeCenter()
        center.useWorkspace("/ws/a.db")
        XCTAssertTrue(center.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .questions)
        XCTAssertEqual(center.inspectorTab(workbenchID: 12), .usages, "an unknown tab falls back to Usages")
    }

    func testWorkspacesKeepTheirOwnInspectorsForTheSameWorkbenchID() {
        let (center, _) = makeCenter()
        center.useWorkspace("/ws/a.db")
        center.setInspectorShown(true, workbenchID: project.id)
        center.selectInspectorTab(.questions, workbenchID: project.id)

        center.useWorkspace("/ws/b.db")
        XCTAssertFalse(center.isInspectorShown(workbenchID: project.id), "workspace B's workbench 9 is another workbench")
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .usages)
        center.setInspectorShown(true, workbenchID: 10)

        let (relaunched, _) = makeCenter()
        relaunched.useWorkspace("/ws/a.db")
        XCTAssertTrue(relaunched.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(relaunched.inspectorTab(workbenchID: project.id), .questions)
        XCTAssertFalse(relaunched.isInspectorShown(workbenchID: 10))
        relaunched.useWorkspace("/ws/b.db")
        XCTAssertFalse(relaunched.isInspectorShown(workbenchID: project.id))
        XCTAssertTrue(relaunched.isInspectorShown(workbenchID: 10))
    }

    func testADeletedWorkbenchLeavesNoStoredInspector() {
        let (center, _) = makeCenter()
        center.useWorkspace("/ws/a.db")
        center.setInspectorShown(true, workbenchID: project.id)
        center.selectInspectorTab(.questions, workbenchID: project.id)
        center.setInspectorShown(true, workbenchID: 10)

        center.workbenchRemoved(project.id)
        XCTAssertFalse(center.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(center.inspectorTab(workbenchID: project.id), .usages)
        XCTAssertTrue(center.isInspectorShown(workbenchID: 10), "the other workbench keeps its inspector")

        let (relaunched, _) = makeCenter()
        relaunched.useWorkspace("/ws/a.db")
        XCTAssertFalse(relaunched.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(relaunched.inspectorTab(workbenchID: project.id), .usages)
        XCTAssertTrue(relaunched.isInspectorShown(workbenchID: 10))
    }

    // MARK: The Files pane goes away

    func testThePaneGoingAwayStopsItsSearchAndKeepsTheList() {
        let (center, _) = makeCenter()
        let page = FakeUsagesPage(answer: true)
        center.registerPage(page, for: project.id)
        center.showUsages(of: "save", project: project)
        searches.started[0].onMatch(hit("src/store.swift", 3))
        center.unregisterPage(page, for: project.id)
        XCTAssertTrue(searches.started[0].handle.cancelled)
        XCTAssertEqual(center.usages(for: project.id)?.count, 1)
        XCTAssertEqual(center.usages(for: project.id)?.status, .stopped)
    }

    func testAnotherPageLeavingStopsNothing() {
        let (center, _) = makeCenter()
        let page = FakeUsagesPage(answer: true)
        center.registerPage(page, for: project.id)
        center.showUsages(of: "save", project: project)
        center.unregisterPage(FakeUsagesPage(answer: true), for: project.id)
        XCTAssertFalse(searches.started[0].handle.cancelled)
    }

    /// The real `code search` child (a stub CLI): a new name and the pane
    /// leaving each kill and reap the process group of the search before.
    func testSpawnedSearchesAreReapedOnANewNameAndWhenThePaneGoes() async throws {
        let stub = try CodeCLIStub()
        defer { stub.remove() }
        let (center, _) = makeCenter { folder, options, onMatch, onDone in
            CodeSearchRun.start(
                folder: folder, options: options, executable: stub.executable.path, environment: stub.environment(),
                onMatch: onMatch, onDone: onDone
            )
        }
        let page = FakeUsagesPage(answer: true)
        center.registerPage(page, for: project.id)
        center.showUsages(of: "hit", project: project)
        let first = await eventually { center.usages(for: self.project.id)?.count == 1 }
        XCTAssertTrue(first, "the stub's match arrived")
        let firstPID = try XCTUnwrap(stub.startedPIDs.first)

        center.showUsages(of: "other", project: project)
        let secondStarted = await eventually { stub.startedPIDs.count == 2 && center.usages(for: self.project.id)?.count == 1 }
        XCTAssertTrue(secondStarted)
        let firstGone = await eventually { killpg(firstPID, 0) != 0 }
        XCTAssertTrue(firstGone, "the superseded search's group is gone")
        XCTAssertEqual(center.usages(for: project.id)?.word, "other")

        center.unregisterPage(page, for: project.id)
        await stub.assertAllGroupsReaped()
        XCTAssertEqual(center.usages(for: project.id)?.status, .stopped)
    }
}

@MainActor
private final class FakeUsagesPage: CodeUsagesPage {
    var answer: Bool
    var asked = 0

    init(answer: Bool) {
        self.answer = answer
    }

    func requestUsagesAtCursor() async -> Bool {
        asked += 1
        return answer
    }
}

@MainActor
private final class PickingMenu: DefinitionMenuPresenting {
    var asked = 0

    func pickDefinition(header: String, choices: [DefinitionChoice], at anchor: DefinitionMenuAnchor?) async -> DefinitionMenuPick {
        asked += 1
        return .showAllUsages
    }
}

@MainActor
private final class UsagesSearches {
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
