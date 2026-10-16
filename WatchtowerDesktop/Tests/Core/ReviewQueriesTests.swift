import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

final class ReviewQueriesTests: XCTestCase {
    private let anchor = CommentAnchor(quote: "q", prefix: "", suffix: "", heading: "")

    func testDraftLifecycleAndSentRowsAreImmutable() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        let id = try draft(db, roundID, "a.go", tree: "t", body: "b")
        try db.write { try ReviewQueries.updateDraft($0, id: id, body: "b2") }
        XCTAssertEqual(try db.read { try ReviewQueries.comments($0, roundID: roundID) }.first?.body, "b2")
        try db.write { try $0.execute(sql: "UPDATE review_comments SET status='sent' WHERE id=?", arguments: [id]) }
        XCTAssertThrowsError(try db.write { try ReviewQueries.updateDraft($0, id: id, body: "late") })
        XCTAssertThrowsError(try db.write { try ReviewQueries.deleteDraft($0, id: id) })
    }

    func testViewedKeepsContentSHA() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        try db.write { try ReviewQueries.setViewed($0, roundID: roundID, path: "a.go", contentSHA: "s1") }
        XCTAssertEqual(try db.read { try ReviewQueries.viewed($0, roundID: roundID) }, ["a.go": "s1"])
        try db.write { try ReviewQueries.setViewed($0, roundID: roundID, path: "a.go", contentSHA: nil) }
        XCTAssertEqual(try db.read { try ReviewQueries.viewed($0, roundID: roundID) }, [:])
    }

    func testReview03_CarryNeverDropsAComment() throws {
        let db = try TestDatabase.create()
        let r1 = try db.write { try Self.seedRound($0) }
        let a = try draft(db, r1, "a.go", tree: "t1", body: "keep")
        let b = try draft(db, r1, "b.go", tree: "t1", body: "gone")
        try db.write {
            try $0.execute(sql: "UPDATE review_rounds SET status='sent' WHERE id=?", arguments: [r1])
            try $0.execute(sql: "UPDATE review_comments SET status='sent'")
        }
        let r2 = try db.write { try Self.seedRound($0) }
        let prev = try db.read { try ReviewQueries.comments($0, roundID: r1) }
        let plan = ReviewCommentAnchor.Plan(moved: [a: .init(startLine: 5, endLine: 5)], lost: [b])
        try db.write { try ReviewQueries.carry($0, from: prev, into: r2, plan: plan, treeSHA: "t2") }
        let now = try db.read { try ReviewQueries.comments($0, roundID: r2) }
        XCTAssertEqual(now.count, 2)
        XCTAssertEqual(now.first { $0.carriedFrom == a }?.status, .carried)
        XCTAssertEqual(now.first { $0.carriedFrom == a }?.startLine, 5)
        XCTAssertEqual(now.first { $0.carriedFrom == b }?.status, .outdated)
    }

    /// An outdated comment goes on as outdated with its quote; a resolved one stays behind.
    func testCarryKeepsOutdatedAndLeavesResolvedBehind() throws {
        let db = try TestDatabase.create()
        let r1 = try db.write { try Self.seedRound($0) }
        let lost = try draft(db, r1, "a.go", tree: "t1", body: "still lost")
        let done = try draft(db, r1, "b.go", tree: "t1", body: "done")
        try db.write {
            try $0.execute(sql: "UPDATE review_rounds SET status='sent' WHERE id=?", arguments: [r1])
            try ReviewQueries.markOutdated($0, id: lost)
            try $0.execute(sql: "UPDATE review_comments SET status='resolved' WHERE id=?", arguments: [done])
        }
        let r2 = try db.write { try Self.seedRound($0) }
        let prev = try db.read { try ReviewQueries.comments($0, roundID: r1) }
        try db.write { try ReviewQueries.carry($0, from: prev, into: r2, plan: .init(), treeSHA: "t2") }
        let now = try db.read { try ReviewQueries.comments($0, roundID: r2) }
        XCTAssertEqual(now.count, 1)
        XCTAssertEqual(now.first?.carriedFrom, lost)
        XCTAssertEqual(now.first?.status, .outdated)
        XCTAssertEqual(now.first?.quote, "q")
        XCTAssertEqual(now.first?.body, "still lost")
    }

    func testReplaceMovesAndMarkOutdatedKeepsTheRow() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        let a = try draft(db, roundID, "a.go", tree: "t1", body: "move")
        let b = try draft(db, roundID, "b.go", tree: "t1", body: "lose")
        try db.write {
            try ReviewQueries.replace($0, id: a, placement: .init(startLine: 4, endLine: 6), treeSHA: "t2")
            try ReviewQueries.markOutdated($0, id: b)
        }
        let rows = try db.read { try ReviewQueries.comments($0, roundID: roundID) }
        XCTAssertEqual(rows.first { $0.id == a }?.startLine, 4)
        XCTAssertEqual(rows.first { $0.id == a }?.endLine, 6)
        XCTAssertEqual(rows.first { $0.id == a }?.treeSHA, "t2")
        XCTAssertEqual(rows.first { $0.id == a }?.status, .draft)
        XCTAssertEqual(rows.first { $0.id == b }?.status, .outdated)
        XCTAssertThrowsError(try db.write { try ReviewQueries.markOutdated($0, id: b) }) {
            XCTAssertEqual($0 as? ReviewQueries.ReviewQueryError, .notADraft)
        }
        XCTAssertThrowsError(try db.write { try ReviewQueries.replace($0, id: b, placement: .init(startLine: 1, endLine: 1), treeSHA: "t3") })
    }

    func testResolveClosesCarriedAndOutdatedOnly() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        let id = try draft(db, roundID, "a.go", tree: "t", body: "b")
        XCTAssertThrowsError(try db.write { try ReviewQueries.resolve($0, id: id) }) {
            XCTAssertEqual($0 as? ReviewQueries.ReviewQueryError, .notResolvable)
        }
        try db.write { try $0.execute(sql: "UPDATE review_comments SET status='carried' WHERE id=?", arguments: [id]) }
        try db.write { try ReviewQueries.resolve($0, id: id) }
        XCTAssertEqual(try db.read { try ReviewQueries.comments($0, roundID: roundID) }.first?.status, .resolved)
    }

    func testSetCheckUpsertsAndDeletes() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        try db.write { try ReviewQueries.setCheck($0, roundID: roundID, chapterKey: "dir:cmd", lens: "tests", itemKey: "k1", state: .checked) }
        try db.write { try ReviewQueries.setCheck($0, roundID: roundID, chapterKey: "dir:cmd", lens: "tests", itemKey: "k1", state: .commented) }
        let rows = try db.read { try ReviewQueries.checks($0, roundID: roundID) }
        XCTAssertEqual(rows, [ReviewCheck(chapterKey: "dir:cmd", lens: "tests", itemKey: "k1", state: .commented)])
        try db.write { try ReviewQueries.setCheck($0, roundID: roundID, chapterKey: "dir:cmd", lens: "tests", itemKey: "k1", state: nil) }
        XCTAssertEqual(try db.read { try ReviewQueries.checks($0, roundID: roundID) }, [])
    }

    func testSetCheckAndRoundStateRefusedOnSentRound() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        try db.write { try $0.execute(sql: "UPDATE review_rounds SET status='sent' WHERE id=?", arguments: [roundID]) }
        XCTAssertThrowsError(try db.write {
            try ReviewQueries.setCheck($0, roundID: roundID, chapterKey: "c", lens: "tests", itemKey: "k", state: .checked)
        }) { XCTAssertEqual($0 as? ReviewQueries.ReviewQueryError, .roundNotOpen) }
        XCTAssertEqual(try db.read { try ReviewQueries.checks($0, roundID: roundID) }, [])
        let changed = try db.write {
            try ReviewQueries.saveRoundState($0, roundID: roundID, mode: "deep", phase: .wrapup, chapterKey: "x", activeSeconds: 9)
        }
        XCTAssertFalse(changed)
        let row = try XCTUnwrap(try db.read { try Row.fetchOne($0, sql: "SELECT * FROM review_rounds WHERE id=?", arguments: [roundID]) })
        XCTAssertEqual(row["mode"] as String, "quick")
        XCTAssertEqual(row["phase"] as String, "")
        XCTAssertEqual(row["active_seconds"] as Int, 0)
    }

    func testSaveRoundStatePersists() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        let changed = try db.write {
            try ReviewQueries.saveRoundState($0, roundID: roundID, mode: "deep", phase: .wrapup, chapterKey: "dir:cmd", activeSeconds: 125)
        }
        XCTAssertTrue(changed)
        let row = try XCTUnwrap(try db.read { try Row.fetchOne($0, sql: "SELECT * FROM review_rounds WHERE id=?", arguments: [roundID]) })
        XCTAssertEqual(row["mode"] as String, "deep")
        XCTAssertEqual(row["phase"] as String, "wrapup")
        XCTAssertEqual(row["chapter_key"] as String, "dir:cmd")
        XCTAssertEqual(row["active_seconds"] as Int, 125)
    }

    func testAddDraftDesignCommentWithLens() throws {
        let db = try TestDatabase.create()
        let roundID = try db.write { try Self.seedRound($0) }
        _ = try db.write {
            try ReviewQueries.addDraft($0, roundID: roundID, path: nil, side: "new", startLine: 0, endLine: 0,
                                       anchor: anchor, treeSHA: "t", body: "why", lens: "intent")
        }
        let row = try XCTUnwrap(try db.read { try ReviewQueries.comments($0, roundID: roundID) }.first)
        XCTAssertNil(row.path)
        XCTAssertEqual(row.lens, "intent")
    }

    // MARK: - Plan 3: notes, reverts, lessons, the agent's answers

    func testNotesDecodePathsJSON() throws {
        let db = try TestDatabase.create()
        let round = try db.write { try Self.seedRound($0) }
        let (project, session) = try db.read { db -> (Int64, Int64) in
            let r = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT project_id, session_id FROM review_rounds WHERE id = ?", arguments: [round]))
            return (r["project_id"], r["session_id"])
        }
        try db.write {
            try $0.execute(sql: """
                INSERT INTO review_notes (project_id, session_id, tree_sha, kind, ord, path, start_line, end_line, quote, text, paths_json, core, why)
                VALUES (?, ?, 't', 'chapter', 1, '', 0, 0, '', 'Server', '["a.go","b.go"]', 1, 'the core'),
                       (?, ?, 't', 'note', 1, 'a.go', 3, 4, 'q', 'look here', '[]', 0, '')
                """, arguments: [project, session, project, session])
        }
        let notes = try db.read { try ReviewQueries.notes($0, projectID: project, sessionID: session) }
        XCTAssertEqual(notes.map(\.kind), [.chapter, .note])
        XCTAssertEqual(notes[0].paths, ["a.go", "b.go"])
        XCTAssertTrue(notes[0].core)
        XCTAssertEqual(notes[0].why, "the core")
        XCTAssertEqual(notes[1].path, "a.go")
        XCTAssertEqual(notes[1].startLine, 3)
        XCTAssertEqual(notes[1].treeSHA, "t")
        XCTAssertEqual(notes[1].paths, [])
    }

    func testRevertsInRoundOrder() throws {
        let db = try TestDatabase.create()
        let round = try db.write { try Self.seedRound($0) }
        try db.write {
            for (hunk, path) in [("h2", "b.go"), ("h1", "a.go")] {
                try $0.execute(sql: "INSERT INTO review_reverts (round_id, hunk_id, path, header, patch) VALUES (?, ?, ?, '@@', 'p')",
                               arguments: [round, hunk, path])
            }
        }
        let reverts = try db.read { try ReviewQueries.reverts($0, roundID: round) }
        XCTAssertEqual(reverts.map(\.hunkID), ["h2", "h1"])
        XCTAssertEqual(reverts[0].path, "b.go")
        XCTAssertEqual(reverts[0].header, "@@")
        XCTAssertFalse(reverts[0].at.isEmpty)
    }

    func testProposedLessonsOnly() throws {
        let db = try TestDatabase.create()
        let project = try db.write { _ = try Self.seedRound($0); return try XCTUnwrap(try Int64.fetchOne($0, sql: "SELECT id FROM projects")) }
        try db.write {
            try $0.execute(sql: """
                INSERT INTO review_lessons (project_id, lens, text, source_comment_ids, status)
                VALUES (?, 'tests', 'add a test', '[4,7]', 'proposed'), (?, 'tests', 'old', '[1]', 'accepted')
                """, arguments: [project, project])
        }
        let lessons = try db.read { try ReviewQueries.proposedLessons($0, projectID: project) }
        XCTAssertEqual(lessons.count, 1)
        XCTAssertEqual(lessons[0].sourceCommentIDs, [4, 7])
        XCTAssertEqual(lessons[0].text, "add a test")
    }

    func testAgentResolvedListsOnlyAgentResolved() throws {
        let f = try replyFixture()
        // Owner-resolved (no agent_reply_at) is left out; the copy shadows its source.
        let owner = try draft(f.db, f.prev, "o.go", body: "owner closed")
        try f.db.write {
            try $0.execute(sql: "UPDATE review_comments SET status='resolved' WHERE id=?", arguments: [owner])
            try $0.execute(sql: """
                UPDATE review_comments SET status='resolved', agent_reply='fixed', agent_reply_at='2026-10-16T10:00:00Z' WHERE id IN (?, ?)
                """, arguments: [f.source, f.copy])
        }
        let list = try f.db.read { try ReviewQueries.agentResolved($0, previousRoundID: f.prev, openRoundID: f.open) }
        XCTAssertEqual(list.map(\.id), [f.copy])
        XCTAssertEqual(list[0].agentReplyAt, "2026-10-16T10:00:00Z")
    }

    func testReopenInsertsACarriedCopy() throws {
        let f = try replyFixture(withCopy: false)
        try f.db.write { try Self.agentResolve($0, f.source) }
        try f.db.write { try ReviewQueries.reopen($0, commentID: f.source, openRoundID: f.open) }
        let open = try f.db.read { try ReviewQueries.comments($0, roundID: f.open) }
        let copy = try XCTUnwrap(open.first { $0.carriedFrom == f.source })
        XCTAssertEqual(copy.status, .carried)
        XCTAssertEqual(copy.path, "a.go")
        XCTAssertEqual(copy.body, "b")
        XCTAssertEqual(copy.agentReply, "fixed")
        // The reopened source no longer counts as agent-resolved.
        XCTAssertEqual(try f.db.read { try ReviewQueries.agentResolved($0, previousRoundID: f.prev, openRoundID: f.open) }, [])
        // Reopening again does not add a second copy.
        try f.db.write { try ReviewQueries.reopen($0, commentID: f.source, openRoundID: f.open) }
        XCTAssertEqual(try f.db.read { try ReviewQueries.comments($0, roundID: f.open) }.count, 1)
    }

    func testReopenRestoresTheOpenCopy() throws {
        let f = try replyFixture()
        try f.db.write {
            try Self.agentResolve($0, f.source)
            try Self.agentResolve($0, f.copy)
        }
        try f.db.write { try ReviewQueries.reopen($0, commentID: f.source, openRoundID: f.open) }
        let open = try f.db.read { try ReviewQueries.comments($0, roundID: f.open) }
        XCTAssertEqual(open.map(\.status), [.carried])
        XCTAssertEqual(open[0].id, f.copy)
        // The copy itself, resolved again, reopens as carried; a copy-less draft as draft.
        try f.db.write { try Self.agentResolve($0, f.copy) }
        try f.db.write { try ReviewQueries.reopen($0, commentID: f.copy, openRoundID: f.open) }
        XCTAssertEqual(try f.db.read { try ReviewQueries.comments($0, roundID: f.open) }.map(\.status), [.carried])
        let own = try draft(f.db, f.open, "n.go")
        try f.db.write { try Self.agentResolve($0, own) }
        try f.db.write { try ReviewQueries.reopen($0, commentID: own, openRoundID: f.open) }
        XCTAssertEqual(try f.db.read { try ReviewQueries.comments($0, roundID: f.open) }.last?.status, .draft)
    }

    func testReopenRefusedOnSentRound() throws {
        let f = try replyFixture(withCopy: false)
        try f.db.write {
            try Self.agentResolve($0, f.source)
            try $0.execute(sql: "UPDATE review_rounds SET status='sent' WHERE id=?", arguments: [f.open])
        }
        XCTAssertThrowsError(try f.db.write { try ReviewQueries.reopen($0, commentID: f.source, openRoundID: f.open) }) {
            XCTAssertEqual($0 as? ReviewQueries.ReviewQueryError, .roundNotOpen)
        }
        XCTAssertEqual(try f.db.read { try ReviewQueries.comments($0, roundID: f.open) }.count, 0)
    }

    func testReopenRefusedForAnUnrelatedRound() throws {
        let f = try replyFixture(withCopy: false)
        // A comment of a round that is neither the open one nor the one it follows.
        let other = try f.db.write { try Self.seedRound($0) }
        let foreign = try draft(f.db, other, "x.go")
        try f.db.write { try Self.agentResolve($0, foreign) }
        try f.db.write { try ReviewQueries.reopen($0, commentID: foreign, openRoundID: f.open) }
        XCTAssertEqual(try f.db.read { try ReviewQueries.comments($0, roundID: f.open) }.count, 0)
    }

    private struct ReplyFixture {
        let db: DatabaseQueue
        let prev: Int64
        let open: Int64
        let source: Int64
        let copy: Int64
    }

    /// A sent previous round with a comment, and (optionally) its carried copy in the session's open round.
    private func replyFixture(withCopy: Bool = true) throws -> ReplyFixture {
        let db = try TestDatabase.create()
        let prev = try db.write { try Self.seedRound($0) }
        let source = try draft(db, prev, "a.go")
        try db.write {
            try $0.execute(sql: "UPDATE review_comments SET status='sent' WHERE id=?", arguments: [source])
            try $0.execute(sql: "UPDATE review_rounds SET status='sent' WHERE id=?", arguments: [prev])
        }
        let open = try db.write { try Self.seedRound($0) }
        try db.write { try $0.execute(sql: "UPDATE review_rounds SET prev_round_id = ? WHERE id = ?", arguments: [prev, open]) }
        var copy: Int64 = 0
        if withCopy {
            let rows = try db.read { try ReviewQueries.comments($0, roundID: prev) }
            try db.write {
                try ReviewQueries.carry($0, from: rows, into: open, plan: .init(moved: [:], lost: []), treeSHA: "t")
                copy = try XCTUnwrap(try Int64.fetchOne($0, sql: "SELECT id FROM review_comments WHERE round_id=?", arguments: [open]))
            }
        }
        return ReplyFixture(db: db, prev: prev, open: open, source: source, copy: copy)
    }

    private static func agentResolve(_ db: Database, _ id: Int64) throws {
        try db.execute(sql: """
            UPDATE review_comments SET status='resolved', agent_reply='fixed', agent_reply_at='2026-10-16T10:00:00Z' WHERE id=?
            """, arguments: [id])
    }

    private func draft(_ db: DatabaseQueue, _ round: Int64, _ path: String, tree: String = "t", body: String = "b") throws -> Int64 {
        try db.write {
            try ReviewQueries.addDraft($0, roundID: round, path: path, side: "new", startLine: 1, endLine: 1,
                                       anchor: anchor, treeSHA: tree, body: body)
        }
    }

    /// A project (once), its own session (one open round per session) and an open round.
    private static func seedRound(_ db: Database) throws -> Int64 {
        let project = try Int64.fetchOne(db, sql: "SELECT id FROM projects LIMIT 1")
            ?? TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
        try db.execute(sql: """
            INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'S', '/tmp/acme')
            """, arguments: [project])
        let session = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO review_rounds (project_id, session_id, folder_root, base_sha, tree_sha) VALUES (?, ?, '/tmp/acme', 'b', 't')
            """, arguments: [project, session])
        return db.lastInsertedRowID
    }
}
