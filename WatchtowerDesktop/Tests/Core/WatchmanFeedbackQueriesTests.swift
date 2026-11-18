import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The owner's feedback writes (spec §8.3, §10; WATCHMAN-03): OK, Correct…
/// and check done each write once, and only on what they are for.
final class WatchmanFeedbackQueriesTests: XCTestCase {
    private let first = AutomationDates.parse("2026-11-17T08:00:00Z") ?? .distantPast
    private let second = AutomationDates.parse("2026-11-17T09:00:00Z") ?? .distantPast

    @discardableResult
    private func item(_ db: Database, kind: String = "ask", outcome: String = "answered", state: String = "done") throws -> Int64 {
        let workbench = try Int64.fetchOne(db, sql: "SELECT id FROM projects LIMIT 1") ?? TestDatabase.insertWorkbench(db)
        let ref = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(ref_id), 0) + 1 FROM watchman_items") ?? 1
        try db.execute(sql: """
            INSERT INTO watchman_items (workbench_id, kind, ref_kind, ref_id, state, outcome, question, choice,
                created_at)
            VALUES (?, ?, 'ask', ?, ?, ?, 'Store the window per workbench?', 'Per workbench', '2026-11-17T02:14:00Z')
            """, arguments: [workbench, kind, ref, state, outcome])
        return db.lastInsertedRowID
    }

    private func feedback(_ queue: DatabaseQueue, _ id: Int64) throws -> Row? {
        try queue.read {
            try Row.fetchOne($0, sql: "SELECT feedback, feedback_text, feedback_at, check_done_at FROM watchman_items WHERE id = ?",
                             arguments: [id])
        }
    }

    /// OK writes once: a second tap, and a Correct… after it, write nothing.
    func testOKWritesOnce() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try item($0) }
        let (first, second) = (first, second)
        XCTAssertTrue(try queue.write { try WatchmanFeedbackQueries.ok($0, itemID: id, now: first) })
        XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.ok($0, itemID: id, now: second) })
        XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.correct($0, itemID: id, text: "Global", now: second) })
        let row = try XCTUnwrap(feedback(queue, id))
        XCTAssertEqual(row["feedback"], "ok")
        XCTAssertEqual(row["feedback_text"], "")
        XCTAssertEqual(row["feedback_at"], "2026-11-17T08:00:00Z")
    }

    /// Correct… stores the owner's words, trimmed, once; a blank one is refused.
    func testCorrectStoresTextOnce() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try item($0) }
        let (first, second) = (first, second)
        XCTAssertThrowsError(try queue.write { try WatchmanFeedbackQueries.correct($0, itemID: id, text: "  \n ") }) {
            XCTAssertEqual($0 as? WatchmanFeedbackError, .blankCorrection)
        }
        XCTAssertTrue(try queue.write {
            try WatchmanFeedbackQueries.correct($0, itemID: id, text: "  Global, one window for all.\n", now: first)
        })
        XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.correct($0, itemID: id, text: "Other", now: second) })
        XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.ok($0, itemID: id, now: second) })
        let row = try XCTUnwrap(feedback(queue, id))
        XCTAssertEqual(row["feedback"], "corrected")
        XCTAssertEqual(row["feedback_text"], "Global, one window for all.")
        XCTAssertEqual(row["feedback_at"], "2026-11-17T08:00:00Z")
    }

    /// Only a finished twin decision takes OK or Correct…: a parked, handed
    /// or owner-first item, a check and an item still deciding are not the
    /// twin's decisions, so learning must never read them as one.
    func testOnlyTwinDecisionsTakeFeedback() throws {
        let queue = try TestDatabase.create()
        let ids = try queue.write { db in
            [try item(db, outcome: "parked"), try item(db, outcome: "handed"), try item(db, outcome: "owner_first"),
             try item(db, kind: "check"), try item(db, outcome: "", state: "deciding")]
        }
        for id in ids {
            XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.ok($0, itemID: id) }, "item \(id)")
            XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.correct($0, itemID: id, text: "x") }, "item \(id)")
            XCTAssertEqual(try feedback(queue, id)?["feedback"], "")
        }
        let approved = try queue.write { try item($0, kind: "review_code", outcome: "approved") }
        XCTAssertTrue(try queue.write { try WatchmanFeedbackQueries.ok($0, itemID: approved) })
    }

    /// Check done stamps the check once, and it leaves Checks nobody ran.
    func testCheckDoneLeavesChecksList() throws {
        let queue = try TestDatabase.create()
        let (check, ask) = try queue.write { (try item($0, kind: "check"), try item($0)) }
        let (first, second) = (first, second)
        let checks = { try queue.read { try WatchmanJournalQueries.nights($0, limit: 1).first?.checks.map(\.id) } }
        XCTAssertEqual(try checks(), [check])
        XCTAssertTrue(try queue.write { try WatchmanFeedbackQueries.checkDone($0, itemID: check, now: first) })
        XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.checkDone($0, itemID: check, now: second) })
        XCTAssertFalse(try queue.write { try WatchmanFeedbackQueries.checkDone($0, itemID: ask) })
        XCTAssertEqual(try checks(), [])
        let row = try XCTUnwrap(feedback(queue, check))
        XCTAssertEqual(row["check_done_at"], "2026-11-17T08:00:00Z")
        XCTAssertEqual(row["feedback"], "", "check done is not feedback")
    }

    /// The journal reads the owner's correction back.
    func testJournalReadsTheCorrection() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try item($0) }
        try queue.write { _ = try WatchmanFeedbackQueries.correct($0, itemID: id, text: "Global") }
        let decided = try queue.read { try WatchmanJournalQueries.nights($0, limit: 1).first?.decided }
        XCTAssertEqual(decided?.first?.feedback, "corrected")
        XCTAssertEqual(decided?.first?.feedbackText, "Global")
    }
}
