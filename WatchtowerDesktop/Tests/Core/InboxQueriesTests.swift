import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

// MARK: - InboxQueries Tests
//
// `fetchByID`, and since C1 the Inbox's Messages reads: the open list and
// the badge's unread count over the same rows.

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

    private static let now = "2026-10-22T12:00:00Z"

    nonisolated private static func message(
        _ db: Database,
        _ n: Int,
        created: String,
        readAt: String? = nil,
        trigger: String = "mention",
        channel: String = "C1"
    ) throws -> Int {
        let id = try TestDatabase.insertInboxItem(
            db, channelID: channel, messageTS: "1700000\(String(format: "%04d", n)).000100",
            triggerType: trigger, readAt: readAt)
        try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [created, id])
        return Int(id)
    }

    /// The badge counts the unread among the rows the list shows: past the
    /// list's limit an older unread message counts nothing.
    func testUnreadCountIsCappedLikeTheList() throws {
        let db = try TestDatabase.create()
        let ids = try db.write { conn in
            [
                try Self.message(conn, 1, created: "2026-10-21T07:00:00Z"),
                try Self.message(conn, 2, created: "2026-10-21T08:00:00Z"),
                try Self.message(conn, 3, created: "2026-10-21T09:00:00Z", readAt: "2026-10-21T10:00:00Z")
            ]
        }
        try db.read { conn in
            let listed = try InboxQueries.fetchOpenMessages(conn, nowUTC: Self.now, limit: 2).map(\.item.id)
            XCTAssertEqual(listed, [ids[2], ids[1]])
            XCTAssertEqual(try InboxQueries.unreadOpenMessageCount(conn, nowUTC: Self.now, limit: 2), 1)
            XCTAssertEqual(try InboxQueries.unreadOpenMessageCount(conn, nowUTC: Self.now), 2)
        }
    }

    /// A Jira row whose issue was deleted at the source is neither listed
    /// nor counted; a live issue's row is both.
    func testADeletedJiraIssueRowIsNeitherListedNorCounted() throws {
        let db = try TestDatabase.create()
        let live = try db.write { conn -> Int in
            let acct = try TestDatabase.insertJiraAccount(conn)
            try TestDatabase.insertJiraIssue(conn, account: acct, key: "PROJ-1")
            try TestDatabase.insertJiraIssue(conn, account: acct, key: "PROJ-2") { $0.deleted = true }
            _ = try Self.message(conn, 2, created: "2026-10-21T08:00:00Z", trigger: "jira_assigned", channel: "PROJ-2")
            return try Self.message(conn, 1, created: "2026-10-21T07:00:00Z", trigger: "jira_assigned", channel: "PROJ-1")
        }
        try db.read { conn in
            XCTAssertEqual(try InboxQueries.fetchOpenMessages(conn, nowUTC: Self.now).map(\.item.id), [live])
            XCTAssertEqual(try InboxQueries.unreadOpenMessageCount(conn, nowUTC: Self.now), 1)
        }
    }
}
