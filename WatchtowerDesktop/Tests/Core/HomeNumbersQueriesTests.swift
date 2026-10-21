import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The reads behind Home's "Today in numbers": messages to and from the
/// owner, meetings, plan state and the workbench's day.
final class HomeNumbersQueriesTests: XCTestCase {
    private var db: DatabaseQueue!
    private let calendar = Calendar.current
    /// Noon today, so "today" and "yesterday" never straddle a day edge.
    private var now: Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func read() throws -> HomeNumbers {
        try db.read { HomeNumbersQueries.read($0, now: now, calendar: calendar) }
    }

    private var ticks = 0

    private func message(
        _ d: Database,
        channel: String = "1:C1",
        user: String = "1:U9",
        text: String = "hi",
        daysAgo: Int = 0,
        deleted: Bool = false
    ) throws {
        ticks += 1
        let when = now.addingTimeInterval(Double(-daysAgo) * 86_400 + Double(ticks))
        try TestDatabase.insertMessage(
            d, channelID: channel, ts: "\(Int(when.timeIntervalSince1970)).\(String(format: "%06d", ticks))",
            userID: user, text: text, isDeleted: deleted
        )
    }

    func testMessagesToMeCountsDMsAndMentionsNotChannelNoise() throws {
        try db.write { d in
            _ = try TestDatabase.insertSlackAccount(d, currentUserID: "1:UME")
            try TestDatabase.insertChannel(d, id: "1:C1", type: "public")
            try TestDatabase.insertChannel(d, id: "1:D1", name: "dm", type: "dm")
            try TestDatabase.insertChannel(d, id: "1:G1", name: "gdm", type: "group_dm")
            try self.message(d, channel: "1:D1")
            try self.message(d, channel: "1:G1")
            try self.message(d, text: "ping <@UME> please")
            try self.message(d, text: "noise in a channel")
            try self.message(d, channel: "1:D1", daysAgo: 1)
            try self.message(d, channel: "1:D1", deleted: true)
            try self.message(d, channel: "1:D1", user: "1:UME")
        }
        let n = try read()
        XCTAssertEqual(n.messagesToMe, 3)
        XCTAssertTrue(n.failed.isEmpty)
    }

    func testSentCountsEveryOwnerAccount() throws {
        try db.write { d in
            _ = try TestDatabase.insertSlackAccount(d, currentUserID: "1:UME")
            _ = try TestDatabase.insertSlackAccount(d, currentUserID: "2:UME2")
            _ = try TestDatabase.insertSlackAccount(d, currentUserID: "3:UGONE", status: "removed")
            _ = try TestDatabase.insertSlackAccount(d, currentUserID: "4:UPURGED", status: "purged")
            try self.message(d, user: "1:UME")
            try self.message(d, channel: "2:C1", user: "2:UME2")
            try self.message(d, channel: "3:C1", user: "3:UGONE")
            try self.message(d, channel: "4:C1", user: "4:UPURGED")
            try self.message(d, user: "1:UME", daysAgo: 1)
            try self.message(d, user: "1:U9")
        }
        XCTAssertEqual(try read().messagesSent, 2)
    }

    func testNoSlackLeavesMessagesNil() throws {
        let n = try read()
        XCTAssertNil(n.messagesToMe)
        XCTAssertNil(n.messagesSent)
        XCTAssertTrue(n.failed.isEmpty, "an absent source is not a failed one")
    }

    func testMeetingHoursSkipAllDayCancelledDeclined() throws {
        let start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        let declined = #"[{"email":"me@example.com","display_name":"","response_status":"declined","slack_user_id":""}]"#
        try db.write { d in
            let account = try TestDatabase.insertGoogleAccount(d, email: "me@example.com", calendarEnabled: true)
            try TestDatabase.ensureCalendar(d, id: "work", accountID: account)
            func event(
                _ id: String,
                minutes: Int,
                allDay: Bool = false,
                status: String = "confirmed",
                attendees: String = "[]"
            ) throws {
                try TestDatabase.insertCalendarEvent(
                    d, id: id, calendarID: "work", startTime: self.iso(start),
                    endTime: self.iso(start.addingTimeInterval(Double(minutes) * 60)),
                    isAllDay: allDay, attendees: attendees, eventStatus: status
                )
            }
            try event("a", minutes: 60)
            try event("b", minutes: 30)
            try event("allday", minutes: 600, allDay: true)
            try event("cancelled", minutes: 60, status: "cancelled")
            try event("declined", minutes: 60, attendees: declined)
        }
        let n = try read()
        XCTAssertEqual(n.meetings, 2)
        XCTAssertEqual(n.meetingHours, 1.5, "90 minutes")
    }

    func testPlanLeftOutUnlessOK() throws {
        func setPlan(_ state: String) throws {
            try db.write { d in
                try d.execute(sql: "DELETE FROM plan_usage_status")
                try d.execute(sql: """
                    INSERT INTO plan_usage_status (id, state, plan, limits_json, updated_at)
                    VALUES (1, ?, 'max', '[
                     {"key":"session","label":"5-hour","group":"session","percent":42.4,"resets_at":"2026-10-15T10:59:59Z","severity":"normal",
                      "projection":{"state":"safe","rate_per_hour":1}},
                     {"key":"weekly_all","label":"Weekly","group":"weekly","percent":17,"resets_at":"2026-10-15T10:59:59Z","severity":"normal",
                      "projection":{"state":"safe","rate_per_hour":1}}]',
                     '2026-10-15T08:00:00Z')
                    """, arguments: [state])
            }
        }
        XCTAssertNil(try read().plan5h, "no row")
        try setPlan("stale")
        var n = try read()
        XCTAssertNil(n.plan5h)
        XCTAssertNil(n.planWeek)
        try setPlan("ok")
        n = try read()
        XCTAssertEqual(n.plan5h, 42)
        XCTAssertEqual(n.planWeek, 17)
    }

    func testWorkbenchCreatedAndDone() throws {
        let today = iso(now)
        let yesterday = iso(now.addingTimeInterval(-86_400))
        try db.write { d in
            try d.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'wb', '/tmp/wb')")
            let wb = try TestDatabase.insertTarget(d, text: "wb task")
            try d.execute(sql: "UPDATE targets SET project_id = 1 WHERE id = ?", arguments: [wb])
            let plain = try TestDatabase.insertTarget(d, text: "plain")
            func history(_ target: Int64, from: String?, to: String, at: String) throws {
                try d.execute(sql: """
                    INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
                    VALUES (?, ?, ?, ?, 'owner')
                    """, arguments: [target, from, to, at])
            }
            try history(wb, from: nil, to: "todo", at: today)
            try history(wb, from: "todo", to: "done", at: today)
            try history(wb, from: nil, to: "todo", at: yesterday)
            try history(plain, from: nil, to: "todo", at: today)
            try history(plain, from: "todo", to: "done", at: today)
            try TestDatabase.insertMeetingTranscript(d, createdAt: today)
            try TestDatabase.insertMeetingTranscript(d, createdAt: yesterday)
        }
        let n = try read()
        XCTAssertEqual(n.workbenchCreated, 1, "personal targets never count")
        XCTAssertEqual(n.workbenchDone, 1)
        XCTAssertEqual(n.meetingsRecorded, 1)
    }
}
