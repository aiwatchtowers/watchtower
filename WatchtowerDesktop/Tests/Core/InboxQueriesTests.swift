import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

// MARK: - InboxQueries Tests
//
// `fetchByID` is all that is left of this enum since the inbox demolition: the
// tier/counts/status-mutation queries went with the screens that called them.

final class InboxQueriesTests: XCTestCase {

    func testFetchByIDReturnsTheItem() throws {
        let db = try TestDatabase.create()
        let id = try db.write { conn -> Int in
            try TestDatabase.insertInboxItem(conn, channelID: "C1", messageTS: "1.0", snippet: "Hi")
            return Int(conn.lastInsertedRowID)
        }

        let item = try XCTUnwrap(try db.read { try InboxQueries.fetchByID($0, id: id) })

        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.channelID, "C1")
        XCTAssertEqual(item.snippet, "Hi")
    }

    /// A recap can cite an `[inbox#id]` ref whose item was archived away since —
    /// the caller renders a plain label for nil, so this must not throw.
    func testFetchByIDReturnsNilForUnknownID() throws {
        let db = try TestDatabase.create()

        let item = try db.read { try InboxQueries.fetchByID($0, id: 9999) }

        XCTAssertNil(item)
    }
}
