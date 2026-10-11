import XCTest
import GRDB
import WatchtowerCore
import WatchtowerTestSupport

final class OwnerPresenceQueriesTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_791_635_696.789)

    private func row(_ db: Database) throws -> (count: Int, session: Int64?, seenAt: String?) {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM owner_presence") ?? 0
        let row = try Row.fetchOne(db, sql: "SELECT session_id, seen_at FROM owner_presence WHERE id = 1")
        return (count, row?["session_id"], row?["seen_at"])
    }

    private func session(_ db: Database, _ project: Int64, _ title: String) throws -> Int64 {
        try TerminalSessionQueries.create(db, .init(
            projectID: project, kind: .claude, title: title, folderPath: "/tmp/acme",
            claudeSessionID: UUID().uuidString
        )).id
    }

    func testUpsertCreatesTheSingleton() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let first = try session(db, project, "First")
            try OwnerPresenceQueries.upsert(db, sessionID: first, at: at)
            let stored = try row(db)
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.session, first)
            XCTAssertEqual(stored.seenAt, "2026-10-10T12:34:56.789Z")
        }
    }

    func testUpsertOverwritesTheSingleton() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let first = try session(db, project, "First")
            let second = try session(db, project, "Second")
            try OwnerPresenceQueries.upsert(db, sessionID: first, at: at)
            try OwnerPresenceQueries.upsert(db, sessionID: second, at: at.addingTimeInterval(30))
            let stored = try row(db)
            XCTAssertEqual(stored.count, 1, "entering another session overwrites the one row")
            XCTAssertEqual(stored.session, second)
            XCTAssertEqual(stored.seenAt, "2026-10-10T12:35:26.789Z")
        }
    }

    func testANilSessionClearsIt() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let first = try session(db, project, "First")
            try OwnerPresenceQueries.upsert(db, sessionID: first, at: at)
            try OwnerPresenceQueries.upsert(db, sessionID: nil, at: at.addingTimeInterval(5))
            let stored = try row(db)
            XCTAssertEqual(stored.count, 1)
            XCTAssertNil(stored.session, "leaving names no session")
            XCTAssertEqual(stored.seenAt, "2026-10-10T12:35:01.789Z", "and still stamps the write")
        }
    }

    /// The written stamp is the layout Go writes and parses: every valid
    /// instant of the shared fixture comes out as its `stamp`, byte for byte.
    func testTheWrittenStampMatchesTheSharedFixture() throws {
        let fixture = try StampFixture.load()
        XCTAssertTrue(fixture.columns.contains("owner_presence.seen_at"))
        let queue = try TestDatabase.create()
        try queue.write { db in
            for valid in fixture.valid {
                let instant = Date(timeIntervalSince1970: TimeInterval(valid.unixMS) / 1000)
                try OwnerPresenceQueries.upsert(db, sessionID: nil, at: instant)
                XCTAssertEqual(try row(db).seenAt, valid.stamp)
            }
        }
    }

    /// Go's formatter truncates to the millisecond; so does the Desktop's.
    func testTheStampTruncatesSubMilliseconds() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try OwnerPresenceQueries.upsert(db, sessionID: nil, at: Date(timeIntervalSince1970: 1_791_590_400.9997))
            XCTAssertEqual(try row(db).seenAt, "2026-10-10T00:00:00.999Z")
        }
    }
}
