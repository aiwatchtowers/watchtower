import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class TargetQueriesTagsTests: XCTestCase {

    private func createTarget(_ db: Database, text: String, tags: String = "[]", status: String = "todo") throws -> Int {
        try TargetQueries.create(
            db,
            text: text,
            level: "day",
            periodStart: "2026-08-24",
            periodEnd: "2026-08-24",
            status: status,
            tags: tags,
            sourceType: "manual",
            sourceID: ""
        )
    }

    // MARK: - fetchAll tag filter

    func testFetchAll_TagFilter_ReturnsOnlyTargetsCarryingTheTag() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            _ = try self.createTarget(db, text: "tagged", tags: #"["infra","ops"]"#)
            _ = try self.createTarget(db, text: "other tag", tags: #"["design"]"#)
            _ = try self.createTarget(db, text: "untagged")
        }

        let results = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(tag: "ops"))
        }

        XCTAssertEqual(results.map(\.text), ["tagged"])
    }

    func testFetchAll_TagFilter_MatchesWholeTagNotSubstring() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            _ = try self.createTarget(db, text: "devops target", tags: #"["devops"]"#)
            _ = try self.createTarget(db, text: "ops target", tags: #"["ops"]"#)
        }

        let results = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(tag: "ops"))
        }

        XCTAssertEqual(results.map(\.text), ["ops target"])
    }

    func testFetchAll_TagFilter_EmptyDatabaseOfTags_ReturnsNothing() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            _ = try self.createTarget(db, text: "untagged one")
            _ = try self.createTarget(db, text: "untagged two")
        }

        let results = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(tag: "ops"))
        }

        XCTAssertTrue(results.isEmpty)
    }

    func testFetchAll_TagFilter_ComposesWithOtherFilters() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            _ = try self.createTarget(db, text: "open tagged", tags: #"["ops"]"#)
            _ = try self.createTarget(db, text: "done tagged", tags: #"["ops"]"#, status: "done")
        }

        let results = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(tag: "ops"))
        }

        XCTAssertEqual(results.map(\.text), ["open tagged"], "default includeDone=false must still apply")
    }

    // MARK: - updateTags

    func testUpdateTags_WritesTagsAsJSONArray() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["old"]"#)
        }

        try queue.write { db in
            try TargetQueries.updateTags(db, id: id, tags: ["infra", "ops"])
        }

        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.decodedTags, ["infra", "ops"])
    }

    func testUpdateTags_EmptyList_ClearsTags() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["old"]"#)
        }

        try queue.write { db in
            try TargetQueries.updateTags(db, id: id, tags: [])
        }

        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.decodedTags, [])
    }

    func testUpdateTags_BumpsUpdatedAt() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target")
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE targets SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?", arguments: [id])
        }

        try queue.write { db in
            try TargetQueries.updateTags(db, id: id, tags: ["ops"])
        }

        let updatedAt = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM targets WHERE id = ?", arguments: [id])
        }
        XCTAssertNotEqual(updatedAt, "2000-01-01T00:00:00Z")
    }

    // MARK: - fetchDistinctTags

    func testFetchDistinctTags_EmptyDatabase_ReturnsEmpty() throws {
        let queue = try TestDatabase.create()

        let tags = try queue.read { db in try TargetQueries.fetchDistinctTags(db) }

        XCTAssertEqual(tags, [])
    }

    func testFetchDistinctTags_OnlyUntaggedTargets_ReturnsEmpty() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            _ = try self.createTarget(db, text: "untagged")
        }

        let tags = try queue.read { db in try TargetQueries.fetchDistinctTags(db) }

        XCTAssertEqual(tags, [])
    }

    func testFetchDistinctTags_DeduplicatesAndSorts() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            _ = try self.createTarget(db, text: "a", tags: #"["ops","infra"]"#)
            _ = try self.createTarget(db, text: "b", tags: #"["ops","Design"]"#)
        }

        let tags = try queue.read { db in try TargetQueries.fetchDistinctTags(db) }

        XCTAssertEqual(tags, ["Design", "infra", "ops"], "unique, case-insensitively sorted")
    }
}
