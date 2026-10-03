import AppKit
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// The jump bar's menus (spec §8.4): built from the Core content, the
/// current entry checked, picks reported; the file's symbol list (the last
/// segment, ⌃6) under a filter field that hides what does not match and
/// opens the first match on Return; ⌃6 through the Navigate menu reaching
/// the jump bar on screen.
@MainActor
final class JumpBarMenuTests: XCTestCase {
    private var pool: DatabasePool!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var suite: String!
    private var project: Workbench!
    private var codeIndex: CodeIndexCenter!
    private var navigation: CodeNavigationCenter!
    private var beeps = 0

    private let path = "src/store.swift"
    private lazy var store = CodeSymbol(name: "Store", kind: .class, path: path, line: 1, col: 7, endLine: 30)
    private lazy var save = CodeSymbol(name: "save", kind: .method, path: path, line: 3, col: 10, endLine: 9, container: "Store",
                                       signature: "func save()")
    private lazy var load = CodeSymbol(name: "load", kind: .method, path: path, line: 12, col: 10, endLine: 15, container: "Store")
    private lazy var mark = CodeSymbol(name: "Helpers", kind: .module, path: path, line: 32, col: 1, endLine: 32, outline: true)
    private lazy var symbols = [store, save, load, mark]

    override func setUpWithError() throws {
        (pool, dbPath) = try TestDatabase.createPool()
        suite = "JumpBarMenuTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        project = Workbench(row: Row(["id": 4, "name": "acme", "folder_path": "/tmp/acme-jump-bar"]))
        beeps = 0
    }

    override func tearDownWithError() throws {
        pool = nil
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: suite)
    }

    private func picks() -> (record: (JumpBarPick) -> Void, read: () -> [JumpBarPick]) {
        final class Box { var picks: [JumpBarPick] = [] }
        let box = Box()
        return ({ box.picks.append($0) }, { box.picks })
    }

    private func fileSymbolsMenu(onPick: @escaping (JumpBarPick) -> Void = { _ in }) -> JumpBarMenu {
        JumpBarMenu(
            content: .fileSymbols(JumpBarSymbolRow.rows(for: symbols)), files: [path],
            currentFile: path, currentSymbol: save, scheme: .light, onPick: onPick
        )
    }

    private func symbolTitles(_ menu: JumpBarMenu, visibleOnly: Bool = false) -> [String] {
        menu.menu.items.filter { $0.action != nil && (!visibleOnly || !$0.isHidden) }.map(\.title)
    }

    /// What a click on the item does (no app to route `performActionForItem` in tests).
    private func trigger(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target as? NSObject else { return XCTFail("\(item.title) has no action") }
        _ = target.perform(action, with: item)
    }

    // MARK: Menus

    func testTheFileSymbolListHasAFilterFieldThenEverySymbolIndented() throws {
        let menu = fileSymbolsMenu()
        let field = try XCTUnwrap(menu.filterField)
        XCTAssertTrue(menu.menu.items.first?.view?.subviews.contains(field) == true, "the filter is the first row")
        XCTAssertEqual(symbolTitles(menu), ["Store", "save", "load", "Helpers"], "outline entries listed too")
        let rows = menu.menu.items.filter { $0.action != nil }
        XCTAssertEqual(rows.map(\.indentationLevel), [0, 1, 1, 0])
        XCTAssertEqual(rows.map(\.state), [.off, .on, .off, .off], "the symbol at the cursor is checked")
        XCTAssertNotNil(rows.first?.image, "a kind badge")
        XCTAssertEqual(rows[1].toolTip, "func save()")
    }

    func testTheFilterHidesWhatDoesNotMatchAndReturnOpensTheFirstMatch() throws {
        let (record, read) = picks()
        let menu = fileSymbolsMenu(onPick: record)
        menu.applyFilter("LO")
        XCTAssertEqual(symbolTitles(menu, visibleOnly: true), ["load"])
        menu.applyFilter("s")
        XCTAssertEqual(symbolTitles(menu, visibleOnly: true), ["Store", "save", "Helpers"])
        menu.applyFilter("")
        XCTAssertEqual(symbolTitles(menu, visibleOnly: true).count, 4)

        let field = try XCTUnwrap(menu.filterField)
        field.stringValue = "loa"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(symbolTitles(menu, visibleOnly: true), ["load"])
        let action = try XCTUnwrap(field.action)
        _ = menu.perform(action, with: field)
        XCTAssertEqual(read(), [.symbol(load)])
    }

    func testAMembersMenuPicksTheSymbol() {
        let (record, read) = picks()
        let menu = JumpBarMenu(content: .members([save, load]), files: [], currentFile: path, currentSymbol: load, scheme: .dark, onPick: record)
        XCTAssertNil(menu.filterField, "only the last segment filters")
        XCTAssertEqual(symbolTitles(menu), ["save", "load"])
        XCTAssertEqual(menu.menu.items.map(\.state), [.off, .on])
        trigger(menu.menu.items[0])
        XCTAssertEqual(read(), [.symbol(save)])
    }

    func testAFolderMenuListsSubfoldersFilledWhenOpenedAndFiles() throws {
        let files = ["src/store.swift", "src/app.swift", "src/views/list.swift", "src/views/deep/row.swift"]
        let (record, read) = picks()
        let menu = JumpBarMenu(
            content: .folder(JumpBarFolderListing(folder: "src", files: files)), files: files,
            currentFile: path, currentSymbol: nil, scheme: .light, onPick: record
        )
        XCTAssertEqual(menu.menu.items.map(\.title), ["views", "app.swift", "store.swift"])
        XCTAssertEqual(menu.menu.items.map(\.state), [.off, .off, .on], "the file on screen is checked")
        let submenu = try XCTUnwrap(menu.menu.items.first?.submenu)
        XCTAssertTrue(submenu.items.isEmpty, "filled when it opens")
        menu.menuNeedsUpdate(submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["deep", "list.swift"])
        menu.menuNeedsUpdate(submenu)
        XCTAssertEqual(submenu.items.count, 2, "filled once")
        trigger(submenu.items[1])
        XCTAssertEqual(read(), [.file("src/views/list.swift")])
    }

    func testAnEmptyFolderSaysSo() {
        let menu = JumpBarMenu(content: .folder(JumpBarFolderListing(folder: "x", files: [])), files: [],
                               currentFile: path, currentSymbol: nil, scheme: .light) { _ in }
        XCTAssertEqual(menu.menu.items.map(\.title), ["No Files"])
        XCTAssertEqual(menu.menu.items.first?.isEnabled, false)
    }

    // MARK: Controller and ⌃6

    private func makeController() -> (JumpBarController, WorkbenchesViewModel, () -> [(JumpBarMenu, NSView)]) {
        codeIndex = CodeIndexCenter { nil }
        let beep: @MainActor () -> Void = { [weak self] in self?.beeps += 1 }
        navigation = CodeNavigationCenter(codeIndex: codeIndex, beep: beep)
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        navigation.workbenches = vm
        vm.codeFiles.codeIndex = codeIndex
        vm.codeFiles.navigation = navigation
        codeIndex.index(for: project.id).applyIndexLines(
            [.file(CodeIndexFileResult(file: path, lang: "swift", symbols: symbols)),
             .file(CodeIndexFileResult(file: "src/app.swift", lang: "swift", symbols: []))],
            from: .update
        )
        final class Shown { var menus: [(JumpBarMenu, NSView)] = [] }
        let shown = Shown()
        let controller = JumpBarController(files: vm.codeFiles, project: project) { shown.menus.append(($0, $1)) }
        return (controller, vm, { shown.menus })
    }

    func testTheSnapshotFollowsTheCursorInTheFileOnScreen() {
        let (controller, vm, _) = makeController()
        XCTAssertNil(controller.snapshot(), "no tab open")
        vm.codeFiles.open(path, project: project, preview: false)
        XCTAssertEqual(controller.snapshot()?.model.segments.last, .file(path: path), "no cursor reported yet")
        vm.codeFiles.cursorMoved(CodeNavLocation(path: path, line: 13, col: 2), workbenchID: project.id)
        XCTAssertEqual(controller.snapshot()?.model.segments.suffix(2), [.symbol(store), .symbol(load)])
        XCTAssertEqual(controller.snapshot()?.model.segments.first, .folder(name: "acme-jump-bar", path: ""))
        vm.codeFiles.cursorMoved(CodeNavLocation(path: "src/app.swift", line: 13, col: 2), workbenchID: project.id)
        XCTAssertEqual(controller.snapshot()?.model.segments.last, .file(path: path), "a cursor in another file does not count")
    }

    func testControlSixShowsTheLastSegmentsMenuWithTheFilter() throws {
        let (controller, vm, shown) = makeController()
        navigation.registerJumpBar(controller, for: project.id)
        vm.codeFiles.open(path, project: project, preview: false)
        vm.codeFiles.cursorMoved(CodeNavLocation(path: path, line: 4, col: 2), workbenchID: project.id)
        let segments = try XCTUnwrap(controller.snapshot()?.model.segments)
        let anchors = segments.indices.map { _ in NSView() }
        anchors.enumerated().forEach { controller.setAnchor($1, segment: $0) }

        navigation.showFileSymbols(project: project)
        XCTAssertEqual(beeps, 0)
        let (menu, anchor) = try XCTUnwrap(shown().first)
        XCTAssertTrue(anchor === anchors.last, "dropped from the last segment")
        XCTAssertNotNil(menu.filterField)
        XCTAssertEqual(menu.menu.items.filter { $0.state == .on }.map(\.title), ["save"])

        // A pick goes through the navigation center: on Back, opened at the line.
        trigger(try XCTUnwrap(menu.menu.items.first { $0.title == "load" }))
        XCTAssertEqual(vm.codeFiles.reveals[project.id]?.line, 12)
        XCTAssertTrue(navigation.canGoBack(workbenchID: project.id))
    }

    func testControlSixBeepsWithoutSymbols() {
        let (controller, vm, shown) = makeController()
        navigation.registerJumpBar(controller, for: project.id)
        vm.codeFiles.open("src/app.swift", project: project, preview: false)
        controller.setAnchor(NSView(), segment: 2)
        navigation.showFileSymbols(project: project)
        XCTAssertEqual(beeps, 1)
        XCTAssertTrue(shown().isEmpty)
    }

    func testAMiddleSegmentShowsItsNeighbours() throws {
        let (controller, vm, shown) = makeController()
        vm.codeFiles.open(path, project: project, preview: false)
        vm.codeFiles.cursorMoved(CodeNavLocation(path: path, line: 4, col: 2), workbenchID: project.id)
        let anchor = NSView()
        controller.setAnchor(anchor, segment: 1)
        controller.showMenu(segment: 1)
        let menu = try XCTUnwrap(shown().first?.0)
        XCTAssertEqual(menu.menu.items.map(\.title), ["app.swift", "store.swift"], "the src folder")
    }
}
