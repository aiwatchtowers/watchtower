import Foundation
import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// People waiting today, the Inbox badge's people term: the SQL count agrees
/// with `InboxToday` over the fixture shared with Go
/// (`internal/inbox/testdata/from_today.json`).
final class InboxPeopleTodayTests: XCTestCase {
    func testOpenMessageCountMatchesInboxToday() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        for item in try InboxTodayFixture.cases() {
            let now = try InboxTodayFixture.date(item.now)
            let since = InboxToday.sinceUTC(now: now, calendar: try InboxTodayFixture.calendar(item.tz))
            let count = try await pool.write { db -> Int in
                let id = try TestDatabase.insertInboxItem(db)
                // `mentioned_at` is NOT NULL: none is ''.
                try db.execute(sql: "UPDATE inbox_items SET created_at = ?, mentioned_at = ? WHERE id = ?",
                               arguments: [item.createdAt, item.mentionedAt ?? "", id])
                let count = try InboxQueries.openMessageCount(db, nowUTC: item.now, sinceUTC: since)
                try db.execute(sql: "DELETE FROM inbox_items WHERE id = ?", arguments: [id])
                return count
            }
            XCTAssertEqual(count, item.expected ? 1 : 0, item.name)
        }
    }

    func testTurnedOffWaitingForMeCountsNoPeople() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let now = "2026-11-11T12:00:00Z"
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            try TestDatabase.insertAgentAction(db, status: "pending")
            let id = try TestDatabase.insertInboxItem(db)
            try db.execute(sql: "UPDATE inbox_items SET created_at = '2026-11-11T09:00:00Z' WHERE id = ?", arguments: [id])
        }
        let utc = try InboxTodayFixture.calendar("UTC")

        let on = try await pool.read { try InboxFolderMenuSnapshot.read($0, nowUTC: now, calendar: utc) }
        XCTAssertEqual(on.peopleWaitingToday, 1)
        XCTAssertEqual(on.badge, 2, "the proposal + the person waiting today")

        let off = try await pool.read {
            try InboxFolderMenuSnapshot.read(
                $0, nowUTC: now, disabledFeatures: [InboxFolderQueries.waitingForMeFeatureID], calendar: utc)
        }
        XCTAssertEqual(off.peopleWaitingToday, 0, "Waiting for me turned off counts no people")
        XCTAssertEqual(off.approvalsCount, 1)
        XCTAssertEqual(off.badge, 1, "the approvals only")
    }

    func testNextMidnight() throws {
        let kyiv = try InboxTodayFixture.calendar("Europe/Kyiv")
        XCTAssertEqual(InboxToday.nextMidnight(after: try InboxTodayFixture.date("2026-11-11T08:00:00Z"), calendar: kyiv),
                       try InboxTodayFixture.date("2026-11-11T22:00:00Z"))
        XCTAssertEqual(InboxToday.nextMidnight(after: try InboxTodayFixture.date("2026-11-10T22:00:00Z"), calendar: kyiv),
                       try InboxTodayFixture.date("2026-11-11T22:00:00Z"), "at midnight: the next one")

        let newYork = try InboxTodayFixture.calendar("America/New_York")
        XCTAssertEqual(
            InboxToday.nextMidnight(after: try InboxTodayFixture.date("2026-03-07T17:00:00Z"), calendar: newYork),
            try InboxTodayFixture.date("2026-03-08T05:00:00Z"), "the DST day starts at midnight EST")
        XCTAssertEqual(
            InboxToday.nextMidnight(after: try InboxTodayFixture.date("2026-03-08T15:00:00Z"), calendar: newYork),
            try InboxTodayFixture.date("2026-03-09T04:00:00Z"), "the day after starts at midnight EDT")

        let santiago = try InboxTodayFixture.calendar("America/Santiago")
        XCTAssertEqual(
            InboxToday.nextMidnight(after: try InboxTodayFixture.date("2026-09-05T15:00:00Z"), calendar: santiago),
            try InboxTodayFixture.date("2026-09-06T04:00:00Z"), "a gap that swallows midnight: its first instant")
    }
}
