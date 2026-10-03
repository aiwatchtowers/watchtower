import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    func testFetchAllSortsByNameAndFetchReadsOne() throws {
        try db.write { d in
            let beta = try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta")
            _ = try TestDatabase.insertWorkbench(d, name: "Alpha", folder: "/tmp/alpha")
            XCTAssertEqual(try WorkbenchQueries.fetchAll(d).map(\.name), ["Alpha", "beta"])
            let fetched = try XCTUnwrap(WorkbenchQueries.fetch(d, id: beta))
            XCTAssertEqual(fetched.folderPath, "/tmp/beta")
            XCTAssertEqual(fetched.folderURL.path, "/tmp/beta")
            XCTAssertNil(try WorkbenchQueries.fetch(d, id: 999))
        }
    }

    func testImagesAreTheTargetsOwnOldestFirst() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let target = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let other = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Other")
            try TestDatabase.insertWorkbenchTargetImage(d, projectID: p, targetID: target, fileName: "first.png", sha256: "a")
            try TestDatabase.insertWorkbenchTargetImage(d, projectID: p, targetID: target, fileName: "second.png", sha256: "b")
            try TestDatabase.insertWorkbenchTargetImage(d, projectID: p, targetID: other, sha256: "c")
            let images = try WorkbenchQueries.images(d, targetID: target)
            XCTAssertEqual(images.map(\.fileName), ["first.png", "second.png"])
            XCTAssertEqual(images[0].fileURL.path, "/tmp/project_files/1/abc.png")
            try d.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [target])
            XCTAssertEqual(try WorkbenchQueries.images(d, targetID: target), [], "the rows go with their target")
        }
    }

    func testOwnerCommentIsTrimmedAndReplyInheritsTheRootTarget() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let root = try WorkbenchQueries.addOwnerComment(d, projectID: p, targetID: t, body: "  Why 3?  ")
            let reply = try WorkbenchQueries.reply(d, to: root, body: "Follow-up")
            let thread = try WorkbenchQueries.comments(d, targetID: t)
            XCTAssertEqual(thread.map(\.id), [root, reply])
            XCTAssertEqual(thread[0].body, "Why 3?")
            XCTAssertEqual(thread[0].author, "owner")
            XCTAssertEqual(thread[1].parentID, root)
            XCTAssertEqual(thread[1].targetID, t)
            XCTAssertEqual(thread[1].author, "owner")
        }
    }

    /// An owner reply under a resolved or outdated root reopens it (Go twin:
    /// `AddProjectCommentTx`), so the thread counts as open again — the same
    /// open-root rule the agent's new-for-agent channel reads.
    func testOwnerReplyReopensAResolvedOrOutdatedThread() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Feature")
            let resolved = try TestDatabase.insertWorkbenchComment(
                d, projectID: p, author: "owner", targetID: t, status: "resolved"
            )
            let agentReply = try TestDatabase.insertWorkbenchComment(
                d, projectID: p, body: "Done.", targetID: t, parentID: resolved, readAt: "2026-09-30T09:00:00Z"
            )
            let outdated = try TestDatabase.insertWorkbenchComment(
                d, projectID: p, author: "owner", targetID: t, status: "outdated"
            )
            let untouched = try TestDatabase.insertWorkbenchComment(
                d, projectID: p, author: "owner", targetID: t, status: "resolved"
            )
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t, parentID: untouched)

            _ = try WorkbenchQueries.reply(d, to: resolved, body: "One more thing")
            _ = try WorkbenchQueries.reply(d, to: outdated, body: "Still relevant")

            func row(_ id: Int64) throws -> WorkbenchComment {
                try XCTUnwrap(WorkbenchComment.fetchOne(d, sql: "SELECT * FROM project_comments WHERE id = ?", arguments: [id]))
            }
            XCTAssertEqual(try row(resolved).status, "open")
            XCTAssertEqual(try row(outdated).status, "open")
            XCTAssertEqual(try row(untouched).status, "resolved", "a thread nobody replied to keeps its status")
            let agent = try row(agentReply)
            XCTAssertEqual(agent.author, "agent")
            XCTAssertEqual(agent.readAt, "2026-09-30T09:00:00Z", "the agent's rows are not rewritten")
            let board = try WorkbenchQueries.board(d, projectID: p)
            XCTAssertEqual(board.first?.openComments, 2, "both reopened threads count as open again")
        }
    }

    func testOwnerCommentRejectsEmptyBodyAndForeignTarget() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let other = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            let foreign = try TestDatabase.insertWorkbenchTarget(d, projectID: other)
            XCTAssertThrowsError(try WorkbenchQueries.addOwnerComment(d, projectID: p, targetID: foreign, body: "x")) {
                XCTAssertEqual($0 as? WorkbenchQueryError, .wrongWorkbench)
            }
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            XCTAssertThrowsError(try WorkbenchQueries.addOwnerComment(d, projectID: p, targetID: t, body: "   ")) {
                XCTAssertEqual($0 as? WorkbenchQueryError, .emptyBody)
            }
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project_comments"), 0)
        }
    }

    func testSetStatusOnlyOnRootsAndOnlyKnownValues() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let root = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t)
            let reply = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: t, parentID: root)
            try WorkbenchQueries.setStatus(d, commentID: root, status: "resolved")
            XCTAssertEqual(try WorkbenchQueries.comments(d, targetID: t).first?.status, "resolved")
            XCTAssertThrowsError(try WorkbenchQueries.setStatus(d, commentID: reply, status: "resolved"))
            XCTAssertThrowsError(try WorkbenchQueries.setStatus(d, commentID: root, status: "closed"))
        }
    }

    func testMarkAgentCommentsReadIsScopedAndLeavesOwnerCommentsAlone() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t1 = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "One")
            let t2 = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Two")
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t1)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t2)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: t1)
            XCTAssertEqual(try WorkbenchQueries.unreadCounts(d), [p: 2])

            try WorkbenchQueries.markAgentCommentsRead(d, projectID: p, targetID: t1)
            XCTAssertEqual(try WorkbenchQueries.unreadCounts(d), [p: 1])
            let ownerReadAt = try String.fetchOne(d, sql: "SELECT read_at FROM project_comments WHERE author = 'owner'")
            XCTAssertEqual(ownerReadAt, "")

            try WorkbenchQueries.markAgentCommentsRead(d, projectID: p, targetID: nil)
            XCTAssertEqual(try WorkbenchQueries.unreadCounts(d), [:])
        }
    }

    func testBoardBuildsTheTreeInStatusOrderWithCounters() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let done = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Done root", status: "done")
            let todo = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Todo root")
            let active = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Active root", status: "in_progress")
            // In progress, so the rollup (PROJ-05) keeps its parent in progress.
            let child = try TestDatabase.insertWorkbenchTarget(
                d, projectID: p, text: "Task 1", status: "in_progress", parentID: active
            )
            _ = try TestDatabase.insertTarget(d, text: "Not a project target")
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: child)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: child, status: "resolved")
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", body: "Why?", targetID: child)

            let board = try WorkbenchQueries.board(d, projectID: p)
            XCTAssertEqual(board.map(\.target.text), ["Active root", "Todo root", "Done root"])
            XCTAssertEqual(board[0].children.map(\.target.text), ["Task 1"])
            XCTAssertEqual(board[0].children[0].openComments, 1, "open owner roots only — not the agent's open root")
            XCTAssertEqual(board[0].children[0].unreadForOwner, 1)
            XCTAssertEqual(Set(board.map { Int64($0.target.id) }), [done, todo, active])
        }
    }

    func testBoardOrdersSiblingsByPriorityBeforeStatus() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            _ = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Low active", status: "in_progress", priority: "low")
            _ = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "High todo", priority: "high")
            let parent = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Medium blocked", status: "blocked")
            _ = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Child low", parentID: parent, priority: "low")
            _ = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Child high done", status: "done", parentID: parent, priority: "high")

            let board = try WorkbenchQueries.board(d, projectID: p)
            XCTAssertEqual(board.map(\.target.text), ["High todo", "Medium blocked", "Low active"])
            XCTAssertEqual(board[1].children.map(\.target.text), ["Child high done", "Child low"])
        }
    }

    func testSummariesCountOpenAndInProgressTargetsAndUnreadComments() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            _ = try TestDatabase.insertWorkbenchTarget(d, projectID: p, status: "in_progress")
            _ = try TestDatabase.insertWorkbenchTarget(d, projectID: p, status: "blocked")
            let done = try TestDatabase.insertWorkbenchTarget(d, projectID: p, status: "done")
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: done)
            let empty = try TestDatabase.insertWorkbench(d, name: "empty", folder: "/tmp/empty")

            let summaries = try WorkbenchQueries.summaries(d)
            let acme = try XCTUnwrap(summaries.first { $0.id == p })
            XCTAssertEqual(acme.openTargets, 2)
            XCTAssertEqual(acme.inProgressTargets, 1)
            XCTAssertEqual(acme.unreadAgentComments, 1)
            let none = try XCTUnwrap(summaries.first { $0.id == empty })
            XCTAssertEqual(none.openTargets, 0)
            XCTAssertEqual(none.unreadAgentComments, 0)
        }
    }

    func testThreadGroupingKeepsRootsInOrderWithTheirReplies() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let first = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: t)
            let second = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: t)
            let reply = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t, parentID: first)
            let threads = WorkbenchCommentThread.group(try WorkbenchQueries.comments(d, targetID: t))
            XCTAssertEqual(threads.map(\.id), [first, second])
            XCTAssertEqual(threads[0].replies.map(\.id), [reply])
            XCTAssertTrue(threads[1].replies.isEmpty)
        }
    }

    /// The reply half of Go's `newForAgentPredicate`: an owner reply newer
    /// than the thread's latest agent comment (the agent root counts).
    func testHasUnansweredOwnerReplyComparesAgainstTheLatestAgentComment() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let owner = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: t)
            let agentRoot = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t)
            func thread(_ id: Int64) throws -> WorkbenchCommentThread {
                try XCTUnwrap(WorkbenchCommentThread.group(WorkbenchQueries.comments(d, targetID: t)).first { $0.id == id })
            }
            XCTAssertFalse(try thread(owner).hasUnansweredOwnerReply, "a bare owner root has no reply")
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: t, parentID: owner)
            XCTAssertTrue(try thread(owner).hasUnansweredOwnerReply)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t, parentID: owner)
            XCTAssertFalse(try thread(owner).hasUnansweredOwnerReply, "answered by the agent")
            XCTAssertFalse(try thread(agentRoot).hasUnansweredOwnerReply)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", targetID: t, parentID: agentRoot)
            XCTAssertTrue(try thread(agentRoot).hasUnansweredOwnerReply, "an owner answer to an agent root")
        }
    }

    func testActivitySnapshotCollectsAgentQuestionsAndTargets() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Task 1", status: "in_progress")
            let old = try TestDatabase.insertWorkbenchComment(d, projectID: p, body: "old?", targetID: t)
            let owner = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", body: "mine", targetID: t)
            let reply = try TestDatabase.insertWorkbenchComment(d, projectID: p, body: "a reply", targetID: t, parentID: owner)
            let fresh = try TestDatabase.insertWorkbenchComment(d, projectID: p, body: "new?", targetID: t)
            let project = try XCTUnwrap(WorkbenchQueries.fetch(d, id: p))

            let snap = try WorkbenchQueries.activitySnapshot(d, project: project, afterAgentCommentID: old)
            XCTAssertEqual(snap.projectName, "acme")
            XCTAssertEqual(snap.questions.map(\.id), [fresh], "agent roots past the watermark; not owner comments, not replies (\(reply))")
            XCTAssertEqual(snap.questions.first?.targetTitle, "Task 1")
            XCTAssertEqual(snap.lastAgentCommentID, fresh)
            XCTAssertTrue(snap.documents.isEmpty, "documents were replaced by asks")
            XCTAssertEqual(snap.targets[t], .init(title: "Task 1", status: "in_progress"))
            XCTAssertTrue(snap.ownerTouched.isEmpty)
        }
    }

    /// #166: the snapshot carries the workbench's pending proposals (a Slack
    /// send from the terminal) and the highest proposal id, never another
    /// workbench's or a decided one.
    func testActivitySnapshotReadsTheProjectsPendingProposals() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let key = String(p)
            let args = ##"{"text":"build is green","target":{"account_id":1,"workspace":"Acme","channel_id":"C1","label":"#ops"}}"##
            let pending = try TestDatabase.insertAgentAction(
                d, tool: "send_slack_message", external: true, argsJSON: args,
                surface: "project", conversationID: 0, contextType: "project", contextID: key
            )
            let decided = try TestDatabase.insertAgentAction(
                d, tool: "send_slack_message", external: true, argsJSON: args,
                surface: "project", conversationID: 0, contextType: "project", contextID: key, status: "applied"
            )
            _ = try TestDatabase.insertAgentAction(
                d, tool: "send_slack_message", argsJSON: args,
                surface: "project", conversationID: 0, contextType: "project", contextID: "999"
            )
            let project = try XCTUnwrap(WorkbenchQueries.fetch(d, id: p))

            let snap = try WorkbenchQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
            XCTAssertEqual(snap.pendingActions.map(\.id), [pending])
            XCTAssertEqual(snap.pendingActions.first?.summary, "To: #ops in Acme — build is green")
            XCTAssertEqual(snap.lastActionID, decided)
        }
    }

}
