import AppKit
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
        await vm.openFile("a.go", root: project.mainCodeRoot, preview: true)
        let buffer = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "a.go")
        buffer.loadIfNeeded()
        let page = PendingPage(edits: [CodeEditorPendingEdit(id: buffer.id, text: "package typed\n", base: 0)])
        vm.codeFiles.register(page, for: project.mainCodeRoot)

        await vm.openFile("b.go", root: project.mainCodeRoot, preview: true)

        XCTAssertEqual(vm.codeFiles.tabs(for: project.mainCodeRoot).paths, ["a.go", "b.go"])
        XCTAssertEqual(vm.codeFiles.tabs(for: project.mainCodeRoot).tabs.first?.isPreview, false)
        XCTAssertTrue(vm.codeFiles.existingBuffer(project.mainCodeRoot, "a.go") === buffer)
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files))
    }

    /// A workbench path clicked in an ask (#394) opens in Files beside the
    /// terminal, an expanded drawer stepping back so it shows; a path that
    /// is not a file of the folder opens nothing.
    func testAskMockupOpensAValidatedImageWithoutMakingATextTab() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 4, bitsPerPixel: 32))
        bitmap.setColor(.white, atX: 0, y: 0)
        let imageURL = folder.appendingPathComponent("mockup.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        try "not an image".write(to: folder.appendingPathComponent("broken.png"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside.png"),
                                                   withDestinationURL: folder.deletingLastPathComponent().appendingPathComponent("outside.png"))
        let folderPath = folder.path
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, folder: folderPath) }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.reload()
        var opened: [URL] = []
        vm.openAskImage = { opened.append($0); return true }
        vm.asks.drawerExpanded = true
        let valid = await vm.openAskLink(OpenQuicklyTarget(path: imageURL.path, line: 1, col: nil), projectID: id)
        XCTAssertTrue(valid)
        XCTAssertEqual(opened, [imageURL])
        XCTAssertFalse(vm.asks.drawerExpanded)
        let root = try XCTUnwrap(vm.summaries.first?.project).mainCodeRoot
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, [], "a mockup never becomes a binary text tab")
        for name in ["broken.png", "outside.png", "missing.png"] {
            let rejected = await vm.openAskLink(OpenQuicklyTarget(path: name, line: 1, col: nil), projectID: id)
            XCTAssertFalse(rejected, name)
        }
        XCTAssertEqual(opened, [imageURL], "only a decoded image inside the folder reaches the image app")
    }

    func testAnAskLinkOpensTheFileInFiles() async throws {
        let folderPath = folder.path
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, folder: folderPath) }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.reload()
        vm.asks.drawerExpanded = true

        let missing = await vm.openAskLink(OpenQuicklyTarget(path: "gone.go", line: 1, col: nil), projectID: id)
        XCTAssertFalse(missing)
        XCTAssertFalse(vm.layout(projectID: id).isShowing(.files))
        XCTAssertTrue(vm.asks.drawerExpanded, "nothing opened, nothing moved")

        let opened = await vm.openAskLink(OpenQuicklyTarget(path: "b.go", line: 1, col: nil), projectID: id)
        XCTAssertTrue(opened)
        XCTAssertTrue(vm.layout(projectID: id).isShowing(.files))
        XCTAssertEqual(vm.codeFiles.tabs(for: try XCTUnwrap(vm.summaries.first?.project).mainCodeRoot).paths, ["b.go"])
        XCTAssertFalse(vm.asks.drawerExpanded)

        let absolute = await vm.openAskLink(OpenQuicklyTarget(path: folder.appendingPathComponent("b.go").path,
                                                              line: 1, col: nil), projectID: id)
        XCTAssertTrue(absolute, "local document URLs resolve inside the workbench")
        let outside = await vm.openAskLink(OpenQuicklyTarget(path: folder.path + "-outside/b.go", line: 1, col: nil), projectID: id)
        XCTAssertFalse(outside, "a matching prefix without a folder boundary is outside")

        let dotted = await vm.openAskLink(OpenQuicklyTarget(path: "./b.go", line: 2, col: nil), projectID: id)
        XCTAssertTrue(dotted)
        XCTAssertEqual(vm.codeFiles.tabs(for: try XCTUnwrap(vm.summaries.first?.project).mainCodeRoot).paths, ["b.go"],
                       "the same file is the same tab, however the link spells it")
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
