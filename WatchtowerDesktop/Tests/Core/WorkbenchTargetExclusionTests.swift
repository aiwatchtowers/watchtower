import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// BEHAVIOR PROJ-01 (Desktop side) — a project target lives only on its
/// project's board: it never reaches the Targets tab's list, counts, tag menu,
/// or the chat `@` picker. See docs/inventory/workbench.md.
final class WorkbenchTargetExclusionTests: XCTestCase {

    /// One ordinary target and one project target, identical in every field a
    /// reader filters on (active, overdue, due today, high priority, tagged,
    /// matching text) — so only project_id can explain a difference.
    private func seed(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
        let projectID = db.lastInsertedRowID
        let today = TargetQueries.todayDateString()
        for (text, project) in [("Ship ordinary", nil as Int64?), ("Ship board", projectID)] {
            try db.execute(
                sql: """
                    INSERT INTO targets (text, level, custom_label, period_start, period_end, status,
                        priority, ownership, due_date, tags, source_type, project_id)
                    VALUES (?, 'custom', 'project', ?, ?, 'in_progress', 'high', 'mine', ?, ?, 'chat', ?)
                    """,
                arguments: [text, today, today, "2020-01-01T09:00",
                            project == nil ? #"["ordinary-tag"]"# : #"["board-tag"]"#, project]
            )
        }
    }

    func testProj01_FetchAllNeverReturnsAProjectTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let texts = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(includeDone: true)).map(\.text)
        }
        XCTAssertEqual(texts, ["Ship ordinary"])
    }

    func testProj01_FetchAllTagFilterNeverReturnsAProjectTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let texts = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(tag: "board-tag")).map(\.text)
        }
        XCTAssertEqual(texts, [])
    }

    func testProj01_FetchCountsIgnoreProjectTargets() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let counts = try queue.read { try TargetQueries.fetchCounts($0) }
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.overdue, 1)
        XCTAssertEqual(counts.highPriority, 1)
    }

    func testProj01_DueTodayIgnoresProjectTargets() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try self.seed(db)
            try db.execute(sql: "UPDATE targets SET due_date = ?", arguments: [TargetQueries.todayDateString() + "T23:59"])
        }
        let counts = try queue.read { try TargetQueries.fetchCounts($0) }
        XCTAssertEqual(counts.dueToday, 1)
    }

    func testProj01_DistinctTagsNeverListAProjectTargetsTag() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let tags = try queue.read { try TargetQueries.fetchDistinctTags($0) }
        XCTAssertEqual(tags, ["ordinary-tag"])
    }

    func testProj01_MentionPickerNeverOffersAProjectTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let hits = try queue.read { try ChatEntitySearch.targets($0, query: "ship") }
        XCTAssertEqual(hits.map(\.label), ["Ship ordinary"])
    }

    func testTargetDecodesProjectID() throws {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        let ids = try queue.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets ORDER BY id").map(\.workbenchID)
        }
        XCTAssertNil(ids[0])
        XCTAssertNotNil(ids[1])
    }
}
