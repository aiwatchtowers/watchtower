import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Code navigation lands in the review (board #960, spec §2): a file of the
/// diff is selected with its line asked for; any other file is previewed.
extension ReviewChangesModelTests {
    private func navigationHarness() async throws -> ReviewModelHarness {
        let h = try harness()
        h.baseScript(paths: ["apps/web/a.go", "apps/web/b.go"])
        h.cli.script("file", [fileJSON(old: "a\n", new: "a2\n"), fileJSON(old: "b\n", new: "b2\n")])
        await h.model.open()
        await h.model.select("apps/web/a.go")
        h.model.pathMap = ReviewPathMap(repoPrefix: "apps/web")
        return h
    }

    func testShowLocationOnADiffFileSelectsItAndAsksForTheLine() async throws {
        let h = try await navigationHarness()
        let shown = h.model.showLocation(CodeNavLocation(path: "b.go", line: 5, col: 2))
        XCTAssertTrue(shown)
        XCTAssertEqual(h.model.selectedPath, "apps/web/b.go")
        XCTAssertNil(h.model.preview)
        XCTAssertEqual(h.model.focusRequest?.path, "apps/web/b.go")
        XCTAssertEqual(h.model.focusRequest?.line, 5)
        XCTAssertEqual(h.model.currentLocation, CodeNavLocation(path: "b.go", line: 5, col: 1))
        await h.model.navigationLoad?.value
        XCTAssertEqual(h.model.currentSides?.new.text, "b2\n")

        let first = try XCTUnwrap(h.model.focusRequest)
        XCTAssertTrue(h.model.showLocation(CodeNavLocation(path: "b.go", line: 5, col: 2)))
        XCTAssertNotEqual(h.model.focusRequest, first, "the same line asked again fires again")
        XCTAssertEqual(h.cli.calls("file").count, 2, "the file on screen is not read again")
    }

    func testShowLocationWithoutALineSelectsTheFileOnly() async throws {
        let h = try await navigationHarness()
        XCTAssertTrue(h.model.showLocation(CodeNavLocation(path: "b.go", line: 0, col: 1)))
        XCTAssertEqual(h.model.selectedPath, "apps/web/b.go")
        XCTAssertNil(h.model.focusRequest)
    }

    func testShowLocationOutsideTheDiffOpensThePreview() async throws {
        let h = try await navigationHarness()
        let place = CodeNavLocation(path: "lib/c.go", line: 12, col: 3)
        XCTAssertTrue(h.model.showLocation(place))
        XCTAssertEqual(h.model.preview, place)
        XCTAssertEqual(h.model.selectedPath, "apps/web/a.go", "the diff's file stays for Back to diff")
        XCTAssertEqual(h.model.currentLocation, place)
        h.model.previewCursorMoved(CodeNavLocation(path: "lib/c.go", line: 14, col: 1))
        XCTAssertEqual(h.model.currentLocation, CodeNavLocation(path: "lib/c.go", line: 14, col: 1))
        h.model.previewCursorMoved(CodeNavLocation(path: "other.go", line: 1, col: 1))
        XCTAssertEqual(h.model.currentLocation, CodeNavLocation(path: "lib/c.go", line: 14, col: 1),
                       "a cursor of another file is a stale message")

        let serial = h.model.previewSerial
        XCTAssertTrue(h.model.showLocation(place))
        XCTAssertNotEqual(h.model.previewSerial, serial, "the same place asked again is revealed again")
        XCTAssertEqual(h.model.currentLocation, place)

        h.model.closePreview()
        XCTAssertNil(h.model.preview)
        XCTAssertEqual(h.model.currentLocation?.path, "a.go")

        XCTAssertTrue(h.model.showLocation(place))
        await h.model.select("apps/web/b.go")
        XCTAssertNil(h.model.preview, "picking a file goes back to the diff")
    }

    func testShowLocationDeclinesBeforeThePathMapIsKnown() async throws {
        let h = try await navigationHarness()
        h.model.pathMap = nil
        XCTAssertFalse(h.model.showLocation(CodeNavLocation(path: "b.go", line: 5, col: 2)))
        XCTAssertNil(h.model.preview)
        XCTAssertEqual(h.model.selectedPath, "apps/web/a.go")
        XCTAssertNil(h.model.currentLocation)
    }

    /// A comment picked in the list: its line is asked for in the diff.
    func testFocusLineAsksForALineOfTheSelectedFile() async throws {
        let h = try await navigationHarness()
        h.model.focusLine(3)
        XCTAssertEqual(h.model.focusRequest?.path, "apps/web/a.go")
        XCTAssertEqual(h.model.focusRequest?.line, 3)
        XCTAssertEqual(h.model.currentLocation, CodeNavLocation(path: "a.go", line: 3, col: 1))
    }

    /// One-shot: a sent request, or one for a file left, is gone — a diff
    /// view rebuilt later (another file and back, a refresh) sends nothing.
    func testAFocusRequestIsNotKeptOnceSentOrLeft() async throws {
        let h = try await navigationHarness()
        h.model.focusLine(3)
        let sent = try XCTUnwrap(h.model.focusRequest)
        h.model.focusDelivered(sent.serial - 1)
        XCTAssertEqual(h.model.focusRequest, sent, "an older serial's delivery clears nothing")
        h.model.focusDelivered(sent.serial)
        XCTAssertNil(h.model.focusRequest)
        XCTAssertEqual(h.model.currentLocation, CodeNavLocation(path: "a.go", line: 3, col: 1), "the place is kept")

        h.model.focusLine(4)
        await h.model.select("apps/web/b.go")
        XCTAssertNil(h.model.focusRequest, "an unsent request for a file left is dropped")
        await h.model.select("apps/web/a.go")
        XCTAssertNil(h.model.focusRequest, "coming back does not ask again")

        XCTAssertTrue(h.model.showLocation(CodeNavLocation(path: "b.go", line: 6, col: 1)))
        XCTAssertEqual(h.model.focusRequest?.path, "apps/web/b.go", "a jump's own request survives its file switch")
        XCTAssertEqual(h.model.focusRequest?.line, 6)
    }
}

/// Go to definition and Usages from the diff's new side (board #960, spec
/// §2): the page names the shown file by its round path; the request goes
/// to the centres in the session's code root, root-relative.
extension ReviewChangesModelTests {
    private struct DiffNavigation {
        /// Held here: the centres keep it weakly.
        let vm: WorkbenchesViewModel
        let root: CodeRoot
        let landing: LandingDestination
        let navigation: CodeNavigationCenter
        let usages: CodeUsagesCenter
        let searches: StartedSearches
        let destination: ReviewNavigationDestination
        let page: MonacoDiffView.Coordinator
    }

    private func diffNavigation(_ h: ReviewModelHarness) throws -> DiffNavigation {
        let suite = "ReviewDiffNavigation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = CodeRoot(workbenchID: h.projectID, worktree: URL(fileURLWithPath: "/tmp/acme-wt"))
        let vm = WorkbenchesViewModel(dbPool: h.db, cli: nil, defaults: defaults)
        let landing = LandingDestination(root: root)
        vm.registerDestination(landing, workbenchID: h.projectID)
        let codeIndex = CodeIndexCenter(resolveExecutable: { nil }, rulesFile: CodeIndexCenter.testRulesFile)
        let symbol = CodeSymbol(name: "Store", kind: .struct, path: "lib/store.go", line: 4, col: 6, endLine: 9)
        codeIndex.index(for: root).applyIndexLines([.file(CodeIndexFileResult(file: symbol.path, lang: "go", symbols: [symbol]))], from: .update)
        let silent: @MainActor () -> Void = {}
        let navigation = CodeNavigationCenter(codeIndex: codeIndex, beep: silent)
        navigation.workbenches = vm
        let searches = StartedSearches()
        let usages = CodeUsagesCenter(defaults: defaults, startSearch: searches.start, beep: silent)
        usages.workbenches = vm
        let destination = ReviewNavigationDestination()
        destination.model = h.model
        destination.root = root
        destination.definitions = navigation
        destination.usages = usages
        let ignore: (String) -> Void = { _ in }
        let page = MonacoDiffView.Coordinator(onComment: { _, _, _ in }, onAsk: { _, _, _ in }, onUndo: ignore, onError: ignore)
        page.navigation = destination
        return DiffNavigation(vm: vm, root: root, landing: landing, navigation: navigation, usages: usages,
                              searches: searches, destination: destination, page: page)
    }

    private func definition(id: String, word: String = "Store", line: Int = 2, col: Int = 3) -> [String: Any] {
        ["type": "definition", "req": 1, "id": id, "word": word, "line": line, "col": col, "x": 0.0, "y": 0.0]
    }

    func testADiffDefinitionGoesToTheCentreInTheSessionRoot() async throws {
        let h = try await navigationHarness()
        let nav = try diffNavigation(h)
        await nav.page.definitionRequested(definition(id: "apps/web/a.go"))
        XCTAssertEqual(nav.landing.shown, [CodeNavLocation(path: "lib/store.go", line: 4, col: 6)])
        nav.navigation.goBack(root: nav.root)
        XCTAssertEqual(nav.landing.shown.last, CodeNavLocation(path: "a.go", line: 2, col: 3),
                       "the origin is the diff file's root-relative place")
    }

    /// The page posts from the new side of the file it shows only; a
    /// message naming another file (the old side's, a stale one) or a file
    /// outside the workbench folder goes nowhere.
    func testADiffDefinitionOfAnotherFileOrOutsideTheFolderIsIgnored() async throws {
        let h = try await navigationHarness()
        let nav = try diffNavigation(h)
        await nav.page.definitionRequested(definition(id: "apps/web/b.go"))
        h.model.pathMap = ReviewPathMap(repoPrefix: "apps/api")
        await nav.page.definitionRequested(definition(id: "apps/web/a.go"))
        XCTAssertEqual(nav.landing.shown, [])
        XCTAssertFalse(nav.navigation.canGoBack(root: nav.root))
    }

    func testDiffUsagesSearchTheSessionRootAndOpenInTheReview() async throws {
        let h = try await navigationHarness()
        let nav = try diffNavigation(h)
        nav.page.usagesRequested(["type": "usages", "id": "apps/web/a.go", "word": "Store", "line": 2, "col": 3])
        XCTAssertEqual(nav.searches.started.map(\.folder), [nav.root.folder])
        XCTAssertEqual(nav.searches.started.map(\.query), ["Store"])
        XCTAssertEqual(nav.usages.usages(for: nav.root)?.word, "Store")
        XCTAssertEqual(nav.landing.usagesListShown, 1, "the key review shows the list")
        XCTAssertFalse(nav.usages.isInspectorShown(workbenchID: h.projectID), "not the Files inspector")

        nav.page.usagesRequested(["type": "usages", "id": "apps/web/b.go", "word": "Other", "line": 1, "col": 1])
        XCTAssertEqual(nav.searches.started.count, 1, "a message about another file is stale")
    }

    func testTheReviewShowsTheUsagesListWhileItsFileAreaIsOnScreen() async throws {
        let h = try await navigationHarness()
        let nav = try diffNavigation(h)
        XCTAssertTrue(nav.destination.showUsagesList())
        XCTAssertTrue(h.model.showsUsages)
        h.model.closeUsages()
        XCTAssertFalse(h.model.showsUsages)
        nav.destination.model = nil
        XCTAssertFalse(nav.destination.showUsagesList(), "no review on screen: the Files inspector shows it")
    }
}

@MainActor
private final class LandingDestination: CodeLocationDestination {
    let root: CodeRoot?
    let isKeyDestination = true
    private(set) var shown: [CodeNavLocation] = []
    private(set) var usagesListShown = 0

    init(root: CodeRoot) { self.root = root }

    var currentLocation: CodeNavLocation? { shown.last }

    func show(_ location: CodeNavLocation, root: CodeRoot) -> Bool {
        shown.append(location)
        return true
    }

    func showUsagesList() -> Bool {
        usagesListShown += 1
        return true
    }
}

@MainActor
private final class StartedSearches {
    final class Handle: CodeSearchCancelling {
        func cancel() {}
    }

    private(set) var started: [(folder: URL, query: String)] = []

    func start(
        _ folder: URL,
        _ options: CodeSearchOptions,
        _ onMatch: @escaping @MainActor (CodeSearchMatch) -> Void,
        _ onDone: @escaping @MainActor (CodeSearchRun.Outcome) -> Void
    ) -> CodeSearchCancelling {
        started.append((folder, options.query))
        return Handle()
    }
}
