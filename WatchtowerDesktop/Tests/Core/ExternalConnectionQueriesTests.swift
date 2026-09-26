import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ExternalConnectionQueriesTests: XCTestCase {

    private var path: String = ""

    override func tearDownWithError() throws {
        if !path.isEmpty {
            TestDatabase.cleanup(path: path)
        }
        try super.tearDownWithError()
    }

    private func makePool() throws -> DatabasePool {
        let (pool, dbPath) = try TestDatabase.createPool()
        path = dbPath
        return pool
    }

    func testFetchAllRoundTripsSeededRowsOrderedByID() throws {
        let pool = try makePool()
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO external_connections (name, kind, command, args_json, enabled, status, error)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["local-fs", "stdio", "/usr/local/bin/fs-mcp", "[\"--root\",\"/tmp\"]", true, "ok", ""])
            try db.execute(
                sql: """
                    INSERT INTO external_connections (name, kind, url, enabled, status, error)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["remote-http", "http", "https://example.com/mcp", false, "error", "connection refused"])
        }

        let connections = try pool.read { db in try ExternalConnectionQueries.fetchAll(db) }

        XCTAssertEqual(connections.count, 2)
        // Ordered by id ASC — the earlier-inserted row comes first.
        let first = connections[0]
        XCTAssertEqual(first.name, "local-fs")
        XCTAssertEqual(first.kind, "stdio")
        XCTAssertTrue(first.enabled)
        XCTAssertEqual(first.status, "ok")
        XCTAssertEqual(first.error, "")
        XCTAssertTrue(first.isOK)

        let second = connections[1]
        XCTAssertEqual(second.name, "remote-http")
        XCTAssertEqual(second.kind, "http")
        XCTAssertFalse(second.enabled)
        XCTAssertEqual(second.status, "error")
        XCTAssertEqual(second.error, "connection refused")
        XCTAssertFalse(second.isOK)
        XCTAssertTrue(second.id > first.id)
    }

    func testFetchAllEmptyWhenNoConnections() throws {
        let pool = try makePool()
        let connections = try pool.read { db in try ExternalConnectionQueries.fetchAll(db) }
        XCTAssertTrue(connections.isEmpty)
    }
}
