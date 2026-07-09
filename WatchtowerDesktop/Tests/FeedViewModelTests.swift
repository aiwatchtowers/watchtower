import GRDB
import XCTest

@testable import WatchtowerDesktop

@MainActor
final class FeedViewModelTests: XCTestCase {
    var dbManager: DatabaseManager!
    var dbPath: String!
    var defaults: UserDefaults!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "FeedViewModelTests"))
        defaults.removePersistentDomain(forName: "FeedViewModelTests")
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: """
                INSERT INTO situations (id, title, priority, status, updated_at)
                VALUES (1, 'story', 'high', 'open', '2026-07-09T09:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO briefings (id, user_id, date, created_at)
                VALUES (5, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')
                """)
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z", importance: 90)
            try TestDatabase.insertFeedItem(db, itemType: "briefing", sourceID: "5", eventTs: "2026-07-09T07:00:00Z", importance: 60)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeVM() -> FeedViewModel {
        FeedViewModel(dbManager: dbManager, defaults: defaults)
    }

    func test_load_populatesEntriesChronologically() {
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.entries.map(\.item.itemTypeRaw), ["situation", "briefing"])
        XCTAssertNil(vm.errorMessage)
    }

    func test_select_marksSeenInDB() throws {
        let vm = makeVM()
        vm.load()
        vm.select(vm.entries[0].id)
        XCTAssertEqual(vm.selectedEntry?.id, vm.entries[0].id)
        let seen = try dbManager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT seen_at FROM feed_items WHERE id = ?", arguments: [vm.entries[0].id])
        }
        XCTAssertNotNil(seen)
    }

    func test_hide_removesEntryWhenHiddenNotShown() throws {
        let vm = makeVM()
        vm.load()
        let target = vm.entries[1]
        vm.hide(target)
        XCTAssertEqual(vm.entries.count, 1)
        vm.showHidden = true
        XCTAssertEqual(vm.entries.count, 2)
    }

    func test_hide_clearsSelectionWhenSelectedEntryHidden() {
        let vm = makeVM()
        vm.load()
        let target = vm.entries[0]
        vm.select(target.id)
        XCTAssertEqual(vm.selectedFeedItemID, target.id)
        vm.hide(target)
        XCTAssertNil(vm.selectedFeedItemID)
        // Hiding a non-selected entry must NOT clear an existing selection.
        let remaining = vm.entries[0]
        vm.select(remaining.id)
        vm.showHidden = true
        if let hiddenEntry = vm.entries.first(where: { $0.id == target.id }) {
            vm.unhide(hiddenEntry)
        } else {
            XCTFail("hidden entry should be visible with showHidden")
        }
        XCTAssertEqual(vm.selectedFeedItemID, remaining.id)
    }

    func test_importantOnly_filters() {
        let vm = makeVM()
        vm.load()
        vm.importantOnly = true
        XCTAssertEqual(vm.entries.map(\.item.itemTypeRaw), ["situation"])
    }

    /// Regression for the OFFSET/LIMIT pagination bug: an orphaned feed row
    /// (source deleted, e.g. a cancelled calendar event) between two surviving
    /// rows must not cause `loadMore()` to re-fetch and duplicate a row already
    /// appended. `pageSize = 1` forces one raw row per fetch so the orphan lands
    /// in its own page.
    func test_loadMore_appendsWithoutDuplicates() throws {
        try dbManager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO situations (id, title, priority, status, updated_at)
                VALUES (2, 'newest', 'high', 'open', '2026-07-09T10:00:00Z')
                """)
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "2", eventTs: "2026-07-09T10:00:00Z", importance: 90)
            // Orphan: no situation row with source id 999 — dropped by the content join,
            // sitting (by event_ts) between the "newest" and "story" situations.
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "999", eventTs: "2026-07-09T08:30:00Z", importance: 90)
        }
        let vm = makeVM()
        vm.pageSize = 1
        vm.load()
        // Loop well past exhaustion — loadMore() no-ops once the cursor is nil.
        for _ in 0..<10 { vm.loadMore() }

        let ids = vm.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate feed-item ids after repeated loadMore")
        XCTAssertEqual(vm.entries.count, 3, "situation(2) + situation(1) + briefing(5) survive; orphan(999) dropped")
    }

    func test_filtersPersistAcrossInstances() {
        let vm = makeVM()
        vm.load()
        vm.importantOnly = true
        vm.toggleType(.briefing) // switch briefings off
        let vm2 = makeVM()
        XCTAssertTrue(vm2.importantOnly)
        XCTAssertFalse(vm2.typeFilter.contains(.briefing))
    }
}
