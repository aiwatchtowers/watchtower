import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class CatchUpViewModelTests: XCTestCase {
    func testParsesResultJSON() throws {
        let json = """
        {"tldr":"Caught up.","truncated":true,
         "counts":{"digests":{"included":1,"total":3},"tracks":{"included":0,"total":0},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":3,"total_included":1},
         "stories":[{"title":"S","narrative":"N","priority":"high","needs_you":true,
                     "refs":[{"area":"digests","id":1,"label":"x"}]}],
         "sections":[{"area":"digests","total":3,"included":1,
                      "items":[{"id":1,"title":"t","snippet":"s"}]}]}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.tldr, "Caught up.")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stories.count, 1)
        XCTAssertEqual(result.stories[0].priority, "high")
        XCTAssertEqual(result.sections.first?.items.first?.id, 1)
        XCTAssertEqual(result.counts.totalUnread, 3)
    }

    func testSnapshotIDsPerArea() throws {
        let json = """
        {"tldr":"","truncated":false,
         "counts":{"digests":{"included":2,"total":2},"tracks":{"included":1,"total":1},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":3,"total_included":3},
         "stories":[],
         "sections":[{"area":"digests","total":2,"included":2,
                      "items":[{"id":7,"title":"a","snippet":""},{"id":8,"title":"b","snippet":""}]},
                     {"area":"tracks","total":1,"included":1,
                      "items":[{"id":42,"title":"c","snippet":""}]}]}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.ids(for: "digests"), [7, 8])
        XCTAssertEqual(result.ids(for: "tracks"), [42])
        XCTAssertEqual(result.ids(for: "inbox"), [])
    }

    // MARK: - Decode tolerance (null / missing array fields)

    /// Explicit null on stories/sections (and nested items/refs) must decode to empty arrays, not throw.
    func testDecodesNullArraysAsEmpty() throws {
        let json = """
        {"tldr":"x","truncated":false,
         "counts":{"digests":{"included":0,"total":0},"tracks":{"included":0,"total":0},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":0,"total_included":0},
         "stories":null,"sections":null}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.stories.isEmpty)
        XCTAssertTrue(result.sections.isEmpty)
    }

    /// Missing stories/sections keys (and nested items/refs) must decode to empty arrays, not throw.
    func testDecodesMissingArrayKeysAsEmpty() throws {
        let json = """
        {"tldr":"x","truncated":false,
         "counts":{"digests":{"included":0,"total":0},"tracks":{"included":0,"total":0},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":0,"total_included":0}}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.stories.isEmpty)
        XCTAssertTrue(result.sections.isEmpty)

        // A story with null refs and a section with null items also tolerate the absence.
        let nested = """
        {"tldr":"x","truncated":false,
         "counts":{"digests":{"included":1,"total":1},"tracks":{"included":0,"total":0},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":1,"total_included":1},
         "stories":[{"title":"S","narrative":"N","priority":"high","needs_you":true}],
         "sections":[{"area":"digests","total":1,"included":1}]}
        """
        let nestedResult = try JSONDecoder().decode(CatchUpResult.self, from: Data(nested.utf8))
        XCTAssertEqual(nestedResult.stories.first?.refs.count, 0)
        XCTAssertEqual(nestedResult.sections.first?.items.count, 0)
    }

    // MARK: - Snapshot clearing (real DB)

    /// markSectionRead must clear exactly the snapshot IDs for that area and leave
    /// non-snapshot rows (including rows that arrived after the snapshot) unread.
    func testMarkSectionReadClearsOnlySnapshotIDs() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let ids = try await pool.write { db -> (snap: Int, other: Int) in
            let snap = try Self.insertDigest(db)
            let other = try Self.insertDigest(db)
            return (snap, other)
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.result = Self.makeResult(sections: [Self.section(area: "digests", ids: [ids.snap])])

        await vm.markSectionRead("digests")

        let unread = try await pool.read { try Self.unreadDigestIDs($0) }
        XCTAssertEqual(unread, [ids.other], "only the non-snapshot digest stays unread")
        // The cleared section drops out of the in-memory result.
        XCTAssertTrue(vm.result?.sections.contains { $0.area == "digests" } == false)
    }

    /// markAllRead clears the snapshot IDs across every area, leaving non-snapshot rows untouched.
    func testMarkAllReadClearsSnapshotAcrossAreas() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let seeded = try await pool.write { db -> Seeded in
            Seeded(
                digSnap: try Self.insertDigest(db),
                digOther: try Self.insertDigest(db),
                trkSnap: try Self.insertTrack(db),
                inbSnap: try Self.insertInbox(db),
                brfSnap: try Self.insertBriefing(db)
            )
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.result = Self.makeResult(sections: [
            Self.section(area: "digests", ids: [seeded.digSnap]),
            Self.section(area: "tracks", ids: [seeded.trkSnap]),
            Self.section(area: "inbox", ids: [seeded.inbSnap]),
            Self.section(area: "briefings", ids: [seeded.brfSnap])
        ])

        await vm.markAllRead()

        try await pool.read { db in
            XCTAssertEqual(try Self.unreadDigestIDs(db), [seeded.digOther], "non-snapshot digest stays unread")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE read_at IS NULL"), 0)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items WHERE read_at IS NULL OR read_at = ''"), 0
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM briefings WHERE read_at IS NULL"), 0)
        }
        XCTAssertNil(vm.result, "result is cleared after marking everything read")
    }

    // MARK: - Truncation honesty

    /// When a section is truncated (included < total), marking it read must NOT silently
    /// drop the section to "all caught up" — the snapshot is still cleared in the DB, and
    /// the rollup is not left falsely empty (it re-runs to pull the next batch).
    func testMarkSectionReadTruncatedDoesNotFalselyClear() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let ids = try await pool.write { db -> (snap: Int, other: Int) in
            let snap = try Self.insertDigest(db)
            let other = try Self.insertDigest(db)
            return (snap, other)
        }

        let vm = CatchUpViewModel(dbPool: pool)
        // Snapshot shows 1 of 2 → truncated section.
        vm.result = Self.makeResult(
            sections: [Self.section(area: "digests", ids: [ids.snap], total: 2)]
        )

        await vm.markSectionRead("digests")

        // The snapshot ID was still marked read in the DB.
        let unread = try await pool.read { try Self.unreadDigestIDs($0) }
        XCTAssertEqual(unread, [ids.other], "only the snapshot digest was cleared")
        // It did NOT take the clearSectionLocally path that would falsely empty the rollup.
        XCTAssertFalse(
            vm.result?.sections.isEmpty ?? true,
            "truncated section must not be silently dropped to 'all caught up'"
        )
    }

    /// markAllRead on a truncated rollup must not leave result=nil ("all caught up");
    /// the snapshot is still cleared, but the rollup re-runs for the next batch.
    func testMarkAllReadTruncatedDoesNotFalselyClear() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let ids = try await pool.write { db -> (snap: Int, other: Int) in
            let snap = try Self.insertDigest(db)
            let other = try Self.insertDigest(db)
            return (snap, other)
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.result = Self.makeResult(
            sections: [Self.section(area: "digests", ids: [ids.snap], total: 2)],
            truncated: true
        )

        await vm.markAllRead()

        let unread = try await pool.read { try Self.unreadDigestIDs($0) }
        XCTAssertEqual(unread, [ids.other], "snapshot digest was cleared, the other stays unread")
        XCTAssertNotNil(vm.result, "truncated rollup must not be nilled to 'all caught up'")
    }

    // MARK: - Seeding helpers

    private struct Seeded {
        let digSnap: Int
        let digOther: Int
        let trkSnap: Int
        let inbSnap: Int
        let brfSnap: Int
    }

    nonisolated private static func insertDigest(_ db: Database) throws -> Int {
        // Distinct period bounds keep the UNIQUE(channel_id,type,period_from,period_to) happy.
        let next = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests") ?? 0) + 1
        try db.execute(
            sql: """
                INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
                VALUES ('C1', ?, ?, 'channel', 's', NULL)
                """,
            arguments: [Double(next), Double(next + 1)]
        )
        return Int(db.lastInsertedRowID)
    }

    nonisolated private static func insertTrack(_ db: Database) throws -> Int {
        try db.execute(sql: "INSERT INTO tracks (text, has_updates, read_at) VALUES ('t', 1, NULL)")
        return Int(db.lastInsertedRowID)
    }

    nonisolated private static func insertInbox(_ db: Database) throws -> Int {
        try db.execute(sql: """
            INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, read_at)
            VALUES ('C1', '1.0', 'U1', 'mention', 'pending', NULL)
            """)
        return Int(db.lastInsertedRowID)
    }

    nonisolated private static func insertBriefing(_ db: Database) throws -> Int {
        try db.execute(sql: "INSERT INTO briefings (user_id, date, read_at) VALUES ('U1', '2026-06-16', NULL)")
        return Int(db.lastInsertedRowID)
    }

    nonisolated private static func unreadDigestIDs(_ db: Database) throws -> [Int] {
        try Int.fetchAll(db, sql: "SELECT id FROM digests WHERE read_at IS NULL ORDER BY id")
    }

    /// Builds a section. `total` defaults to the snapshot size (not truncated); pass a
    /// larger value to simulate a truncated "+N not shown" section.
    private static func section(area: String, ids: [Int], total: Int? = nil) -> CatchUpSection {
        CatchUpSection(
            area: area, total: total ?? ids.count, included: ids.count,
            items: ids.map { CatchUpSectionItem(id: $0, title: "t", snippet: "") }
        )
    }

    private static func makeResult(sections: [CatchUpSection], truncated: Bool = false) -> CatchUpResult {
        let zero = CatchUpAreaCount(included: 0, total: 0)
        return CatchUpResult(
            tldr: "",
            counts: CatchUpCounts(
                digests: zero, tracks: zero, inbox: zero, briefings: zero,
                totalUnread: 0, totalIncluded: 0
            ),
            truncated: truncated, stories: [], sections: sections
        )
    }
}
