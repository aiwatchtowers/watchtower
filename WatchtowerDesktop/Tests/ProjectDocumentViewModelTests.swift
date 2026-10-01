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

    /// A failed write must report `false` so the composer keeps the owner's
    /// draft, and must surface the error instead of pretending it saved.
    func testAddCommentReportsAFailedWriteAndKeepsTheDraft() async throws {
        let vm = makeVM()
        var writes: [ProjectSubject] = []
        vm.onOwnerWrite = { writes.append($0) }
        await vm.load()
        try await pool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_comment_insert BEFORE INSERT ON project_comments
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        let wrote = await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        XCTAssertFalse(wrote, "a failed write must not tell the composer to clear")
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(writes.isEmpty, "the owner-write hook fires only after a committed write")
        XCTAssertTrue(vm.threads.isEmpty)
        XCTAssertEqual(vm.drafts.map(\.body), ["Why small?"], "a failed send keeps the draft")
    }

    // MARK: - Drafts (#84)

    private func commentCount() async throws -> Int? {
        try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments") }
    }

    func testDraftsWriteNothingUntilSentThenGoAsOneBatch() async throws {
        let store = ProjectCommentDrafts()
        let vm = ProjectDocumentViewModel(dbPool: pool, project: project, document: document, drafts: store,
                                          reloadDelay: .milliseconds(10))
        var writes: [ProjectSubject] = []
        vm.onOwnerWrite = { writes.append($0) }
        await vm.load()
        XCTAssertTrue(vm.addDraft(body: "Why small?", selection: try selection("retry budget small", in: vm)))
        XCTAssertTrue(vm.addDraft(body: "Which tests?", selection: try selection("migration tests", in: vm)))
        XCTAssertFalse(vm.addDraft(body: "  ", selection: try selection("Plan", in: vm)), "an empty body is no draft")
        let before = try await commentCount()
        XCTAssertEqual(before, 0, "the agent sees nothing before the send")
        XCTAssertEqual(vm.sendableDraftCount, 2)
        XCTAssertEqual(vm.drafts.map(\.body), ["Why small?", "Which tests?"], "in text order")
        XCTAssertEqual(vm.draftRanges.count, 2)
        XCTAssertTrue(writes.isEmpty)

        let sent = await vm.sendDrafts()
        XCTAssertEqual(sent, 2)
        let after = try await commentCount()
        XCTAssertEqual(after, 2)
        XCTAssertEqual(vm.openThreads.map(\.root.anchorQuote), ["retry budget small", "migration tests"])
        XCTAssertEqual(vm.anchoredRanges.count, 2, "the sent comments are highlighted as threads now")
        XCTAssertTrue(vm.drafts.isEmpty)
        XCTAssertTrue(store.byDocument.isEmpty)
        XCTAssertEqual(writes, [.document(document.id)], "one owner write for the whole batch")
    }

    /// Two clicks on Send while the first write runs write the batch once.
    func testOverlappingSendsWriteTheDraftsOnce() async throws {
        let vm = makeVM()
        await vm.load()
        vm.addDraft(body: "Why small?", selection: try selection("retry budget small", in: vm))
        vm.addDraft(body: "Which tests?", selection: try selection("migration tests", in: vm))
        async let first = vm.sendDrafts()
        async let second = vm.sendDrafts()
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.reduce(0, +), 2)
        let count = try await commentCount()
        XCTAssertEqual(count, 2)
        XCTAssertFalse(vm.isSending)
    }

    /// House rule: drafts survive navigation — the store outlives the
    /// document's view model, which a document switch recreates.
    func testDraftsSurviveReopeningTheDocument() async throws {
        let store = ProjectCommentDrafts()
        let first = ProjectDocumentViewModel(dbPool: pool, project: project, document: document, drafts: store)
        await first.load()
        first.addDraft(body: "Why small?", selection: try selection("retry budget small", in: first))
        first.updateDraft(try XCTUnwrap(first.drafts.first?.id), body: "Why so small?")

        let reopened = ProjectDocumentViewModel(dbPool: pool, project: project, document: document, drafts: store)
        await reopened.load()
        XCTAssertEqual(reopened.drafts.map(\.body), ["Why so small?"])
        XCTAssertEqual(reopened.draftRanges[try XCTUnwrap(reopened.drafts.first?.id)],
                       try selection("retry budget small", in: reopened))
    }

    func testADraftWhosePassageIsGoneIsKeptButNotSent() async throws {
        let vm = makeVM()
        await vm.load()
        vm.addDraft(body: "Why small?", selection: try selection("retry budget small", in: vm))
        vm.addDraft(body: "Which tests?", selection: try selection("migration tests", in: vm))
        try plan.replacingOccurrences(of: "retry budget small", with: "retry budget generous")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()

        XCTAssertEqual(vm.drafts.map(\.body), ["Which tests?", "Why small?"], "the lost draft sorts last")
        XCTAssertEqual(vm.sendableDraftCount, 1)
        XCTAssertEqual(vm.unsendableDraftCount, 1)
        let sent = await vm.sendDrafts()
        XCTAssertEqual(sent, 1)
        let after = try await commentCount()
        XCTAssertEqual(after, 1)
        XCTAssertEqual(vm.drafts.map(\.body), ["Why small?"], "kept for the owner to delete or redo")

        vm.deleteDraft(try XCTUnwrap(vm.drafts.first?.id))
        XCTAssertTrue(vm.drafts.isEmpty)
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

    /// An owner reply that reopened an `outdated` root must survive the next
    /// load: the quote is still gone, but the reply is unanswered, so the
    /// re-anchor leaves the root open for the agent. Once the agent answers,
    /// the next load marks it `outdated` as usual.
    func testLostThreadWithAnUnansweredOwnerReplyStaysOpen() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        try plan.replacingOccurrences(of: "Keep the retry budget small so a flaky service cannot stall the sync.", with: "Rewritten.")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        await vm.load()
        XCTAssertEqual(try status(root), "outdated")

        let replied = await vm.reply(to: root, body: "Still relevant — where did it go?")
        XCTAssertTrue(replied)
        XCTAssertEqual(try status(root), "open")
        await vm.load()
        XCTAssertEqual(try status(root), "open", "an unanswered owner reply keeps the lost root open")
        XCTAssertTrue(vm.outdatedThreads.isEmpty)
        let projectID = project.id
        let docs = try await pool.read { try ProjectQueries.documentListItems($0, projectID: projectID) }
        XCTAssertEqual(docs.first?.openComments, 1, "the Swift open counter includes it")

        let documentID = document.id
        try await pool.write { d in
            _ = try TestDatabase.insertProjectComment(
                d, projectID: projectID, body: "Moved to Task 2.", documentID: documentID, parentID: root
            )
        }
        await vm.load()
        XCTAssertEqual(try status(root), "outdated", "answered by the agent: the lost root goes outdated normally")
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

    /// The reply path follows the `addComment` rule: a failed write reports
    /// `false` and surfaces the error, so the thread keeps the owner's draft.
    func testReplyReportsAFailedWriteAndKeepsTheDraft() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        var writes = 0
        vm.onOwnerWrite = { _ in writes += 1 }
        try await pool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_comment_insert BEFORE INSERT ON project_comments
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        let replied = await vm.reply(to: root, body: "Also: which service?")
        XCTAssertFalse(replied, "a failed write must not tell the thread to clear its draft")
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(writes, 0, "the owner-write hook fires only after a committed write")
        XCTAssertEqual(vm.threads.first?.replies.count, 0)
        XCTAssertEqual(
            CommentThreadView.draftAfterReply(sent: "Also: which service?", current: "Also: which service?", saved: replied),
            "Also: which service?",
            "the thread view keeps the draft when the reply was not saved"
        )
    }

    func testReplyDraftClearsOnlyWhenSavedAndUnchanged() {
        XCTAssertEqual(CommentThreadView.draftAfterReply(sent: "hi", current: "hi", saved: true), "")
        XCTAssertEqual(CommentThreadView.draftAfterReply(sent: "hi", current: "hi", saved: false), "hi")
        XCTAssertEqual(
            CommentThreadView.draftAfterReply(sent: "hi", current: "hi, and more", saved: true), "hi, and more",
            "text typed while the write ran is never wiped"
        )
    }

    func testReplyResolveReopenWriteAndReportEachTime() async throws {
        let vm = makeVM()
        await vm.load()
        await vm.addComment(body: "Why small?", selection: try selection("retry budget small", in: vm))
        let root = try XCTUnwrap(vm.threads.first?.id)
        var writes = 0
        vm.onOwnerWrite = { _ in writes += 1 }

        let replied = await vm.reply(to: root, body: "Also: which service?")
        XCTAssertTrue(replied)
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

private extension ProjectDocumentViewModel {
    /// An owner comment the way the pane writes one: a draft, then the send.
    @discardableResult
    func addComment(body: String, selection: NSRange) async -> Bool {
        guard addDraft(body: body, selection: selection) else { return false }
        return await sendDrafts() != nil
    }
}
