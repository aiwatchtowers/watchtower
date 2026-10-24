import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// A Branch review pane stands in for the Files pane as the place a jump
/// lands while it is the key pane (board #960, spec §2 "Where results
/// land"); otherwise jumps open the Files pane as before (Review Focus 4).
@MainActor
final class WorkbenchesViewModelNavigationTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var project: Workbench!
    private var root: CodeRoot { project.mainCodeRoot }

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        suite = "WorkbenchesViewModelNavigationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vmnav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "package x\n".write(to: folder.appendingPathComponent("a.go"), atomically: true, encoding: .utf8)
        project = Workbench(row: Row(["id": 4, "name": "acme", "folder_path": folder.path]))
    }

    override func tearDownWithError() throws {
        pool = nil
        TestDatabase.cleanup(path: path)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeVM() -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
    }

    private let target = CodeNavLocation(path: "a.go", line: 3, col: 2)

    func testWithNoDestinationAJumpOpensTheFilesPane() {
        let vm = makeVM()
        vm.showLocation(target, root: root, keepingTab: true)
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, ["a.go"])
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files))
    }

    func testADestinationThatIsNotKeyLeavesTheJumpToFiles() {
        let vm = makeVM()
        let destination = FakeDestination(root: root, isKey: false)
        vm.registerDestination(destination, workbenchID: project.id)
        vm.showLocation(target, root: root, keepingTab: true)
        XCTAssertEqual(destination.shown, [])
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, ["a.go"])
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files))
    }

    func testTheKeyDestinationTakesTheJumpAndFilesIsUntouched() {
        let vm = makeVM()
        let destination = FakeDestination(root: root, isKey: true)
        vm.registerDestination(destination, workbenchID: project.id)
        vm.showLocation(target, root: root, keepingTab: true)
        XCTAssertEqual(destination.shown, [target])
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, [])
        XCTAssertFalse(vm.layout(projectID: project.id).isShowing(.files))
    }

    func testAKeyDestinationThatDeclinesFallsBackToFiles() {
        let vm = makeVM()
        let destination = FakeDestination(root: root, isKey: true, accepts: false)
        vm.registerDestination(destination, workbenchID: project.id)
        vm.showLocation(target, root: root, keepingTab: true)
        XCTAssertEqual(destination.shown, [target])
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, ["a.go"])
    }

    func testAKeyDestinationOfAnotherRootIsNotAsked() {
        let vm = makeVM()
        let worktree = CodeRoot(workbenchID: project.id, worktree: folder.appendingPathComponent("wt"))
        let destination = FakeDestination(root: worktree, isKey: true)
        vm.registerDestination(destination, workbenchID: project.id)
        vm.showLocation(target, root: root, keepingTab: true)
        XCTAssertEqual(destination.shown, [])
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, ["a.go"])
    }

    func testAnUnregisteredDestinationIsNoLongerAsked() {
        let vm = makeVM()
        let destination = FakeDestination(root: root, isKey: true)
        vm.registerDestination(destination, workbenchID: project.id)
        vm.unregisterDestination(destination, workbenchID: project.id)
        vm.showLocation(target, root: root, keepingTab: true)
        XCTAssertEqual(destination.shown, [])
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, ["a.go"])
    }

    /// Open Quickly and a Usages row: a target without a line is line 0.
    func testOpenFileGoesToTheKeyDestination() async {
        let vm = makeVM()
        let destination = FakeDestination(root: root, isKey: true)
        vm.registerDestination(destination, workbenchID: project.id)
        await vm.openFile(at: OpenQuicklyTarget(path: "a.go", line: nil, col: nil), root: root, beside: false)
        await vm.openFile(at: OpenQuicklyTarget(path: "a.go", line: 7, col: 4), root: root, beside: true)
        XCTAssertEqual(destination.shown, [CodeNavLocation(path: "a.go", line: 0, col: 1), CodeNavLocation(path: "a.go", line: 7, col: 4)])
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, [])
        XCTAssertFalse(vm.layout(projectID: project.id).isShowing(.files))
    }

    /// Back/Forward's origin is the key destination's place, not the Files
    /// pane's cursor.
    func testTheHistoryRecordsTheKeyDestinationsLocation() {
        let vm = makeVM()
        let codeIndex = CodeIndexCenter(resolveExecutable: { nil }, rulesFile: CodeIndexCenter.testRulesFile)
        let silent: @MainActor () -> Void = {}
        let center = CodeNavigationCenter(codeIndex: codeIndex, beep: silent)
        center.workbenches = vm
        let destination = FakeDestination(root: root, isKey: true)
        destination.current = CodeNavLocation(path: "a.go", line: 9, col: 1)
        vm.registerDestination(destination, workbenchID: project.id)

        center.recordJumpFromCurrentLocation(root: root)
        XCTAssertTrue(center.canGoBack(root: root))
        destination.current = CodeNavLocation(path: "b.go", line: 20, col: 1)
        center.goBack(root: root)
        XCTAssertEqual(destination.shown.last, CodeNavLocation(path: "a.go", line: 9, col: 1))
        XCTAssertTrue(center.canGoForward(root: root), "the place Back left from is the destination's")
        center.goForward(root: root)
        XCTAssertEqual(destination.shown.last, CodeNavLocation(path: "b.go", line: 20, col: 1))
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, [])
    }
}

@MainActor
private final class FakeDestination: CodeLocationDestination {
    let root: CodeRoot?
    var isKeyDestination: Bool
    let accepts: Bool
    var current: CodeNavLocation?
    private(set) var shown: [CodeNavLocation] = []

    init(root: CodeRoot, isKey: Bool, accepts: Bool = true) {
        self.root = root
        isKeyDestination = isKey
        self.accepts = accepts
    }

    var currentLocation: CodeNavLocation? { current }

    func show(_ location: CodeNavLocation, root: CodeRoot) -> Bool {
        shown.append(location)
        if accepts { current = location }
        return accepts
    }
}
