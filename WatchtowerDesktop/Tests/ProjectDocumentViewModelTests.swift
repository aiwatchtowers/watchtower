import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ProjectDocumentViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var dbPath: String!
    private var folder: URL!
    private var fileURL: URL!
    private var project: Project!
    private var document: ProjectDocument!

    private let plan = """
    # Plan

    ## Task 1

    Keep the retry budget small so a flaky service cannot stall the sync.

    ## Task 2

    Write the migration tests.
    """

    override func setUpWithError() throws {
        (pool, dbPath) = try TestDatabase.createPool()
        // A folder name with a space and non-ASCII (index Review Focus #1).
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt project ü \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("docs/plan.md")
        try plan.write(to: fileURL, atomically: true, encoding: .utf8)
        let ids = try pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertProject(d, folder: folder.path)
            return (p, try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/plan.md", title: "Plan"))
        }
        project = try pool.read { try ProjectQueries.fetch($0, id: ids.0) }
        document = try pool.read { try ProjectQueries.document($0, id: ids.1) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeVM() -> ProjectDocumentViewModel {
        ProjectDocumentViewModel(dbPool: pool, project: project, document: document, reloadDelay: .milliseconds(10))
    }

    private func selection(_ needle: String, in vm: ProjectDocumentViewModel) throws -> NSRange {
        let text = try XCTUnwrap(vm.rendered?.text)
        return (text as NSString).range(of: needle)
    }

    private func status(_ id: Int64) throws -> String? {
        try pool.read { try String.fetchOne($0, sql: "SELECT status FROM project_comments WHERE id = ?", arguments: [id]) }
    }

    func testLoadRendersAnchorsThreadsAndMarksAgentRepliesRead() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        let (projectID, documentID) = (project.id, document.id)
        try await pool.write { d in
            _ = try TestDatabase.insertProjectComment(d, projectID: projectID, body: "Because…", documentID: documentID, parentID: root)
        }

        await vm.load()
        XCTAssertEqual(vm.threads.first?.replies.count, 1)
        XCTAssertEqual(vm.anchoredRanges[root], try selection("retry budget small", in: vm))
        let unread = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments WHERE author = 'agent' AND read_at = ''")
        }
        XCTAssertEqual(unread, 0)
    }

    func testAddCommentAnchorsTheSelectionOnRenderedTextAndReportsAnOwnerWrite() async throws {
        let vm = makeVM()
        var writes: [ProjectSubject] = []
        vm.onOwnerWrite = { writes.append($0) }
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))

        let documentID = document.id
        let comments = try await pool.read { try ProjectQueries.comments($0, documentID: documentID) }
        let row = try XCTUnwrap(comments.first)
        XCTAssertEqual(row.author, "owner")
        XCTAssertEqual(row.anchorQuote, "retry budget small")
        XCTAssertEqual(row.anchorHeading, "Task 1")
        XCTAssertTrue(row.anchorPrefix.hasSuffix("Keep the "))
        XCTAssertTrue(row.anchorSuffix.hasPrefix(" so a flaky"))
        XCTAssertEqual(writes, [.document(document.id)])
    }

    func testEmptySelectionOrBodyWritesNothing() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "x", selection: NSRange(location: 3, length: 0))
        await vm.addComment(body: "   ", selection: try selection("retry", in: vm))
        let count = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments") }
        XCTAssertEqual(count, 0)
    }

    /// A composer opened against an old render, then a reload swapped `rendered`
    /// out from under it (e.g. the file watcher fired) before the owner submitted:
    /// the stale selection must never be written, and the composer's text must
    /// survive so the owner can re-select and retry.
    func testAddCommentRefusesAStaleRenderVersionAndKeepsTheDraftRecoverable() async throws {
        let vm = makeVM()
        await vm.load()
        let staleVersion = vm.renderVersion
        let range = try selection("retry budget small", in: vm)

        try (plan + "\n\n## Task 3\n\nNew task.").write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()
        XCTAssertNotEqual(vm.renderVersion, staleVersion, "the reload must have bumped the version")

        let wrote = await vm.addComment(body: "Why small?", selection: range, renderVersion: staleVersion)
        XCTAssertFalse(wrote, "a stale version must refuse the write")
        XCTAssertNotNil(vm.errorMessage)
        let count = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments") }
        XCTAssertEqual(count, 0, "the owner's typed comment must not be persisted against the wrong text")
    }

    func testAddCommentWritesWhenTheCapturedVersionStillMatches() async throws {
        let vm = makeVM()
        await vm.load()
        let currentVersion = vm.renderVersion
        let range = try selection("retry budget small", in: vm)

        let wrote = await vm.addComment(body: "Why small?", selection: range, renderVersion: currentVersion)
        XCTAssertTrue(wrote)
        let count = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments") }
        XCTAssertEqual(count, 1)
    }

    func testLostOpenThreadIsMarkedOutdatedAndCountsAsAnOwnerWrite() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        var writes: [ProjectSubject] = []
        vm.onOwnerWrite = { writes.append($0) }

        try plan.replacingOccurrences(of: "Keep the retry budget small so a flaky service cannot stall the sync.", with: "Rewritten.")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()

        XCTAssertEqual(try status(root), "outdated")
        XCTAssertNil(vm.anchoredRanges[root])
        XCTAssertEqual(vm.outdatedThreads.map(\.id), [root])
        XCTAssertEqual(writes, [.document(document.id)], "the Desktop's own write — never reported as an agent answer")
    }

    func testReflowedParagraphKeepsTheThreadOpen() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        try plan.replacingOccurrences(of: "Keep the retry budget small", with: "Keep the retry\nbudget   small")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()
        XCTAssertEqual(try status(root), "open")
        XCTAssertNotNil(vm.anchoredRanges[root])
    }

    func testResolvedThreadWhoseQuoteIsLostStaysResolved() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        await vm.resolve(root)
        try "# Plan\n\nAll new.".write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()
        XCTAssertEqual(try status(root), "resolved")
        XCTAssertEqual(vm.resolvedThreads.map(\.id), [root])
    }

    func testMissingFileIsALoadErrorAndChangesNoStatus() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        try FileManager.default.removeItem(at: fileURL)
        await vm.load()
        XCTAssertNotNil(vm.loadError)
        XCTAssertNil(vm.rendered)
        XCTAssertEqual(try status(root), "open")
        XCTAssertEqual(vm.threads.map(\.id), [root])
    }

    func testReplyResolveReopenWriteAndReportEachTime() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        var writes = 0
        vm.onOwnerWrite = { _ in writes += 1 }

        await vm.reply(to: root, body: "Also: which service?")
        await vm.resolve(root)
        XCTAssertEqual(try status(root), "resolved")
        await vm.reopen(root)
        XCTAssertEqual(try status(root), "open")
        XCTAssertEqual(vm.threads.first?.replies.map(\.body), ["Also: which service?"])
        XCTAssertEqual(writes, 3)
    }

    func testThreadIDAtALocationInsideItsHighlight() async throws {
        let vm = makeVM()
        await vm.load()
        let range = try selection("retry budget small", in: vm)
        await vm.addComment(body: "Why small?", selection: range)
        let root = try XCTUnwrap(vm.threads.first?.id)
        XCTAssertEqual(vm.threadID(at: range.location + 2), root)
        XCTAssertNil(vm.threadID(at: 0))
    }

    func testFileChangeReloadsAfterTheDebounce() async throws {
        let vm = makeVM()
        await vm.load()
        try (plan + "\n\n## Task 3\n\nNew task.").write(to: fileURL, atomically: true, encoding: .utf8)
        vm.fileDidChange()
        vm.fileDidChange()   // a burst of events collapses into one reload
        await vm.pendingReload?.value
        XCTAssertTrue(vm.rendered?.text.contains("New task.") == true)
    }

    /// BEHAVIOR PROJ-03 — see docs/inventory/projects.md
    func testProj03DesktopNeverWritesTheDocument() async throws {
        let before = try Data(contentsOf: fileURL)
        let modified = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        let vm = makeVM()
        vm.startWatching()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        await vm.reply(to: root, body: "More")
        await vm.resolve(root)
        await vm.reopen(root)
        vm.stopWatching()
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date, modified)
    }
}
