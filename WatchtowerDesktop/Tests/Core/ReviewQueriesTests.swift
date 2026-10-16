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
