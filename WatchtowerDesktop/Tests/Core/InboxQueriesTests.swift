import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

// MARK: - InboxQueries Extended Method Tests

final class InboxQueriesTests: XCTestCase {

    // MARK: - fetchActionTier

    func testFetchActionTierReturnsOnlyActionableOrderedByPriority() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // actionable/high, pending → included
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','high','actionable','High',?,?)
            """, arguments: ["2026-04-23T09:00:00Z", "2026-04-23T09:00:00Z"])
            // actionable/low, pending → included
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','2.0','U1','mention','pending','low','actionable','Low',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
            // ambient/high → excluded, even though high priority
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','3.0','U1','mention','pending','high','ambient','Ambient',?,?)
            """, arguments: ["2026-04-23T09:00:00Z", "2026-04-23T09:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchActionTier($0) }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].snippet, "High")
        XCTAssertEqual(items[1].snippet, "Low")
        XCTAssertTrue(items.allSatisfy { $0.itemClass == .actionable })
    }

    func testFetchActionTierExcludesResolvedStatus() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','resolved','high','actionable',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchActionTier($0) }
        XCTAssertTrue(items.isEmpty)
    }

    func testFetchActionTierExcludesArchivedItems() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, archived_at, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','high','actionable',?,?,?)
            """, arguments: ["2026-04-23T12:00:00Z", "2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchActionTier($0) }
        XCTAssertTrue(items.isEmpty)
    }

    func testFetchActionTierOrdersByPriorityThenUpdatedAtDesc() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','high','actionable','Older',?,?)
            """, arguments: ["2026-04-23T09:00:00Z", "2026-04-23T09:00:00Z"])
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','2.0','U1','mention','pending','high','actionable','Newer',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchActionTier($0) }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].snippet, "Newer")
        XCTAssertEqual(items[1].snippet, "Older")
    }

    // MARK: - fetchAwarenessTier

    func testFetchAwarenessTierPaginatesAmbientOnly() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // ambient, pending → included
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium','ambient','Feed item',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
            // actionable → should not appear in awareness tier
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','2.0','U1','mention','pending','high','actionable','Action item',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchAwarenessTier($0, limit: 50, offset: 0) }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].snippet, "Feed item")
    }

    func testFetchAwarenessTierExcludesResolvedDismissedSnoozed() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // pending → included
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium','ambient',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
            // resolved → excluded
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','2.0','U1','mention','resolved','medium','ambient',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
            // dismissed → excluded
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','3.0','U1','mention','dismissed','medium','ambient',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
            // snoozed → excluded
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','4.0','U1','mention','snoozed','medium','ambient',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchAwarenessTier($0, limit: 50, offset: 0) }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].status, "pending")
    }

    func testFetchAwarenessTierExcludesArchivedItems() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, archived_at, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium','ambient',?,?,?)
            """, arguments: ["2026-04-23T12:00:00Z", "2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchAwarenessTier($0, limit: 50, offset: 0) }
        XCTAssertTrue(items.isEmpty)
    }

    func testFetchAwarenessTierPagination() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            for i in 1...5 {
                try db.execute(sql: """
                    INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                        status, priority, item_class, snippet, created_at, updated_at)
                    VALUES ('C1',?,      'U1','mention','pending','medium','ambient',?,?,?)
                """, arguments: ["\(i).0", "Item \(i)",
                                 "2026-04-23T\(String(format: "%02d", i)):00:00Z",
                                 "2026-04-23T\(String(format: "%02d", i)):00:00Z"])
            }
        }
        let page1 = try db.read { try InboxQueries.fetchAwarenessTier($0, limit: 2, offset: 0) }
        let page2 = try db.read { try InboxQueries.fetchAwarenessTier($0, limit: 2, offset: 2) }
        XCTAssertEqual(page1.count, 2)
        XCTAssertEqual(page2.count, 2)
        // Items should not overlap
        let page1IDs = Set(page1.map(\.id))
        let page2IDs = Set(page2.map(\.id))
        XCTAssertTrue(page1IDs.isDisjoint(with: page2IDs))
    }

    func testFetchAwarenessTierOrdersByCreatedAtDesc() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium','ambient','Older',?,?)
            """, arguments: ["2026-04-22T10:00:00Z", "2026-04-22T10:00:00Z"])
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES ('C1','2.0','U1','mention','pending','medium','ambient','Newer',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let items = try db.read { try InboxQueries.fetchAwarenessTier($0, limit: 10, offset: 0) }
        XCTAssertEqual(items[0].snippet, "Newer")
        XCTAssertEqual(items[1].snippet, "Older")
    }

    // MARK: - hasHighPriorityAction

    func testHasHighPriorityActionReturnsTrueWhenExists() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','high','actionable',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let result = try db.read { try InboxQueries.hasHighPriorityAction($0) }
        XCTAssertTrue(result)
    }

    func testHasHighPriorityActionReturnsFalseWhenNone() throws {
        let db = try TestDatabase.create()
        // No items
        let result = try db.read { try InboxQueries.hasHighPriorityAction($0) }
        XCTAssertFalse(result)
    }

    func testHasHighPriorityActionReturnsFalseForMediumPriority() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium','actionable',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let result = try db.read { try InboxQueries.hasHighPriorityAction($0) }
        XCTAssertFalse(result)
    }

    func testHasHighPriorityActionReturnsFalseWhenNotPending() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // high priority but resolved → false
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','resolved','high','actionable',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let result = try db.read { try InboxQueries.hasHighPriorityAction($0) }
        XCTAssertFalse(result)
    }

    func testHasHighPriorityActionReturnsFalseForAmbient() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // high priority, pending, but ambient → false
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','high','ambient',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let result = try db.read { try InboxQueries.hasHighPriorityAction($0) }
        XCTAssertFalse(result)
    }

    // MARK: - markSeen

    func testMarkSeenSetsReadAt() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let id = try db.read { db -> Int64 in
            try Int64.fetchOne(db, sql: "SELECT id FROM inbox_items LIMIT 1") ?? 0
        }
        try db.write { try InboxQueries.markSeen($0, itemID: id) }
        let item = try db.read { try InboxItem.fetchOne($0, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id]) }
        XCTAssertFalse(try XCTUnwrap(item).readAt.isEmpty)
    }

    func testMarkSeenDoesNotOverwriteExistingReadAt() throws {
        let db = try TestDatabase.create()
        let originalReadAt = "2026-04-20T08:00:00Z"
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, read_at, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium',?,?,?)
            """, arguments: [originalReadAt, "2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let id = try db.read { db -> Int64 in
            try Int64.fetchOne(db, sql: "SELECT id FROM inbox_items LIMIT 1") ?? 0
        }
        try db.write { try InboxQueries.markSeen($0, itemID: id) }
        let item = try db.read { try InboxItem.fetchOne($0, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(try XCTUnwrap(item).readAt, originalReadAt)
    }

    func testMarkSeenIsIdempotentForUnread() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','medium',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let id = try db.read { db -> Int64 in
            try Int64.fetchOne(db, sql: "SELECT id FROM inbox_items LIMIT 1") ?? 0
        }
        // Mark seen twice — second call should be a no-op, no crash
        try db.write { try InboxQueries.markSeen($0, itemID: id) }
        let firstReadAt = try db.read { try String.fetchOne($0, sql: "SELECT read_at FROM inbox_items WHERE id = ?", arguments: [id]) ?? "" }
        try db.write { try InboxQueries.markSeen($0, itemID: id) }
        let secondReadAt = try db.read { try String.fetchOne($0, sql: "SELECT read_at FROM inbox_items WHERE id = ?", arguments: [id]) ?? "" }
        XCTAssertEqual(firstReadAt, secondReadAt)
        XCTAssertFalse(firstReadAt.isEmpty)
    }
}
