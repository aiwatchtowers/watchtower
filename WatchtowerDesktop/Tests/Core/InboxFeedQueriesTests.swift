import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class InboxFeedQueriesTests: XCTestCase {
    private let now = "2026-10-22T08:00:00Z"

    private func message(
        _ db: Database,
        _ n: Int,
        created: String = "2026-10-22T07:00:00Z",
        status: String = "pending",
        snooze: String = "",
        archived: String? = nil,
        itemClass: String = "actionable",
        readAt: String? = nil
    ) throws -> Int64 {
        let id = try TestDatabase.insertInboxItem(
            db, messageTS: "1700000\(String(format: "%04d", n)).000100", status: status, snoozeUntil: snooze,
            readAt: readAt, archivedAt: archived, itemClass: itemClass)
        try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [created, id])
        return id
    }

    func testDayCardsJoinBriefingAndPlanByDate() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertBriefing(db, date: "2026-10-20")
            try TestDatabase.insertDayPlan(db, planDate: "2026-10-21", generatedAt: "2026-10-21T06:00:00Z")
            try TestDatabase.insertBriefing(db, date: "2026-10-22")
            let plan22 = try TestDatabase.insertDayPlan(db, planDate: "2026-10-22", generatedAt: "2026-10-22T06:00:00Z")
            try TestDatabase.insertDayPlanItem(db, dayPlanID: plan22, title: "A", status: "done")
            try TestDatabase.insertDayPlanItem(db, dayPlanID: plan22, title: "B", status: "pending")
            try TestDatabase.insertDayPlanItem(db, dayPlanID: plan22, title: "C", status: "done")
        }
        let cards = try queue.read { try BriefingQueries.fetchDayCards($0, limit: 30) }
        XCTAssertEqual(cards.map(\.date), ["2026-10-22", "2026-10-21", "2026-10-20"])
        XCTAssertNotNil(cards[0].briefing)
        XCTAssertNotNil(cards[0].plan)
        XCTAssertEqual(cards[0].planDone, 2)
        XCTAssertEqual(cards[0].planTotal, 3)
        XCTAssertNil(cards[1].briefing)
        XCTAssertNotNil(cards[1].plan)
        XCTAssertNotNil(cards[2].briefing)
        XCTAssertNil(cards[2].plan)
        let page = try queue.read { try BriefingQueries.fetchDayCards($0, limit: 1, offset: 1) }
        XCTAssertEqual(page.map(\.date), ["2026-10-21"])
    }

    /// The read says whether a date exists past the page (the Day filter's Show older).
    func testReadTellsWhetherOlderDaysExist() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            for day in ["2026-10-20", "2026-10-21", "2026-10-22"] {
                try TestDatabase.insertBriefing(db, date: day)
            }
        }
        let nowUTC = "2026-10-22T08:00:00Z"
        let page = try queue.read { try InboxFeedQueries.read($0, nowUTC: nowUTC, dayLimit: 2) }
        XCTAssertEqual(page.days.map(\.date), ["2026-10-22", "2026-10-21"])
        XCTAssertTrue(page.hasOlderDays)
        let all = try queue.read { try InboxFeedQueries.read($0, nowUTC: nowUTC, dayLimit: 3) }
        XCTAssertEqual(all.days.count, 3)
        XCTAssertFalse(all.hasOlderDays)
    }

    func testMessagesReadIsCappedAndOnePerRow() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            for n in 0..<250 {
                _ = try message(db, n, created: String(format: "2026-10-21T%02d:%02d:00Z", n / 60 % 24, n % 60))
            }
            _ = try message(db, 300, status: "resolved")
            _ = try message(db, 301, snooze: "2026-10-23T08:00:00Z")
            _ = try message(db, 302, archived: "2026-10-22T01:00:00Z")
            _ = try message(db, 303, itemClass: "ambient")
            let folded = try message(db, 304, created: "2026-10-22T07:30:00Z")
            let entries = ["a", "b", "c"].enumerated().map {
                #"{"ts":"\#($0.offset)","sender":"U1","trigger":"mention","text":"\#($0.element)"}"#
            }
            try db.execute(sql: """
                UPDATE inbox_items SET mentions = ?, mentioned_at = '2026-10-22T07:45:00Z' WHERE id = ?
                """, arguments: ["[" + entries.joined(separator: ",") + "]", folded])
        }
        let rows = try queue.read { try InboxQueries.fetchOpenMessages($0, nowUTC: now) }
        XCTAssertEqual(rows.count, 200)
        XCTAssertTrue(rows[0].item.isAccumulated)
        XCTAssertEqual(rows[0].item.mentionList.count, 3)
        XCTAssertEqual(rows.filter { $0.item.isAccumulated }.count, 1, "one row for the folded channel item")
        XCTAssertEqual(rows.map(\.stamp), rows.map(\.stamp).sorted(by: >), "newest first")
        let ids = Set(rows.map(\.item.id))
        let hiddenIDs = try queue.read { db in
            try Int.fetchAll(db, sql: "SELECT id FROM inbox_items WHERE message_ts LIKE '%030_.000100'")
        }
        XCTAssertEqual(hiddenIDs.count, 5)
        XCTAssertEqual(ids.intersection(hiddenIDs).count, 1, "only the folded row (304) of the n03xx rows shows")
    }

    func testMarkMessageReadWritesOnlyReadAt() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try message($0, 1) }
        let dump = {
            try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id]) }
        }
        let before = try XCTUnwrap(try dump())
        try queue.write { try InboxQueries.markRead($0, id: Int(id)) }
        let after = try XCTUnwrap(try dump())
        XCTAssertNotNil(after["read_at"] as String?)
        for column in after.columnNames where column != "read_at" {
            XCTAssertEqual(after[column] as DatabaseValue, before[column] as DatabaseValue, column)
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE inbox_items SET read_at = '2026-10-01T00:00:00Z' WHERE id = ?", arguments: [id])
            try InboxQueries.markRead(db, id: Int(id))
        }
        XCTAssertEqual(try XCTUnwrap(try dump())["read_at"] as String?, "2026-10-01T00:00:00Z")
    }

    func testTrackCardsCountUnreadEventsAndExcludeDismissed() throws {
        let queue = try TestDatabase.create()
        let ids = try queue.write { db -> (Int64, Int64) in
            let custom = try TestDatabase.insertTrack(db, text: "Watch the launch")
            let dismissed = try TestDatabase.insertTrack(db, text: "Gone")
            try db.execute(sql: """
                UPDATE tracks SET dismissed_at = '2026-10-20T00:00:00Z', updated_at = '2026-10-01T00:00:00Z' WHERE id = ?
                """, arguments: [dismissed])
            try db.execute(sql: "UPDATE tracks SET updated_at = '2026-10-10T00:00:00Z' WHERE id = ?", arguments: [custom])
            let events: [(String, String, String?)] = [
                ("old", "2026-10-11T00:00:00Z", "2026-10-12T00:00:00Z"),
                ("new1", "2026-10-20T00:00:00Z", nil),
                ("new2", "2026-10-21T00:00:00Z", nil)
            ]
            for (summary, created, read) in events {
                try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at, read_at) VALUES (?, ?, ?, ?)",
                               arguments: [custom, summary, created, read])
            }
            return (custom, dismissed)
        }
        let cards = try queue.read { try TrackQueries.fetchInboxCards($0) }
        XCTAssertEqual(cards.map(\.track.id), [Int(ids.0)])
        XCTAssertEqual(cards[0].newEventCount, 2)
        XCTAssertEqual(cards[0].lastEventAt, AutomationDates.parse("2026-10-21T00:00:00Z"))
        XCTAssertTrue(cards[0].isUnread)
    }

    func testMarkAllEventsReadTouchesOnlyThatTrack() throws {
        let queue = try TestDatabase.create()
        let (a, b) = try queue.write { db -> (Int64, Int64) in
            let a = try TestDatabase.insertTrack(db)
            let b = try TestDatabase.insertTrack(db)
            for track in [a, a, b] {
                try db.execute(sql: "INSERT INTO track_events (track_id, summary) VALUES (?, 's')", arguments: [track])
            }
            return (a, b)
        }
        try queue.write { try TrackEventQueries.markAllRead($0, trackId: Int(a)) }
        XCTAssertEqual(try queue.read { try TrackEventQueries.unreadCount($0, trackId: Int(a)) }, 0)
        XCTAssertEqual(try queue.read { try TrackEventQueries.unreadCount($0, trackId: Int(b)) }, 1)
    }

    func testInboxRegistryHidesMergedOnly() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertIdea(db, kind: "idea", title: "I", status: "proposed", updatedAt: "2026-10-20T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "note", title: "N", status: "active", updatedAt: "2026-10-21T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "decision", title: "D", status: "active", updatedAt: "2026-10-19T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "idea", title: "M", status: "merged", updatedAt: "2026-10-22T00:00:00Z")
            try TestDatabase.insertIdea(db, kind: "idea", title: "R", status: "rejected", updatedAt: "2026-10-18T00:00:00Z")
        }
        let titles = try queue.read { try IdeaQueries.fetchInboxRegistry($0) }.map(\.title)
        XCTAssertEqual(titles, ["N", "I", "D", "R"])
    }

    func testBadgeCountsDecisionsUnreadMessagesLatestUnreadDayAndDueReminders() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, status: "pending")
            try TestDatabase.insertIdea(db, kind: "idea", status: "proposed")
            try TestDatabase.insertIdea(db, kind: "decision", status: "proposed")
            _ = try self.message(db, 1)
            _ = try self.message(db, 2)
            _ = try self.message(db, 3, readAt: "2026-10-22T07:30:00Z")
            try TestDatabase.insertBriefing(db, date: "2026-10-20")
            try TestDatabase.insertBriefing(db, date: "2026-10-21")
            try db.execute(sql: "UPDATE briefings SET created_at = date || 'T05:00:00Z'")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
            let automation = try TestDatabase.insertAutomation(db, slug: "s", name: "S")
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            for _ in 0..<3 { _ = try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run) }
            _ = try TestDatabase.insertTrack(db)
            _ = try TestDatabase.insertTrack(db)
            try db.execute(sql: "UPDATE tracks SET read_at = NULL, has_updates = 1")
        }
        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: self.now) }
        // 1 proposal + 1 proposed idea (a decision never counts) + 2 unread messages
        // + the latest briefing + 1 due reminder; outputs and tracks are dots only.
        XCTAssertEqual(badge, 6)

        // + a built-in's failed move (C2); a move that is done counts nothing.
        try await pool.write { db in
            try self.builtinMigration(db, "morning-brief", status: "failed")
            try self.builtinMigration(db, "done-one", status: "done")
        }
        let withNotice = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: self.now) }
        XCTAssertEqual(withNotice, 7)
    }

    private func builtinMigration(_ db: Database, _ id: String, status: String) throws {
        try db.execute(sql: """
            INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at)
            VALUES (?, ?, ?, 1, '2026-10-22T07:00:00Z')
            """, arguments: [id, status, status == "failed" ? "config unreadable" : ""])
    }

    func testReadFillsBuiltinNoticesInTheSameRead() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try self.builtinMigration(db, "morning-brief", status: "failed")
            try self.builtinMigration(db, "done-one", status: "done")
        }
        let snapshot = try await pool.read { try InboxFeedQueries.read($0, nowUTC: self.now, dayLimit: 30) }
        XCTAssertEqual(snapshot.builtinNotices.map(\.builtinID), ["morning-brief"])
        XCTAssertEqual(snapshot.builtinNotices.first?.error, "config unreadable")

        try await pool.write { db in try db.execute(sql: "DROP TABLE builtin_migrations") }
        let older = try await pool.read { try InboxFeedQueries.read($0, nowUTC: self.now, dayLimit: 30) }
        XCTAssertEqual(older.builtinNotices, [], "a schema before the table has none")
    }

    func testBadgeOnASchemaWithoutTheNewTables() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, status: "pending")
            try TestDatabase.insertBriefing(db, date: "2026-10-21")
            try db.execute(sql: "DROP TABLE inbox_items")
            try db.execute(sql: "DROP TABLE ideas")
            try db.execute(sql: "DROP TABLE tracks")
        }
        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: self.now) }
        XCTAssertEqual(badge, 2, "the proposal and the unread briefing; the missing tables count 0")
        let snapshot = try await pool.read {
            try InboxFeedQueries.read($0, nowUTC: self.now, dayLimit: 30)
        }
        XCTAssertEqual(snapshot.proposals.count, 1)
        XCTAssertEqual(snapshot.days.count, 1)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertTrue(snapshot.ideas.isEmpty)
    }

    func testReadAssemblesEverySource() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, status: "pending")
            try TestDatabase.insertIdea(db, kind: "idea")
            _ = try self.message(db, 1)
            try TestDatabase.insertBriefing(db, date: "2026-10-22")
            _ = try TestDatabase.insertTrack(db)
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C1@1','x','2000-01-01T00:00:00Z','pending')
                """)
        }
        let snapshot = try queue.read { try InboxFeedQueries.read($0, nowUTC: now, dayLimit: 30) }
        XCTAssertEqual(snapshot.proposals.count, 1)
        XCTAssertEqual(snapshot.ideas.count, 1)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.days.count, 1)
        XCTAssertEqual(snapshot.tracks.count, 1)
        XCTAssertEqual(snapshot.reminders.count, 1)
    }
}
