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
        try db.write { try ReviewQueries.setCheck($0, roundID: roundID, chapterKey: "c", lens: "tests", itemKey: "k", state: .checked) }
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
