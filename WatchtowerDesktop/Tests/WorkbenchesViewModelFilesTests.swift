import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// The FILES tree's open: the Files pane goes on screen, and an edit the
/// page has not sent yet keeps its preview tab instead of being replaced.
@MainActor
final class WorkbenchesViewModelFilesTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        suite = "WorkbenchesViewModelFilesTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vmfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.go", "b.go"] {
            try "package x\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        pool = nil
        TestDatabase.cleanup(path: path)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    func testOpenPullsTheUnsentEditSoThePreviewTabIsKept() async {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        let project = Workbench(row: Row(["id": 3, "name": "acme", "folder_path": folder.path]))
        await vm.openFile("a.go", project: project, preview: true)
        let buffer = vm.codeFiles.buffer(for: project, relPath: "a.go")
        buffer.loadIfNeeded()
        let page = PendingPage(edits: [CodeEditorPendingEdit(id: buffer.id, text: "package typed\n", base: 0)])
        vm.codeFiles.register(page, for: project)

        await vm.openFile("b.go", project: project, preview: true)

        XCTAssertEqual(vm.codeFiles.tabs(for: project).paths, ["a.go", "b.go"])
        XCTAssertEqual(vm.codeFiles.tabs(for: project).tabs.first?.isPreview, false)
        XCTAssertTrue(vm.codeFiles.existingBuffer(project, "a.go") === buffer)
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files))
    }
}

@MainActor
private final class PendingPage: CodeEditorBridge {
    var edits: [CodeEditorPendingEdit]

    init(edits: [CodeEditorPendingEdit]) {
        self.edits = edits
    }

    func takePending() async -> [CodeEditorPendingEdit]? {
        defer { edits = [] }
        return edits
    }
}
