import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    func testFetchAllSortsByNameAndFetchReadsOne() throws {
        try db.write { d in
            let beta = try TestDatabase.insertProject(d, name: "beta", folder: "/tmp/beta")
            _ = try TestDatabase.insertProject(d, name: "Alpha", folder: "/tmp/alpha")
            XCTAssertEqual(try ProjectQueries.fetchAll(d).map(\.name), ["Alpha", "beta"])
            let fetched = try XCTUnwrap(ProjectQueries.fetch(d, id: beta))
            XCTAssertEqual(fetched.folderPath, "/tmp/beta")
            XCTAssertEqual(fetched.folderURL.path, "/tmp/beta")
            XCTAssertNil(try ProjectQueries.fetch(d, id: 999))
        }
    }

    func testDocumentsNewestFirstAndDisplayTitleFallsBackToFileName() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/a.md", updatedAt: "2026-09-29T09:00:00Z")
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/b.md", title: "Plan B", updatedAt: "2026-09-29T11:00:00Z")
            let docs = try ProjectQueries.documents(d, projectID: p)
            XCTAssertEqual(docs.map(\.displayTitle), ["Plan B", "a.md"])
            let project = try XCTUnwrap(ProjectQueries.fetch(d, id: p))
            XCTAssertEqual(docs[1].fileURL(in: project).path, "/tmp/acme/docs/a.md")
        }
    }

    func testImagesAreTheTargetsOwnOldestFirst() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let target = try TestDatabase.insertProjectTarget(d, projectID: p)
            let other = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Other")
            try TestDatabase.insertProjectTargetImage(d, projectID: p, targetID: target, fileName: "first.png", sha256: "a")
            try TestDatabase.insertProjectTargetImage(d, projectID: p, targetID: target, fileName: "second.png", sha256: "b")
            try TestDatabase.insertProjectTargetImage(d, projectID: p, targetID: other, sha256: "c")
            let images = try ProjectQueries.images(d, targetID: target)
            XCTAssertEqual(images.map(\.fileName), ["first.png", "second.png"])
            XCTAssertEqual(images[0].fileURL.path, "/tmp/project_files/1/abc.png")
            try d.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [target])
            XCTAssertEqual(try ProjectQueries.images(d, targetID: target), [], "the rows go with their target")
        }
    }

    func testOwnerCommentCarriesTheAnchorAndReplyInheritsTheRootSubject() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let anchor = CommentAnchor(quote: "retry", prefix: "before ", suffix: " after", heading: "Errors")
            let root = try ProjectQueries.addOwnerComment(
                d, projectID: p, targetID: nil, documentID: doc, anchor: anchor, body: "  Why 3?  "
            )
            let reply = try ProjectQueries.reply(d, to: root, body: "Follow-up")
            let thread = try ProjectQueries.comments(d, documentID: doc)
            XCTAssertEqual(thread.map(\.id), [root, reply])
            XCTAssertEqual(thread[0].body, "Why 3?")
            XCTAssertEqual(thread[0].author, "owner")
            XCTAssertEqual(thread[0].anchor, anchor)
            XCTAssertEqual(thread[1].parentID, root)
            XCTAssertEqual(thread[1].documentID, doc)
            XCTAssertEqual(thread[1].author, "owner")
        }
    }

    /// An owner reply under a resolved or outdated root reopens it (Go twin:
    /// `AddProjectCommentTx`), so the thread counts as open again — the same
    /// open-root rule the agent's new-for-agent channel reads.
    func testOwnerReplyReopensAResolvedOrOutdatedThread() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Feature")
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let resolved = try TestDatabase.insertProjectComment(
                d, projectID: p, author: "owner", targetID: t, status: "resolved"
            )
            let agentReply = try TestDatabase.insertProjectComment(
                d, projectID: p, body: "Done.", targetID: t, parentID: resolved, readAt: "2026-09-30T09:00:00Z"
            )
            let outdated = try TestDatabase.insertProjectComment(
                d, projectID: p, author: "owner", documentID: doc, status: "outdated", quote: "gone"
            )
            let untouched = try TestDatabase.insertProjectComment(
                d, projectID: p, author: "owner", targetID: t, status: "resolved"
            )
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t, parentID: untouched)

            _ = try ProjectQueries.reply(d, to: resolved, body: "One more thing")
            _ = try ProjectQueries.reply(d, to: outdated, body: "Still relevant")

            func row(_ id: Int64) throws -> ProjectComment {
                try XCTUnwrap(ProjectComment.fetchOne(d, sql: "SELECT * FROM project_comments WHERE id = ?", arguments: [id]))
            }
            XCTAssertEqual(try row(resolved).status, "open")
            XCTAssertEqual(try row(outdated).status, "open")
            XCTAssertEqual(try row(untouched).status, "resolved", "a thread nobody replied to keeps its status")
            let agent = try row(agentReply)
            XCTAssertEqual(agent.author, "agent")
            XCTAssertEqual(agent.readAt, "2026-09-30T09:00:00Z", "the agent's rows are not rewritten")
            let board = try ProjectQueries.board(d, projectID: p)
            XCTAssertEqual(board.first?.openComments, 1, "the reopened target thread counts as open again")
            let docs = try ProjectQueries.documentListItems(d, projectID: p)
            XCTAssertEqual(docs.first?.openComments, 1, "the reopened document thread counts as open again")
        }
    }

    func testOwnerCommentRejectsEmptyBodyNoSubjectAndForeignDocument() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let other = try TestDatabase.insertProject(d, name: "other", folder: "/tmp/other")
            let foreignDoc = try TestDatabase.insertProjectDocument(d, projectID: other)
            XCTAssertThrowsError(try ProjectQueries.addOwnerComment(d, projectID: p, targetID: nil, documentID: foreignDoc, anchor: nil, body: "x"))
            XCTAssertThrowsError(try ProjectQueries.addOwnerComment(d, projectID: p, targetID: nil, documentID: nil, anchor: nil, body: "x"))
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/x.md")
            XCTAssertThrowsError(try ProjectQueries.addOwnerComment(d, projectID: p, targetID: nil, documentID: doc, anchor: nil, body: "   "))
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project_comments"), 0)
        }
    }

    func testSetStatusOnlyOnRootsAndOnlyKnownValues() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p)
            let root = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t)
            let reply = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", targetID: t, parentID: root)
            try ProjectQueries.setStatus(d, commentID: root, status: "resolved")
            XCTAssertEqual(try ProjectQueries.comments(d, targetID: t).first?.status, "resolved")
            XCTAssertThrowsError(try ProjectQueries.setStatus(d, commentID: reply, status: "resolved"))
            XCTAssertThrowsError(try ProjectQueries.setStatus(d, commentID: root, status: "closed"))
        }
    }

    func testMarkAgentCommentsReadIsScopedAndLeavesOwnerCommentsAlone() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t1 = try TestDatabase.insertProjectTarget(d, projectID: p, text: "One")
            let t2 = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Two")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t1)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t2)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", targetID: t1)
            XCTAssertEqual(try ProjectQueries.unreadCounts(d), [p: 2])

            try ProjectQueries.markAgentCommentsRead(d, projectID: p, targetID: t1, documentID: nil)
            XCTAssertEqual(try ProjectQueries.unreadCounts(d), [p: 1])
            let ownerReadAt = try String.fetchOne(d, sql: "SELECT read_at FROM project_comments WHERE author = 'owner'")
            XCTAssertEqual(ownerReadAt, "")

            try ProjectQueries.markAgentCommentsRead(d, projectID: p, targetID: nil, documentID: nil)
            XCTAssertEqual(try ProjectQueries.unreadCounts(d), [:])
        }
    }

    func testBoardBuildsTheTreeInStatusOrderWithCounters() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let done = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Done root", status: "done")
            let todo = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Todo root")
            let active = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Active root", status: "in_progress")
            // In progress, so the rollup (PROJ-05) keeps its parent in progress.
            let child = try TestDatabase.insertProjectTarget(
                d, projectID: p, text: "Task 1", status: "in_progress", parentID: active
            )
            _ = try TestDatabase.insertTarget(d, text: "Not a project target")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: child)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", targetID: child, status: "resolved")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "Why?", targetID: child)
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, targetID: active)

            let board = try ProjectQueries.board(d, projectID: p)
            XCTAssertEqual(board.map(\.target.text), ["Active root", "Todo root", "Done root"])
            XCTAssertEqual(board[0].children.map(\.target.text), ["Task 1"])
            XCTAssertEqual(board[0].documents.count, 1)
            XCTAssertEqual(board[0].children[0].openComments, 1, "open owner roots only — not the agent's open root")
            XCTAssertEqual(board[0].children[0].unreadForOwner, 1)
            XCTAssertEqual(Set(board.map { Int64($0.target.id) }), [done, todo, active])
        }
    }

    func testBoardOrdersSiblingsByPriorityBeforeStatus() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Low active", status: "in_progress", priority: "low")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, text: "High todo", priority: "high")
            let parent = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Medium blocked", status: "blocked")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Child low", parentID: parent, priority: "low")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Child high done", status: "done", parentID: parent, priority: "high")

            let board = try ProjectQueries.board(d, projectID: p)
            XCTAssertEqual(board.map(\.target.text), ["High todo", "Medium blocked", "Low active"])
            XCTAssertEqual(board[1].children.map(\.target.text), ["Child high done", "Child low"])
        }
    }

    func testSummariesCountOpenAndInProgressTargetsAndStampDocuments() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, status: "in_progress")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, status: "blocked")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, status: "done")
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p, updatedAt: "2026-09-29T12:00:00Z")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, documentID: doc)
            let empty = try TestDatabase.insertProject(d, name: "empty", folder: "/tmp/empty")

            let summaries = try ProjectQueries.summaries(d)
            let acme = try XCTUnwrap(summaries.first { $0.id == p })
            XCTAssertEqual(acme.openTargets, 2)
            XCTAssertEqual(acme.inProgressTargets, 1)
            XCTAssertEqual(acme.unreadAgentComments, 1)
            XCTAssertEqual(acme.documentStamps, [doc: "2026-09-29T12:00:00Z"])
            let none = try XCTUnwrap(summaries.first { $0.id == empty })
            XCTAssertEqual(none.openTargets, 0)
            XCTAssertEqual(none.documentStamps, [:])
        }
    }

    func testThreadGroupingKeepsRootsInOrderWithTheirReplies() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let first = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc)
            let second = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc)
            let reply = try TestDatabase.insertProjectComment(d, projectID: p, documentID: doc, parentID: first)
            let threads = ProjectCommentThread.group(try ProjectQueries.comments(d, documentID: doc))
            XCTAssertEqual(threads.map(\.id), [first, second])
            XCTAssertEqual(threads[0].replies.map(\.id), [reply])
            XCTAssertTrue(threads[1].replies.isEmpty)
        }
    }

    /// The reply half of Go's `newForAgentPredicate`: an owner reply newer
    /// than the thread's latest agent comment (the agent root counts).
    func testHasUnansweredOwnerReplyComparesAgainstTheLatestAgentComment() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let owner = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc)
            let agentRoot = try TestDatabase.insertProjectComment(d, projectID: p, documentID: doc)
            func thread(_ id: Int64) throws -> ProjectCommentThread {
                try XCTUnwrap(ProjectCommentThread.group(ProjectQueries.comments(d, documentID: doc)).first { $0.id == id })
            }
            XCTAssertFalse(try thread(owner).hasUnansweredOwnerReply, "a bare owner root has no reply")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc, parentID: owner)
            XCTAssertTrue(try thread(owner).hasUnansweredOwnerReply)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, documentID: doc, parentID: owner)
            XCTAssertFalse(try thread(owner).hasUnansweredOwnerReply, "answered by the agent")
            XCTAssertFalse(try thread(agentRoot).hasUnansweredOwnerReply)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc, parentID: agentRoot)
            XCTAssertTrue(try thread(agentRoot).hasUnansweredOwnerReply, "an owner answer to an agent root")
        }
    }

    func testDocumentListItemsCarryTheLinkedTargetAndOpenOwnerThreads() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Payments feature")
            let linked = try TestDatabase.insertProjectDocument(
                d, projectID: p, relPath: "docs/plan.md", targetID: t, updatedAt: "2026-09-29T11:00:00Z"
            )
            let loose = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/notes.md", updatedAt: "2026-09-29T10:00:00Z")
            let root = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: linked, quote: "x")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: linked, status: "resolved", quote: "y")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, documentID: linked, parentID: root)

            let items = try ProjectQueries.documentListItems(d, projectID: p)
            XCTAssertEqual(items.map(\.id), [linked, loose])
            XCTAssertEqual(items[0].targetTitle, "Payments feature")
            XCTAssertEqual(items[0].openComments, 1, "open owner roots only — not resolved roots, not replies")
            XCTAssertNil(items[1].targetTitle)
            XCTAssertEqual(items[1].openComments, 0)
        }
    }

    func testActivitySnapshotCollectsAgentQuestionsDocumentsAndTargets() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p, text: "Task 1", status: "in_progress")
            let old = try TestDatabase.insertProjectComment(d, projectID: p, body: "old?", targetID: t)
            let owner = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "mine", targetID: t)
            let reply = try TestDatabase.insertProjectComment(d, projectID: p, body: "a reply", targetID: t, parentID: owner)
            let fresh = try TestDatabase.insertProjectComment(d, projectID: p, body: "new?", targetID: t)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p, title: "Plan", updatedAt: "2026-09-29T12:00:00Z")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", documentID: doc, quote: "x")
            let project = try XCTUnwrap(ProjectQueries.fetch(d, id: p))

            let snap = try ProjectQueries.activitySnapshot(d, project: project, afterAgentCommentID: old)
            XCTAssertEqual(snap.projectName, "acme")
            XCTAssertEqual(snap.questions.map(\.id), [fresh], "agent roots past the watermark; not owner comments, not replies (\(reply))")
            XCTAssertEqual(snap.questions.first?.targetTitle, "Task 1")
            XCTAssertEqual(snap.lastAgentCommentID, fresh)
            XCTAssertEqual(snap.documents[doc], .init(title: "Plan", updatedAt: "2026-09-29T12:00:00Z", openOwnerComments: 1))
            XCTAssertEqual(snap.targets[t], .init(title: "Task 1", status: "in_progress"))
            XCTAssertTrue(snap.ownerTouched.isEmpty)
        }
    }

    /// #105: an agent document whose target is in review awaits the owner's
    /// review — in the list and in the notification snapshot.
    func testAgentDocumentOnATargetInReviewAwaitsReview() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p)
            // The agent's move, as the project MCP tools claim it.
            try d.execute(sql: "UPDATE targets SET status = 'in_review', status_actor = 'agent' WHERE id = ?", arguments: [t])
            let agent = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/specs/a.md", targetID: t)
            let owner = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "notes/b.md", targetID: t, origin: "owner")
            let loose = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/plans/c.md")
            let items = Dictionary(uniqueKeysWithValues: try ProjectQueries.documentListItems(d, projectID: p).map { ($0.id, $0) })
            XCTAssertEqual(items[agent]?.targetStatus, "in_review")
            XCTAssertEqual(items[agent]?.awaitingReview, true)
            XCTAssertEqual(items[owner]?.awaitingReview, false, "the owner's own document is not handed to them for review")
            XCTAssertEqual(items[loose]?.awaitingReview, false)

            let project = try XCTUnwrap(ProjectQueries.fetch(d, id: p))
            let snapshot = try ProjectQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
            XCTAssertEqual(snapshot.documents[agent]?.awaitingReview, true)

            // The owner moving it to review themselves is not announced back:
            // the latest status change is theirs.
            try d.execute(sql: "UPDATE targets SET status = 'in_progress', status_actor = 'agent' WHERE id = ?", arguments: [t])
            try d.execute(sql: "UPDATE targets SET status = 'in_review', status_actor = 'owner' WHERE id = ?", arguments: [t])
            let ownerMoved = try ProjectQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
            XCTAssertEqual(ownerMoved.documents[agent]?.awaitingReview, false)
            XCTAssertEqual(try ProjectQueries.documentListItems(d, projectID: p).first { $0.id == agent }?.awaitingReview, true,
                           "the list still marks it: it does await the owner's review")
        }
    }

    /// Migration 00083 / #80: an imported or owner-attached document is not
    /// "revised" — it leaves the badge stamps and is marked non-agent in the
    /// notification snapshot. An agent re-attach (origin agent, new
    /// updated_at) makes it count again.
    func testNonAgentDocumentsStayOffTheBadgeUntilTheAgentReattachesThem() throws {
        for origin in ["import", "owner"] {
            try db.write { d in
                let p = try TestDatabase.insertProject(d, folder: "/tmp/acme-\(origin)")
                let doc = try TestDatabase.insertProjectDocument(d, projectID: p, title: "Spec", origin: origin)
                let project = try XCTUnwrap(ProjectQueries.fetch(d, id: p))
                let stamps = { try ProjectQueries.summaries(d).first { $0.id == p }?.documentStamps }

                XCTAssertEqual(try stamps(), [:], origin)
                XCTAssertEqual(try ProjectQueries.document(d, id: doc)?.isAgentAttached, false, origin)
                let before = try ProjectQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
                XCTAssertEqual(before.documents[doc]?.imported, true, origin)

                try d.execute(sql: """
                    UPDATE project_documents SET origin = 'agent', updated_at = '2026-09-29T13:00:00Z' WHERE id = ?
                    """, arguments: [doc])
                XCTAssertEqual(try stamps(), [doc: "2026-09-29T13:00:00Z"], origin)
                let after = try ProjectQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
                XCTAssertEqual(after.documents[doc]?.imported, false, origin)
            }
        }
    }
}
