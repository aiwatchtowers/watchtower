import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// MARK: - InboxViewModel Action/Awareness Tier Split Tests

final class InboxViewModelPinnedFeedTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> (DatabaseManager, String) {
        try TestDatabase.createDatabaseManager()
    }

    private func insertInboxItem(
        _ pool: DatabasePool,
        messageTS: String,
        status: String = "pending",
        priority: String = "medium",
        itemClass: String = "actionable"
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, snippet, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "C1", messageTS, "U1", "mention",
                    status, priority, itemClass,
                    "Snippet \(messageTS)",
                    "2026-04-23T10:00:00Z",
                    "2026-04-23T10:00:00Z"
                ])
        }
    }

    // MARK: - Action / Awareness Split

    @MainActor
    func testViewModelSplitsActionAndAwareness() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        // One actionable item
        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", priority: "high", itemClass: "actionable")
        // Two awareness items (ambient)
        try insertInboxItem(dbManager.dbPool, messageTS: "2.0", priority: "medium", itemClass: "ambient")
        try insertInboxItem(dbManager.dbPool, messageTS: "3.0", priority: "low", itemClass: "ambient")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.actionItems.count, 1)
        XCTAssertEqual(vm.awarenessItems.count, 2)
    }

    @MainActor
    func testActionItemsAreActuallyActionable() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", itemClass: "actionable")
        try insertInboxItem(dbManager.dbPool, messageTS: "2.0", itemClass: "ambient")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.actionItems.allSatisfy { $0.itemClass == .actionable })
        XCTAssertTrue(vm.awarenessItems.allSatisfy { $0.itemClass == .ambient })
    }

    @MainActor
    func testEmptyDBYieldsEmptyLists() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.actionItems.isEmpty)
        XCTAssertTrue(vm.awarenessItems.isEmpty)
        XCTAssertFalse(vm.hasHighPriorityAction)
    }

    // MARK: - hasHighPriorityAction

    @MainActor
    func testSidebarBadgeReflectsHighPriorityAction() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", priority: "high", itemClass: "actionable")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.hasHighPriorityAction)
    }

    @MainActor
    func testHasHighPriorityActionFalseWhenOnlyMedium() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", priority: "medium", itemClass: "actionable")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertFalse(vm.hasHighPriorityAction)
    }

    // MARK: - loadMore (pagination)

    @MainActor
    func testLoadMoreAppendsToAwareness() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        // Insert 5 awareness items
        for i in 1...5 {
            try insertInboxItem(dbManager.dbPool, messageTS: "\(i).0", itemClass: "ambient")
        }

        let vm = InboxViewModel(dbManager: dbManager)
        vm.feedPageSize = 3
        vm.load()

        XCTAssertEqual(vm.awarenessItems.count, 3)

        vm.loadMore()

        XCTAssertEqual(vm.awarenessItems.count, 5)
    }

    @MainActor
    func testLoadMoreDoesNotDuplicateItems() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        for i in 1...4 {
            try insertInboxItem(dbManager.dbPool, messageTS: "\(i).0", itemClass: "ambient")
        }

        let vm = InboxViewModel(dbManager: dbManager)
        vm.feedPageSize = 2
        vm.load()
        vm.loadMore()

        let ids = vm.awarenessItems.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "No duplicates expected")
    }

    // MARK: - markSeen

    @MainActor
    func testMarkAsSeenOnScroll() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", itemClass: "ambient")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        guard let item = vm.awarenessItems.first else {
            XCTFail("Expected awareness item")
            return
        }
        XCTAssertTrue(item.readAt.isEmpty, "Item should start unread")

        vm.markSeen(item)

        let updated = try dbManager.dbPool.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [item.id])
        }
        XCTAssertFalse(try XCTUnwrap(updated).readAt.isEmpty, "read_at should be set after markSeen")
    }

    @MainActor
    func testMarkSeenIsNoOpIfAlreadyRead() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        let originalReadAt = "2026-04-20T08:00:00Z"
        try dbManager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, read_at, created_at, updated_at)
                VALUES ('C1','5.0','U1','mention','pending','medium','ambient',?,?,?)
                """, arguments: [originalReadAt, "2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }

        let item = try dbManager.dbPool.read {
            try InboxItem.fetchOne($0, sql: "SELECT * FROM inbox_items LIMIT 1")
        }!

        let vm = InboxViewModel(dbManager: dbManager)
        vm.markSeen(item)

        let updated = try dbManager.dbPool.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(try XCTUnwrap(updated).readAt, originalReadAt, "read_at should not change for already-read item")
    }

    // MARK: - submitFeedback

    @MainActor
    func testSubmitFeedbackUpdatesDB() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", itemClass: "ambient")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        guard let item = vm.awarenessItems.first else {
            XCTFail("Expected awareness item")
            return
        }

        vm.submitFeedback(item, rating: -1, reason: "never_show")

        // Check that inbox_learned_rules got a source_mute row
        let ruleCount = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_learned_rules WHERE rule_type = 'source_mute'")
        }
        XCTAssertEqual(ruleCount, 1, "Expected one source_mute rule after never_show feedback")
    }

    @MainActor
    func testSubmitFeedbackTriggersReload() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", itemClass: "ambient")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        let countBefore = vm.awarenessItems.count
        guard let item = vm.awarenessItems.first else {
            XCTFail("Expected awareness item"); return
        }

        vm.submitFeedback(item, rating: 1, reason: "useful")

        // After reload the count should stay consistent (item still pending, feedback doesn't change status)
        XCTAssertEqual(vm.awarenessItems.count, countBefore)
    }

    // MARK: - Secretary card fields surfaced through load()

    @MainActor
    func testLoadSurfacesCardFieldsOnActionItems() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try dbManager.dbPool.write { db in
            try TestDatabase.insertInboxItem(
                db,
                messageTS: "1.0",
                itemClass: "actionable",
                cardStatus: "ready",
                whyMatters: "w",
                threadDigest: "t",
                draftReply: "d"
            )
        }

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        let item = try XCTUnwrap(vm.actionItems.first)
        XCTAssertTrue(item.hasCard)
        XCTAssertEqual(item.whyMatters, "w")
        XCTAssertEqual(item.threadDigest, "t")
        XCTAssertEqual(item.draftReply, "d")
    }

    // MARK: - Backward-compat: allItems still populated

    @MainActor
    func testLegacyAllItemsStillPopulated() throws {
        let (dbManager, path) = try makeDB()
        defer { TestDatabase.cleanup(path: path) }

        try insertInboxItem(dbManager.dbPool, messageTS: "1.0", itemClass: "ambient")
        try insertInboxItem(dbManager.dbPool, messageTS: "2.0", itemClass: "actionable")

        let vm = InboxViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertFalse(vm.allItems.isEmpty, "allItems backward-compat property should still be populated")
    }
}
