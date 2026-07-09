import GRDB
import XCTest

@testable import WatchtowerDesktop

final class FeedItemQueriesTests: XCTestCase {
    var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertWorkspace(db)
            // Calendar fixtures (FK: calendar_events → calendar_calendars).
            try db.execute(sql: "INSERT INTO calendar_calendars (id, name) VALUES ('cal1', 'Test')")
            try db.execute(sql: """
                INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
                VALUES ('ev1', 'cal1', 'Standup', '2026-07-09T12:10:00Z', '2026-07-09T12:25:00Z')
                """)
        }
    }

    private func insertSituationRow(_ db: Database, id: Int, title: String) throws {
        try db.execute(sql: """
            INSERT INTO situations (id, title, priority, status, updated_at)
            VALUES (?, ?, 'high', 'open', '2026-07-09T09:00:00Z')
            """, arguments: [id, title])
    }

    func test_fetchFeed_ordersByEventTsDescAndJoinsEachType() throws {
        try dbQueue.write { db in
            try insertSituationRow(db, id: 1, title: "release blocked")
            try db.execute(sql: """
                INSERT INTO briefings (id, user_id, date, created_at)
                VALUES (5, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')
                """)
            try TestDatabase.insertMeetingRecap(db, eventID: "ev1", createdAt: "2026-07-09T11:00:00Z")
            try db.execute(sql: """
                INSERT INTO day_plans (id, user_id, plan_date, status, generated_at, created_at, updated_at)
                VALUES (3, 'U1', '2026-07-09', 'active', '2026-07-09T06:00:00Z', '2026-07-09T06:00:00Z', '2026-07-09T06:00:00Z')
                """)
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "meeting", sourceID: "ev1", eventTs: "2026-07-09T12:10:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "briefing", sourceID: "5", eventTs: "2026-07-09T07:00:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "meeting_recap", sourceID: "ev1", eventTs: "2026-07-09T11:00:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "day_plan", sourceID: "3", eventTs: "2026-07-09T06:00:00Z")
        }
        let entries = try dbQueue.read { db in
            try FeedItemQueries.fetchFeed(db, limit: 50).entries
        }
        XCTAssertEqual(entries.map(\.item.itemTypeRaw),
                       ["meeting", "meeting_recap", "situation", "briefing", "day_plan"])
        guard case .situation(let s) = entries[2].content else { return XCTFail("expected situation") }
        XCTAssertEqual(s.title, "release blocked")
        guard case .meeting(let event, _) = entries[0].content else { return XCTFail("expected meeting") }
        XCTAssertEqual(event.title, "Standup")
        guard case .meetingRecap(let recap, let recapEvent) = entries[1].content else { return XCTFail("expected recap") }
        XCTAssertEqual(recap.parsed?.actionItems, ["ship it"])
        XCTAssertEqual(recapEvent?.id, "ev1")
    }

    func test_fetchFeed_dropsEntriesWithMissingSource() throws {
        try dbQueue.write { db in
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "404", eventTs: "2026-07-09T09:00:00Z")
        }
        let entries = try dbQueue.read { db in
            try FeedItemQueries.fetchFeed(db, limit: 50).entries
        }
        XCTAssertTrue(entries.isEmpty)
    }

    func test_fetchFeed_filters() throws {
        try dbQueue.write { db in
            try insertSituationRow(db, id: 1, title: "low importance")
            try db.execute(sql: "UPDATE situations SET priority = 'low' WHERE id = 1")
            try insertSituationRow(db, id: 2, title: "hidden one")
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z", importance: 30)
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "2", eventTs: "2026-07-09T10:00:00Z", importance: 90, hiddenAt: "2026-07-09T10:30:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "meeting", sourceID: "ev1", eventTs: "2026-07-09T12:10:00Z", importance: 70)
        }
        // Default: hidden excluded.
        var entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, limit: 50).entries }
        XCTAssertEqual(entries.count, 2)
        // showHidden reveals the hidden situation.
        var filter = FeedItemQueries.Filter()
        filter.showHidden = true
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50).entries }
        XCTAssertEqual(entries.count, 3)
        // importantOnly keeps >= 70 only.
        filter = FeedItemQueries.Filter()
        filter.importantOnly = true
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50).entries }
        XCTAssertEqual(entries.map(\.item.itemTypeRaw), ["meeting"])
        // Type filter.
        filter = FeedItemQueries.Filter()
        filter.types = [.situation]
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50).entries }
        XCTAssertEqual(entries.map(\.item.sourceID), ["1"])
        // Empty type set → empty feed, not a SQL error.
        filter.types = []
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50).entries }
        XCTAssertTrue(entries.isEmpty)
    }

    /// Calendar sync hard-deletes cancelled events, so a `meeting` (or any)
    /// feed row can be orphaned — the old OFFSET/LIMIT scheme dropped orphans
    /// AFTER the SQL page, so `offset = entries.count` undercounted and the
    /// next page re-fetched (and duplicated) rows already seen. The keyset
    /// cursor tracks the last RAW row regardless of whether it survived.
    func test_fetchFeed_keysetPaginationSkipsDroppedRowsWithoutDuplicates() throws {
        try dbQueue.write { db in
            try insertSituationRow(db, id: 1, title: "oldest")
            try insertSituationRow(db, id: 3, title: "newest")
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T08:00:00Z")
            // Orphan: no situation row with id 999 — dropped by the content join.
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "999", eventTs: "2026-07-09T09:00:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "3", eventTs: "2026-07-09T10:00:00Z")
        }
        // Raw SQL page 1 (DESC): [newest(3), orphan(999)] — orphan drops, so
        // only 1 entry survives even though the SQL LIMIT was 2.
        let page1 = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, limit: 2) }
        XCTAssertEqual(page1.entries.count, 1)
        XCTAssertNotNil(page1.nextCursor, "SQL returned a full page (2 raw rows), so there may be more")

        let page2 = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, limit: 2, before: page1.nextCursor) }
        XCTAssertEqual(page2.entries.count, 1)
        XCTAssertNil(page2.nextCursor, "SQL returned fewer rows than the limit — exhausted")

        let allIDs = (page1.entries + page2.entries).map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "no duplicate feed-item ids across pages")
        let survivingSituationIDs = (page1.entries + page2.entries).compactMap { entry -> Int? in
            guard case .situation(let s) = entry.content else { return nil }
            return s.id
        }
        XCTAssertEqual(Set(survivingSituationIDs), [1, 3], "every surviving entry appears exactly once")
    }

    func test_hide_and_markSeen_writeState() throws {
        var itemID: Int64 = 0
        try dbQueue.write { db in
            try self.insertSituationRow(db, id: 1, title: "s")
            itemID = try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z")
        }
        try dbQueue.write { db in
            try FeedItemQueries.hide(db, id: itemID)
            try FeedItemQueries.markSeen(db, id: itemID)
        }
        let (hidden, seen) = try dbQueue.read { db -> (String?, String?) in
            let row = try Row.fetchOne(db, sql: "SELECT hidden_at, seen_at FROM feed_items WHERE id = ?", arguments: [itemID])!
            return (row["hidden_at"], row["seen_at"])
        }
        XCTAssertNotNil(hidden)
        XCTAssertNotNil(seen)
        // markSeen is first-write-wins; a later call must not move the timestamp.
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE feed_items SET seen_at = '2020-01-01T00:00:00Z' WHERE id = ?", arguments: [itemID])
            try FeedItemQueries.markSeen(db, id: itemID)
        }
        let seenAfter = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT seen_at FROM feed_items WHERE id = ?", arguments: [itemID])
        }
        XCTAssertEqual(seenAfter, "2020-01-01T00:00:00Z")
        // unhide clears hidden_at.
        try dbQueue.write { db in try FeedItemQueries.unhide(db, id: itemID) }
        let hiddenAfter = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT hidden_at FROM feed_items WHERE id = ?", arguments: [itemID])
        }
        XCTAssertNil(hiddenAfter)
    }
}
