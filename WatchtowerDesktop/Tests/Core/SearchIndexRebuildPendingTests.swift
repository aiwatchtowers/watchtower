import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The same states as Go's TestMessagesSearchPending_States
/// (internal/db/fts_rebuild_test.go): the two sides must agree.
final class SearchIndexRebuildPendingTests: XCTestCase {
    func testNeitherKeyNorLegacyTableIsNotPending() throws {
        let db = try TestDatabase.create()
        try db.read { d in XCTAssertFalse(try SearchQueries.messagesIndexRebuildPending(d)) }
    }

    func testPendingKeyIsPendingWhateverItsValue() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "INSERT INTO db_maintenance (key, value) VALUES ('fts_rebuild_pending', '0')")
            XCTAssertTrue(try SearchQueries.messagesIndexRebuildPending(d))
        }
    }

    func testLegacyTableAloneIsPending() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "CREATE VIRTUAL TABLE messages_fts_legacy USING fts5(text)")
            XCTAssertTrue(try SearchQueries.messagesIndexRebuildPending(d))
        }
    }

    func testOtherKeysAndMissingMaintenanceTableAreNotPending() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "INSERT INTO db_maintenance (key, value) VALUES ('fts_rebuild_cursor_messages', '42')")
            XCTAssertFalse(try SearchQueries.messagesIndexRebuildPending(d))
            try d.execute(sql: "DROP TABLE db_maintenance")
            XCTAssertFalse(try SearchQueries.messagesIndexRebuildPending(d))
        }
    }
}
