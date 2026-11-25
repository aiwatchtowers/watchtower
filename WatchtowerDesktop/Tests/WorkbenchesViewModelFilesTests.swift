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

    private func vmWithProject() async throws -> (WorkbenchesViewModel, Workbench) {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        let folderPath = folder.path
        let id = try await pool.write { db in try TestDatabase.insertWorkbench(db, folder: folderPath) }
        await vm.reload()
        return (vm, try XCTUnwrap(vm.summaries.first { $0.id == id }?.project))
    }

    /// A path clicked in Workchat B of a split with Workchat A on another worktree (#2201 T2 review): the file opens
    /// in B's root, the Files pane takes A's place beside B, and the Files pane works in B's root — even with
    /// another FILES root chosen before.
    func testAWorkchatPathOpensBesideItsOwnSessionInASplit() async throws {
        let (vm, project) = try await vmWithProject()
        let rootA = CodeRoot(workbenchID: project.id, worktree: folder.appendingPathComponent("wt-a"))
        let rootB = CodeRoot(workbenchID: project.id, worktree: folder.appendingPathComponent("wt-b"))
        var split = WorkspaceLayout.default
        split.primary = .sessionChat(1)
        split.secondary = .sessionChat(2)
        vm.setLayout(split, projectID: project.id)
        vm.selectFilesRoot(rootA, project: project)

        await vm.openSessionFile("a.go", root: rootB, pane: .sessionChat(2))

        let layout = vm.layout(projectID: project.id)
        XCTAssertEqual(Set(layout.visiblePanes), [.files, .sessionChat(2)], "B stays, Files takes A's place")
        XCTAssertEqual(vm.pageSessionID(projectID: project.id), 2)
        XCTAssertEqual(vm.activeCodeRoot(project: project), rootB, "the Files pane works in B's root")
        XCTAssertEqual(vm.codeFiles.tabs(for: rootB).paths, ["a.go"])
        XCTAssertEqual(vm.codeFiles.tabs(for: project.mainCodeRoot).paths, [])
    }

    /// A session's report beside its Workchat: the click keeps the chat it came from and replaces the report.
    func testAWorkchatPathKeepsTheChatItWasClickedIn() async throws {
        let (vm, project) = try await vmWithProject()
        var split = WorkspaceLayout.default
        split.primary = .sessionReport(2)
        split.secondary = .sessionChat(2)
        vm.setLayout(split, projectID: project.id)
        await vm.openSessionFile("a.go", root: project.mainCodeRoot, pane: .sessionChat(2))
        XCTAssertEqual(Set(vm.layout(projectID: project.id).visiblePanes), [.files, .sessionChat(2)])
    }

    /// A single Workchat opens Files the way a FILES click does.
    func testAWorkchatPathInASinglePaneShowsFiles() async throws {
        let (vm, project) = try await vmWithProject()
        var single = WorkspaceLayout.default
        single.primary = .sessionChat(2)
        vm.setLayout(single, projectID: project.id)
        await vm.openSessionFile("a.go", root: project.mainCodeRoot, pane: .sessionChat(2))
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files))
        XCTAssertEqual(vm.codeFiles.tabs(for: project.mainCodeRoot).paths, ["a.go"])
    }

    /// A click whose Workchat is no longer on screen (another session took the page meanwhile) opens nothing and
    /// leaves the layout alone (review round 3).
    func testAWorkchatPathWhoseChatIsOffScreenOpensNothing() async throws {
        let (vm, project) = try await vmWithProject()
        var single = WorkspaceLayout.default
        single.primary = .sessionChat(3)
        vm.setLayout(single, projectID: project.id)
        let opened = await vm.openSessionFile("a.go", root: project.mainCodeRoot, pane: .sessionChat(2))
        XCTAssertFalse(opened, "given up: the view beeps")
        XCTAssertEqual(vm.layout(projectID: project.id), single)
        XCTAssertEqual(vm.codeFiles.tabs(for: project.mainCodeRoot).paths, [])
    }

    /// Branch review's Author chat lives in the `.changes` pane (round 4): a path clicked there opens Files beside
    /// the review in a split, and in its place on a single pane — never nothing.
    func testAPathClickedInTheReviewsAuthorChatOpensBesideTheReview() async throws {
        let (vm, project) = try await vmWithProject()
        let chat = ReviewAgentChat(vm: vm, projectID: project.id, sessionID: 2)
        XCTAssertEqual(chat.pane, .changes(2))
        var split = WorkspaceLayout.default
        split.primary = .changes(2)
        split.secondary = .sessionChat(3)
        vm.setLayout(split, projectID: project.id)
        let opened = await vm.openSessionFile("a.go", root: project.mainCodeRoot, pane: chat.pane)
        XCTAssertTrue(opened)
        XCTAssertEqual(Set(vm.layout(projectID: project.id).visiblePanes), [.files, .changes(2)])
        XCTAssertEqual(vm.codeFiles.tabs(for: project.mainCodeRoot).paths, ["a.go"])

        var single = WorkspaceLayout.default
        single.primary = .changes(2)
        vm.setLayout(single, projectID: project.id)
        let again = await vm.openSessionFile("b.go", root: project.mainCodeRoot, pane: chat.pane)
        XCTAssertTrue(again)
        XCTAssertTrue(vm.layout(projectID: project.id).isShowing(.files))
    }

    /// The click's lookup may suspend while the owner types into the preview tab (final review F1): the lookup runs
    /// before the unsent edits are pulled, so an edit typed during it reaches its buffer and keeps the preview tab
    /// the open would otherwise replace.
    func testAnEditTypedDuringTheClickLookupIsPulledBeforeTheOpen() async throws {
        let (vm, project) = try await vmWithProject()
        var single = WorkspaceLayout.default
        single.primary = .sessionChat(2)
        vm.setLayout(single, projectID: project.id)
        let root = project.mainCodeRoot
        vm.codeFiles.open("b.go", root: root, preview: true)
        let buffer = vm.codeFiles.buffer(for: root, relPath: "b.go")
        buffer.loadIfNeeded()
        let page = PendingPage(edits: [])
        vm.codeFiles.register(page, for: root)
        // Labelled: a trailing closure would bind to `stillCurrent`, the last closure parameter.
        // swiftlint:disable:next trailing_closure
        let opened = await vm.openSessionFile("a.go", root: root, pane: .sessionChat(2), stillValid: {
            page.edits = [CodeEditorPendingEdit(id: buffer.id, text: "package typed\n", base: 0)]
            return true
        })
        XCTAssertTrue(opened)
        XCTAssertTrue(page.edits.isEmpty, "the edit typed during the lookup was pulled")
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, ["b.go", "a.go"], "the edited preview tab is kept")
        XCTAssertTrue(vm.codeFiles.existingBuffer(root, "b.go") === buffer)
        XCTAssertEqual(buffer.text, "package typed\n")
    }

    /// After the pull only synchronous checks run (final review F1): a click whose index moved during the pull, or
    /// whose chat left the screen, opens nothing — and its edit is still pulled.
    func testAPathClickIsCheckedSynchronouslyAfterThePull() async throws {
        let (vm, project) = try await vmWithProject()
        var single = WorkspaceLayout.default
        single.primary = .sessionChat(2)
        vm.setLayout(single, projectID: project.id)
        let root = project.mainCodeRoot
        let buffer = vm.codeFiles.buffer(for: root, relPath: "b.go")
        buffer.loadIfNeeded()
        let page = PendingPage(edits: [CodeEditorPendingEdit(id: buffer.id, text: "package typed\n", base: 0)])
        vm.codeFiles.register(page, for: root)
        var order: [String] = []
        let opened = await vm.openSessionFile("a.go", root: root, pane: .sessionChat(2), stillValid: {
            order.append(page.edits.isEmpty ? "lookup after pull" : "lookup before pull")
            return true
        }, stillCurrent: {
            order.append(page.edits.isEmpty ? "current after pull" : "current before pull")
            return false
        })
        XCTAssertFalse(opened)
        XCTAssertEqual(order, ["lookup before pull", "current after pull"])
        XCTAssertEqual(vm.codeFiles.tabs(for: root).paths, [])
        XCTAssertEqual(vm.layout(projectID: project.id), single)
    }

    /// A bench folder removed from its bench stops being watched once the folders are read again (review round 3).
    func testAFolderOffTheBenchIsRetiredByTheFoldersRead() async throws {
        let (vm, project) = try await vmWithProject()
        let hubFolder = folder.appendingPathComponent("hub")
        try FileManager.default.createDirectory(at: hubFolder, withIntermediateDirectories: true)
        let home = WorkbenchFolder(id: 3, workbenchID: project.id, folderPath: folder.path, position: 0, name: "acme")
        let hub = WorkbenchFolder(id: 5, workbenchID: project.id, folderPath: hubFolder.path, position: 1, name: "hub")
        let hubRoot = CodeRoot(folder: hub, homeFolderID: 3)
        vm.codeFiles.startWatching(hubRoot)
        vm.codeFiles.stopShowing(hubRoot)
        vm.applyBenchFolders([project.id: BenchFolders(folders: [home, hub], homeID: 3)])
        XCTAssertTrue(vm.codeFiles.isWatching(hubRoot))
        let removed = WorkbenchFolder(id: 5, workbenchID: project.id, folderPath: hubFolder.path, position: 1,
                                      removedAt: "2026-11-24T00:00:00Z", name: "hub")
        vm.applyBenchFolders([project.id: BenchFolders(folders: [home, removed], homeID: 3)])
        XCTAssertFalse(vm.codeFiles.isWatching(hubRoot))
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
