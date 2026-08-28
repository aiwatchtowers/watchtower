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

    /// Bypasses every writer's JSON marshalling to plant a corrupt row —
    /// unreachable through the app, but the read side must tolerate it.
    private func corruptTags(_ db: Database, id: Int) throws {
        try db.execute(sql: "UPDATE targets SET tags = 'not json' WHERE id = ?", arguments: [id])
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

    func testFetchAll_TagFilter_ToleratesMalformedTagsRow() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let badID = try self.createTarget(db, text: "corrupt")
            try self.corruptTags(db, id: badID)
            _ = try self.createTarget(db, text: "good", tags: #"["ops"]"#)
        }

        let results = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(tag: "ops"))
        }

        XCTAssertEqual(results.map(\.text), ["good"], "one bad row must not abort the whole query")
    }

    // MARK: - addTag

    func testAddTag_AppendsToExistingTags() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["infra"]"#)
        }

        let changed = try queue.write { db in
            try TargetQueries.addTag(db, id: id, tag: "ops")
        }

        XCTAssertTrue(changed)
        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.decodedTags, ["infra", "ops"])
    }

    func testAddTag_ReadsFreshRowNotCallerSnapshot() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["a"]"#)
        }
        // Simulate a concurrent writer (daemon/CLI) landing after the UI snapshot.
        try queue.write { db in
            try db.execute(sql: #"UPDATE targets SET tags = '["a","b"]' WHERE id = ?"#, arguments: [id])
        }

        try queue.write { db in
            try TargetQueries.addTag(db, id: id, tag: "c")
        }

        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.decodedTags, ["a", "b", "c"], "the concurrently added tag must survive")
    }

    func testAddTag_DuplicateIsNoOp() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["ops"]"#)
        }

        let changed = try queue.write { db in
            try TargetQueries.addTag(db, id: id, tag: "ops")
        }

        XCTAssertFalse(changed, "duplicate add reports no change")
        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.decodedTags, ["ops"])
    }

    func testAddTag_BumpsUpdatedAt() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target")
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE targets SET updated_at = '2000-01-01T00:00:00Z' WHERE id = ?", arguments: [id])
        }

        try queue.write { db in
            try TargetQueries.addTag(db, id: id, tag: "ops")
        }

        let updatedAt = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM targets WHERE id = ?", arguments: [id])
        }
        XCTAssertNotEqual(updatedAt, "2000-01-01T00:00:00Z")
    }

    func testAddTag_MalformedTagsColumn_ThrowsAndLeavesRowUntouched() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            let id = try self.createTarget(db, text: "target")
            try self.corruptTags(db, id: id)
            return id
        }

        XCTAssertThrowsError(try queue.write { db in
            try TargetQueries.addTag(db, id: id, tag: "ops")
        }, "an undecodable column must throw, never be silently replaced")

        let raw = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT tags FROM targets WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(raw, "not json")
    }

    // MARK: - removeTag

    func testRemoveTag_RemovesOnlyThatTag() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["infra","ops"]"#)
        }

        let changed = try queue.write { db in
            try TargetQueries.removeTag(db, id: id, tag: "infra")
        }

        XCTAssertTrue(changed)
        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.decodedTags, ["ops"])
    }

    func testRemoveTag_LastTag_LeavesEmptyArray() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["ops"]"#)
        }

        try queue.write { db in
            try TargetQueries.removeTag(db, id: id, tag: "ops")
        }

        let raw = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT tags FROM targets WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(raw, "[]")
    }

    func testRemoveTag_AbsentTag_IsNoOp() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try self.createTarget(db, text: "target", tags: #"["ops"]"#)
        }

        let changed = try queue.write { db in
            try TargetQueries.removeTag(db, id: id, tag: "infra")
        }

        XCTAssertFalse(changed, "absent-tag removal reports no change")
        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.decodedTags, ["ops"])
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

    func testFetchDistinctTags_SkipsEmptyStringTag() throws {
        // `watchtower targets update --tags ""` historically wrote `[""]`;
        // such rows must not surface a blank filter-menu entry.
        let queue = try TestDatabase.create()
        try queue.write { db in
            _ = try self.createTarget(db, text: "cleared the wrong way", tags: #"[""]"#)
            _ = try self.createTarget(db, text: "tagged", tags: #"["ops"]"#)
        }

        let tags = try queue.read { db in try TargetQueries.fetchDistinctTags(db) }

        XCTAssertEqual(tags, ["ops"])
    }

    func testFetchDistinctTags_ToleratesMalformedTagsRow() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let badID = try self.createTarget(db, text: "corrupt")
            try self.corruptTags(db, id: badID)
            _ = try self.createTarget(db, text: "good", tags: #"["ops"]"#)
        }

        let tags = try queue.read { db in try TargetQueries.fetchDistinctTags(db) }

        XCTAssertEqual(tags, ["ops"], "one bad row must not abort the whole query")
    }
}
