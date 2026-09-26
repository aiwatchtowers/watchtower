import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class StreamDigestQueriesTests: XCTestCase {

    // MARK: - fetchAll

    func testFetchAllOrdersByCreatedAtDescending() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertStreamDigest(db, source: "gmail", createdAt: "2024-01-01T00:00:00Z")
            try TestDatabase.insertStreamDigest(db, source: "jira", createdAt: "2024-01-03T00:00:00Z")
            try TestDatabase.insertStreamDigest(db, source: "gmail", createdAt: "2024-01-02T00:00:00Z")
        }

        let digests = try db.read { try StreamDigestQueries.fetchAll($0) }

        XCTAssertEqual(digests.map(\.createdAt), [
            "2024-01-03T00:00:00Z",
            "2024-01-02T00:00:00Z",
            "2024-01-01T00:00:00Z"
        ])
    }

    func testFetchAllRespectsLimit() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertStreamDigest(db, createdAt: "2024-01-01T00:00:00Z")
            try TestDatabase.insertStreamDigest(db, createdAt: "2024-01-02T00:00:00Z")
            try TestDatabase.insertStreamDigest(db, createdAt: "2024-01-03T00:00:00Z")
        }

        let digests = try db.read { try StreamDigestQueries.fetchAll($0, limit: 2) }

        XCTAssertEqual(digests.count, 2)
    }

    // MARK: - parsedTopics

    func testParsedTopicsDecodesGmailTopicsWithDecisions() throws {
        let json = """
            [{"title":"Renewal","summary":"Contract renewal thread",
              "ideas":null,
              "decisions":[{"text":"Renew for another year","author":"alice@example.com","ref":"mail:123"}]}]
            """
        let db = try TestDatabase.create()
        let id = try db.write { db in
            try TestDatabase.insertStreamDigest(db, source: "gmail", topicsJSON: json)
        }

        let digest = try db.read { try StreamDigestQueries.fetchAll($0) }.first { $0.id == Int(id) }

        let topics = try XCTUnwrap(digest?.parsedTopics)
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics[0].title, "Renewal")
        XCTAssertEqual(topics[0].decisions?.first?.text, "Renew for another year")
        XCTAssertEqual(topics[0].decisions?.first?.author, "alice@example.com")
        XCTAssertEqual(topics[0].ideas, nil)
    }

    func testParsedTopicsHandlesEmptyJiraTopics() throws {
        let db = try TestDatabase.create()
        let id = try db.write { db in
            try TestDatabase.insertStreamDigest(db, source: "jira", topicsJSON: "[]")
        }

        let digest = try db.read { try StreamDigestQueries.fetchAll($0) }.first { $0.id == Int(id) }

        XCTAssertEqual(digest?.parsedTopics, [])
    }

    func testParsedTopicsReturnsEmptyArrayOnMalformedJSON() throws {
        let db = try TestDatabase.create()
        let id = try db.write { db in
            try TestDatabase.insertStreamDigest(db, topicsJSON: "{not valid json")
        }

        let digest = try db.read { try StreamDigestQueries.fetchAll($0) }.first { $0.id == Int(id) }

        XCTAssertEqual(digest?.parsedTopics, [])
    }

    // MARK: - markRead / unreadCount

    func testMarkReadStampsReadAt() throws {
        let db = try TestDatabase.create()
        let id = try db.write { db in
            try TestDatabase.insertStreamDigest(db)
        }
        XCTAssertNil(try db.read { try StreamDigestQueries.fetchAll($0) }.first?.readAt)

        try db.write { db in try StreamDigestQueries.markRead(db, id: Int(id)) }

        let digest = try db.read { try StreamDigestQueries.fetchAll($0) }.first { $0.id == Int(id) }
        XCTAssertNotNil(digest?.readAt)
        XCTAssertEqual(digest?.isRead, true)
    }

    func testMarkReadIsIdempotentAndNeverOverwritesAnEarlierTimestamp() throws {
        let db = try TestDatabase.create()
        let id = try db.write { db in
            try TestDatabase.insertStreamDigest(db)
        }

        try db.write { db in try StreamDigestQueries.markRead(db, id: Int(id)) }
        let firstReadAt = try db.read { try StreamDigestQueries.fetchAll($0) }.first { $0.id == Int(id) }?.readAt

        try db.write { db in try StreamDigestQueries.markRead(db, id: Int(id)) }
        let secondReadAt = try db.read { try StreamDigestQueries.fetchAll($0) }.first { $0.id == Int(id) }?.readAt

        XCTAssertEqual(firstReadAt, secondReadAt)
    }

    // MARK: - fetchByID

    func testFetchByIDResolvesOneRowAndNilForUnknown() throws {
        let db = try TestDatabase.create()
        let id = try db.write { db -> Int64 in
            _ = try TestDatabase.insertStreamDigest(db, source: "gmail", scope: "other")
            return try TestDatabase.insertStreamDigest(db, source: "jira", scope: "PROJ")
        }

        let digest = try db.read { try StreamDigestQueries.fetchByID($0, id: Int(id)) }

        XCTAssertEqual(digest?.id, Int(id))
        XCTAssertEqual(digest?.source, "jira")
        XCTAssertEqual(digest?.scope, "PROJ")
        XCTAssertNil(try db.read { try StreamDigestQueries.fetchByID($0, id: 9999) })
    }

    func testUnreadCountCountsOnlyUnreadRows() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertStreamDigest(db)
            try TestDatabase.insertStreamDigest(db)
            let readID = try TestDatabase.insertStreamDigest(db)
            try StreamDigestQueries.markRead(db, id: Int(readID))
        }

        let count = try db.read { try StreamDigestQueries.unreadCount($0) }

        XCTAssertEqual(count, 2)
    }
}
