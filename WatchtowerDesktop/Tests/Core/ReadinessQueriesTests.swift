import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class ReadinessQueriesTests: XCTestCase {

    /// Written out here, not read from production, so the mapping itself is
    /// under test.
    private let tables: [(ReadinessFeature, String)] = [
        (.slackSync, "messages"),
        (.digests, "digests"),
        (.streamDigests, "stream_digests"),
        (.tracks, "tracks"),
        (.peopleCards, "people_cards"),
        (.briefing, "briefings"),
        (.dayPlan, "day_plans"),
        (.ideas, "ideas"),
        (.memory, "memory_nodes"),
        (.inbox, "inbox_items"),
        (.knowledgeIndex, "kb_documents"),
        (.calendar, "calendar_events"),
        (.jira, "jira_issues")
    ]

    /// One row with a filler for every NOT NULL column that has no default.
    /// CHECKs and foreign keys are off: the query only asks whether a row
    /// exists, so what is in it doesn't matter.
    private func insertMinimalRow(_ queue: DatabaseQueue, into table: String) throws {
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            var names: [String] = []
            var values: [DatabaseValueConvertible] = []
            // A lone INTEGER primary key is the rowid and fills itself; a
            // composite or TEXT key (`messages`) needs a value.
            let keyCount = columns.filter { ($0["pk"] as Int) > 0 }.count
            for column in columns {
                let type = (column["type"] as String).uppercased()
                let isKey = (column["pk"] as Int) > 0
                let isRowID = isKey && keyCount == 1 && type == "INTEGER"
                let notNull: Bool = column["notnull"]
                let hasDefault = !(column["dflt_value"] as DatabaseValue).isNull
                guard (notNull || isKey) && !hasDefault && !isRowID else { continue }
                names.append(column["name"])
                values.append(type.contains("INT") || type.contains("REAL") ? 1 : "x")
            }
            let sql = names.isEmpty
                ? "INSERT INTO \(table) DEFAULT VALUES"
                : "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))"
            try db.execute(sql: sql, arguments: StatementArguments(values))
        }
    }

    private func insertRun(_ queue: DatabaseQueue, pipeline: String, status: String, startedAt: String, error: String = "") throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO pipeline_runs (pipeline, status, started_at, error_msg) VALUES (?, ?, ?, ?)",
                arguments: [pipeline, status, startedAt, error]
            )
        }
    }

    // MARK: - Content presence

    func testEmptyDatabaseHasNoContent() throws {
        let queue = try TestDatabase.create()
        XCTAssertEqual(try queue.read(ReadinessQueries.contentPresent), [])
    }

    func testEachTableFlipsItsFeature() throws {
        XCTAssertEqual(Set(tables.map(\.0)), Set(ReadinessFeature.allCases))
        XCTAssertEqual(Set(ReadinessQueries.observedTables), Set(tables.map(\.1) + ["pipeline_runs"]))
        for (feature, table) in tables {
            let queue = try TestDatabase.create()
            try insertMinimalRow(queue, into: table)
            XCTAssertEqual(try queue.read(ReadinessQueries.contentPresent), [feature], table)
        }
    }

    func testMissingTableReadsAbsent() throws {
        let queue = try TestDatabase.create()
        try insertMinimalRow(queue, into: "stream_digests")
        try insertMinimalRow(queue, into: "digests")
        try queue.write { db in try db.execute(sql: "DROP TABLE stream_digests") }
        let present = try queue.read(ReadinessQueries.contentPresent)
        XCTAssertFalse(present.contains(.streamDigests))
        XCTAssertEqual(present, [.digests])
    }

    // MARK: - Latest runs

    func testLatestRunsPicksNewestPerPipeline() throws {
        let queue = try TestDatabase.create()
        let iso = ISO8601DateFormatter()
        let now = Date()
        try insertRun(queue, pipeline: "briefing", status: "done", startedAt: iso.string(from: now.addingTimeInterval(-3600)))
        try insertRun(queue, pipeline: "briefing", status: "running", startedAt: iso.string(from: now.addingTimeInterval(-60)))
        try insertRun(queue, pipeline: "digests", status: "error", startedAt: iso.string(from: now), error: "boom")
        let runs = try queue.read(ReadinessQueries.latestRuns)
        XCTAssertEqual(runs["briefing"]?.status, "running")
        XCTAssertEqual(runs["digests"]?.status, "error")
        XCTAssertEqual(runs["digests"]?.errorMessage, "boom")
        XCTAssertEqual(runs.count, 2)
    }

    func testLatestRunsIgnoresUnknownPipelines() throws {
        let queue = try TestDatabase.create()
        try insertRun(queue, pipeline: "custom_tracks", status: "running", startedAt: ISO8601DateFormatter().string(from: Date()))
        XCTAssertNil(try queue.read(ReadinessQueries.latestRuns)["custom_tracks"])
    }

    func testLatestRunsParsesGoTimestamps() throws {
        let queue = try TestDatabase.create()
        let now = Date()
        let whole = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try insertRun(queue, pipeline: "tracks", status: "done", startedAt: whole.string(from: now))
        try insertRun(queue, pipeline: "people", status: "done", startedAt: fractional.string(from: now))
        let runs = try queue.read(ReadinessQueries.latestRuns)
        let tracks = try XCTUnwrap(runs["tracks"]).startedAt
        let people = try XCTUnwrap(runs["people"]).startedAt
        XCTAssertEqual(tracks.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(people.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.01)
    }

    // MARK: - Running backfill rows (#578)

    func testRunningBackfillStartsReadsOnlyRunningRows() throws {
        let queue = try TestDatabase.create()
        XCTAssertEqual(try queue.read(ReadinessQueries.runningBackfillStarts), [])
        try queue.write { db in
            for (account, status) in [(1, "running"), (2, "paused"), (3, "done"), (4, "off")] {
                try db.execute(
                    sql: """
                        INSERT INTO history_backfill (source_kind, account_id, floor_ts, upper_ts, reached_ts,
                            status, started_at, updated_at)
                        VALUES ('slack', ?, 0, 100, 100, ?, '2026-10-15T12:00:00Z', '2026-10-15T12:00:00Z')
                        """,
                    arguments: [account, status])
            }
        }
        let starts = try queue.read(ReadinessQueries.runningBackfillStarts)
        XCTAssertEqual(starts, [try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z"))])
    }

    func testRunningBackfillStartsWithoutTableIsEmpty() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in try db.execute(sql: "DROP TABLE history_backfill") }
        XCTAssertEqual(try queue.read(ReadinessQueries.runningBackfillStarts), [])
    }
}
