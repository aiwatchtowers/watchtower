import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `calendar_event` projection (mobile POC spec §4.10): the window and
/// its local-time edges (review focus 2), dedup across accounts, caps, prep
/// bullets, linked targets (PROJ-01) and the hidden `raw_json`.
final class CalendarEventSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private let day: TimeInterval = 86_400
    /// Whole seconds: the DB stores `…:SSZ`.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func calendar(_ zone: TimeZone?) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(zone)
        return calendar
    }

    private var utc: Calendar {
        get throws { try calendar(TimeZone(identifier: "UTC")) }
    }

    /// id → payload, in publish order.
    private func payloads(now: Date? = nil, calendar: Calendar? = nil) throws -> [(id: String, payload: [String: Any])] {
        let stamp = now ?? self.now
        let calendar = try calendar ?? utc
        let slice = CalendarEventSlice(now: { stamp }, calendar: { calendar })
        let records = try dbPool.read { try slice.records($0) }
        XCTAssertTrue(records.allSatisfy { $0.kind == .calendarEvent })
        return try records.map { ($0.id, try SliceJSON.object($0.payload)) }
    }

    private func ids(now: Date? = nil, calendar: Calendar? = nil) throws -> [String] {
        try payloads(now: now, calendar: calendar).map(\.id)
    }

    private func payload(_ id: String) throws -> [String: Any] {
        try XCTUnwrap(try payloads().first { $0.id == id }?.payload, "event \(id) is not published")
    }

    private func insertEvent(
        _ id: String,
        start: Date? = nil,
        end: Date? = nil,
        allDay: (start: String, end: String)? = nil,
        icalUID: String = "",
        conferenceURL: String = "",
        status: String = "confirmed",
        title: String = "Acme sync",
        description: String = "",
        attendees: String = "[]",
        calendarID: String = "primary"
    ) throws {
        let start = start ?? now.addingTimeInterval(3600)
        try dbPool.write { db in
            try TestDatabase.insertCalendarEvent(
                db, id: id, calendarID: calendarID, title: title, description: description,
                startTime: allDay?.start ?? dbStamp(start),
                endTime: allDay?.end ?? dbStamp(end ?? start.addingTimeInterval(1800)),
                isAllDay: allDay != nil, attendees: attendees, eventStatus: status, conferenceURL: conferenceURL
            )
            try db.execute(
                sql: "UPDATE calendar_events SET ical_uid = ?, raw_json = ? WHERE id = ?",
                arguments: [icalUID, #"{"raw_json":"secret","attendees":[{"self":true}]}"#, id]
            )
        }
    }

    /// `YYYY-MM-DDT00:00:00Z` of `calendar`'s day of `date` (an all-day
    /// event's stored form).
    private func storedDay(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00Z", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Wire shape

    private let optionalKeys: Set<String> = [
        "title_clipped", "location_clipped", "description_clipped", "attendees_more", "prep_bullets_more",
        "prep_generated_at", "linked_targets_more"
    ]

    /// The Kit fixture lives inline in the Kit mirror test (no JSON file):
    /// read that literal from the repo so a mirror change shows here too.
    private func kitCalendarFixture() throws -> [String: Any] {
        try SliceJSON.object(
            try SliceJSON.kitInlineFixture("WatchtowerKitTests/CalendarMirrorFixtureTests.swift", test: "testCalendarEventFixture")
        )
    }

    func testAnEventMatchesTheKitFixture() throws {
        try insertEvent(
            "evt-1", conferenceURL: "https://meet.example.com/abc",
            attendees: #"[{"email":"colleague-a@example.com","display_name":"Colleague A","response_status":"accepted","slack_user_id":"U1"}]"#
        )
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE calendar_events SET is_recurring = 1, location = 'Room 1', html_link = 'https://calendar.example.com/e/1',
                    organizer_email = 'colleague-a@example.com' WHERE id = 'evt-1'
                """)
            try TestDatabase.insertMeetingPrep(db, eventID: "evt-1", resultJSON: #"{"talking_points":[{"text":"Ask about the release"}]}"#)
            let target = try TestDatabase.insertTarget(db, text: "Send the notes")
            try TestDatabase.insertMeetingTranscript(db, eventID: "evt-1", chaptersJSON: chapters([target]))
        }
        let payload = try payload("evt-1")
        let fixture = try kitCalendarFixture()

        assertWireShape(payload, matches: fixture, optionalKeys: optionalKeys)
        let attendee = try XCTUnwrap((payload["attendees"] as? [[String: Any]])?.first)
        assertWireShape(attendee, matches: try XCTUnwrap((fixture["attendees"] as? [[String: Any]])?.first))
        let linked = try XCTUnwrap((payload["linked_targets"] as? [[String: Any]])?.first)
        assertWireShape(linked, matches: try XCTUnwrap((fixture["linked_targets"] as? [[String: Any]])?.first))
        XCTAssertEqual(payload["conference_url"] as? String, "https://meet.example.com/abc")
        XCTAssertEqual(payload["start_time"] as? String, dbStamp(now.addingTimeInterval(3600)))
        XCTAssertEqual(payload["is_recurring"] as? Bool, true)
        XCTAssertEqual(payload["prep_bullets"] as? [String], ["Ask about the release"])
        XCTAssertNotNil(payload["prep_generated_at"] as? String)
        XCTAssertEqual(linked["text"] as? String, "Send the notes")
        XCTAssertNil(payload["title_clipped"], "nothing clipped: the key is omitted")
    }

    // MARK: - Hidden column

    func testNoPayloadCarriesRawJSON() throws {
        try insertEvent("evt-a", attendees: #"[{"email":"a@example.com","display_name":"A","response_status":"accepted"}]"#)
        try insertEvent("evt-b", allDay: (storedDay(now, in: utc), storedDay(now.addingTimeInterval(day), in: utc)))
        let all = try payloads()
        XCTAssertEqual(all.count, 2)
        for (_, payload) in all {
            let keys = SliceJSON.allKeys(payload)
            XCTAssertFalse(keys.contains("raw_json"))
            XCTAssertFalse(keys.contains("slack_user_id"), "attendees keep three keys only")
            XCTAssertFalse(keys.contains("self"))
            XCTAssertFalse(keys.contains("ical_uid"))
        }
    }

    // MARK: - Dedup

    func testTwoAccountsCopiesBecomeOneRecordWithTheConferenceLink() throws {
        let start = now.addingTimeInterval(7200)
        try insertEvent("evt-a", start: start, icalUID: "uid-1@example.com", calendarID: "cal-a")
        try insertEvent(
            "evt-b", start: start, icalUID: "uid-1@example.com", conferenceURL: "https://meet.example.com/x",
            calendarID: "cal-b"
        )
        XCTAssertEqual(try ids(), ["evt-b"])
    }

    func testCopiesThatBothHaveAConferenceLinkKeepTheLowestID() throws {
        let start = now.addingTimeInterval(7200)
        try insertEvent(
            "evt-b", start: start, icalUID: "uid-1@example.com", conferenceURL: "https://meet.example.com/b",
            calendarID: "cal-b"
        )
        try insertEvent(
            "evt-a", start: start, icalUID: "uid-1@example.com", conferenceURL: "https://meet.example.com/a",
            calendarID: "cal-a"
        )
        XCTAssertEqual(try ids(), ["evt-a"])
        XCTAssertEqual(try payload("evt-a")["conference_url"] as? String, "https://meet.example.com/a")
    }

    func testCopiesWithoutAConferenceLinkKeepTheLowestID() throws {
        let start = now.addingTimeInterval(7200)
        try insertEvent("evt-b", start: start, icalUID: "uid-1@example.com", calendarID: "cal-b")
        try insertEvent("evt-a", start: start, icalUID: "uid-1@example.com", calendarID: "cal-a")
        XCTAssertEqual(try ids(), ["evt-a"])
    }

    func testRecurringInstancesWithTheSameUIDStaySeparate() throws {
        try insertEvent("evt-1", start: now.addingTimeInterval(3600), icalUID: "uid-r@example.com")
        try insertEvent("evt-2", start: now.addingTimeInterval(3600 + day), icalUID: "uid-r@example.com")
        XCTAssertEqual(try ids(), ["evt-1", "evt-2"])
    }

    func testAnEmptyUIDIsNeverDeduplicated() throws {
        let start = now.addingTimeInterval(3600)
        try insertEvent("evt-1", start: start)
        try insertEvent("evt-2", start: start)
        XCTAssertEqual(try ids(), ["evt-1", "evt-2"])
    }

    func testTheKeptCopyCarriesPrepAndTargetsOfTheDroppedCopy() throws {
        let start = now.addingTimeInterval(7200)
        try insertEvent("evt-a", start: start, icalUID: "uid-1@example.com", calendarID: "cal-a")
        try insertEvent(
            "evt-b", start: start, icalUID: "uid-1@example.com", conferenceURL: "https://meet.example.com/x",
            calendarID: "cal-b"
        )
        try dbPool.write { db in
            try TestDatabase.insertMeetingPrep(db, eventID: "evt-a", resultJSON: #"{"suggested_prep":["Read the doc"]}"#)
            let target = try TestDatabase.insertTarget(db, text: "Follow up")
            try TestDatabase.insertMeetingTranscript(db, eventID: "evt-a", chaptersJSON: chapters([target]))
        }
        let payload = try payload("evt-b")
        XCTAssertEqual(payload["prep_bullets"] as? [String], ["Read the doc"])
        XCTAssertEqual((payload["linked_targets"] as? [[String: Any]])?.compactMap { $0["text"] as? String }, ["Follow up"])
    }

    // MARK: - Cancelled

    func testACancelledEventIsNotPublished() throws {
        try insertEvent("evt-ok")
        try insertEvent("evt-x", status: "cancelled")
        XCTAssertEqual(try ids(), ["evt-ok"])
    }

    func testACancelledCopyNeverWinsTheDedup() throws {
        let start = now.addingTimeInterval(7200)
        try insertEvent("evt-a", start: start, icalUID: "uid-1@example.com", calendarID: "cal-a")
        try insertEvent(
            "evt-b", start: start, icalUID: "uid-1@example.com", conferenceURL: "https://meet.example.com/x",
            status: "cancelled", calendarID: "cal-b"
        )
        XCTAssertEqual(try ids(), ["evt-a"])
    }

    // MARK: - Window edges

    func testTheWindowEdges() throws {
        let utc = try utc
        let end = try XCTUnwrap(utc.date(byAdding: .day, value: 14, to: now))
        let firstDay = try XCTUnwrap(utc.date(byAdding: .day, value: -1, to: utc.startOfDay(for: now)))
        try insertEvent("evt-last", start: end, end: end.addingTimeInterval(1800))
        try insertEvent("evt-past-end", start: end.addingTimeInterval(1), end: end.addingTimeInterval(1800))
        try insertEvent("evt-first", start: firstDay, end: firstDay.addingTimeInterval(1800))
        try insertEvent("evt-before", start: firstDay.addingTimeInterval(-3600), end: firstDay.addingTimeInterval(-1))
        XCTAssertEqual(try ids(), ["evt-first", "evt-last"])
    }

    // MARK: - Caps

    func testFiveHundredAndOneEventsKeepTheFiveHundredEarliest() throws {
        try dbPool.write { db in
            for index in 0...500 {
                let start = now.addingTimeInterval(Double(index) * 60)
                try TestDatabase.insertCalendarEvent(
                    db, id: String(format: "evt-%03d", 500 - index), startTime: dbStamp(start),
                    endTime: dbStamp(start.addingTimeInterval(60))
                )
            }
        }
        let ids = try ids()
        XCTAssertEqual(ids.count, 500)
        XCTAssertEqual(ids.first, "evt-500", "earliest first")
        XCTAssertFalse(ids.contains("evt-000"), "the latest event is left out")
    }

    func testAHundredAndOneAttendeesKeepAHundred() throws {
        let list = (0...100).map { #"{"email":"p\#($0)@example.com","display_name":"P\#($0)","response_status":"accepted"}"# }
        try insertEvent("evt-1", attendees: "[" + list.joined(separator: ",") + "]")
        let payload = try payload("evt-1")
        let attendees = try XCTUnwrap(payload["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.count, 100)
        XCTAssertEqual(attendees.first?["email"] as? String, "p0@example.com")
        XCTAssertEqual((payload["attendees_more"] as? NSNumber)?.intValue, 1)
    }

    /// Go stores a nil attendee slice as `null` (an event without guests):
    /// an empty list, not an unreadable one.
    func testNullOrEmptyAttendeesAreAnEmptyListWithoutAWarning() throws {
        try insertEvent("evt-null", attendees: "null")
        try insertEvent("evt-empty", attendees: "")
        for (id, json) in [("evt-null", "null"), ("evt-empty", "")] {
            XCTAssertEqual((try payload(id)["attendees"] as? [Any])?.count, 0)
            XCTAssertFalse(CalendarEventSlice.hasWarned(.attendees, id: id, content: json))
            XCTAssertEqual(CalendarEventSlice.warningCount(event: id), 0)
        }
    }

    func testUnreadableAttendeesWarnOncePerContent() throws {
        let id = "evt-bad-\(UUID().uuidString)"
        try insertEvent(id, attendees: #"{"email":"a@example.com"}"#)
        XCTAssertEqual((try payload(id)["attendees"] as? [Any])?.count, 0)
        _ = try payloads()
        XCTAssertTrue(CalendarEventSlice.hasWarned(.attendees, id: id, content: #"{"email":"a@example.com"}"#))
        XCTAssertEqual(CalendarEventSlice.warningCount(event: id), 1, "a second tick does not warn again")
        try dbPool.write { try $0.execute(sql: "UPDATE calendar_events SET attendees = '[1]' WHERE id = ?", arguments: [id]) }
        _ = try payloads()
        XCTAssertEqual(CalendarEventSlice.warningCount(event: id), 2, "changed content warns again")
    }

    func testAWarningIsForgottenOnceItsEventLeavesTheWindow() throws {
        let id = "evt-gone-\(UUID().uuidString)"
        try insertEvent(id, attendees: #"{"email":"a@example.com"}"#)
        _ = try payloads()
        XCTAssertEqual(CalendarEventSlice.warningCount(event: id), 1)

        try dbPool.write { try $0.execute(sql: "DELETE FROM calendar_events WHERE id = ?", arguments: [id]) }
        _ = try payloads()

        XCTAssertEqual(CalendarEventSlice.warningCount(event: id), 0, "the warn-once set keeps only current events")
        XCTAssertFalse(CalendarEventSlice.hasWarned(.attendees, id: id, content: #"{"email":"a@example.com"}"#))
    }

    func testTitleAndLocationClipAtThreeHundred() throws {
        try insertEvent("evt-1", title: String(repeating: "t", count: 301))
        try dbPool.write {
            try $0.execute(
                sql: "UPDATE calendar_events SET location = ? WHERE id = 'evt-1'", arguments: [String(repeating: "l", count: 300)]
            )
        }
        let payload = try payload("evt-1")
        XCTAssertEqual((payload["title"] as? String)?.count, 300)
        XCTAssertEqual((payload["title"] as? String)?.last, "…")
        XCTAssertEqual(payload["title_clipped"] as? Bool, true)
        XCTAssertEqual((payload["location"] as? String)?.count, 300)
        XCTAssertNil(payload["location_clipped"], "exactly 300 is not clipped")
    }

    // MARK: - Prep

    func testNoPrepCacheMeansNoBulletsAndNoGeneratedAt() throws {
        try insertEvent("evt-1")
        let payload = try payload("evt-1")
        XCTAssertEqual(payload["prep_bullets"] as? [String], [])
        XCTAssertNil(payload["prep_generated_at"])
        XCTAssertNil(payload["prep_bullets_more"])
    }

    func testTwelveBulletsKeepEightTalkingPointsFirst() throws {
        try insertEvent("evt-1")
        let points = (1...6).map { #"{"text":"Point \#($0)","category":"agenda","priority":"high"}"# }.joined(separator: ",")
        let prep = (1...6).map { #""Prep \#($0)""# }.joined(separator: ",")
        try dbPool.write {
            try TestDatabase.insertMeetingPrep($0, eventID: "evt-1", resultJSON: #"{"talking_points":[\#(points)],"suggested_prep":[\#(prep)]}"#)
        }
        let payload = try payload("evt-1")
        XCTAssertEqual(
            payload["prep_bullets"] as? [String],
            ["Point 1", "Point 2", "Point 3", "Point 4", "Point 5", "Point 6", "Prep 1", "Prep 2"]
        )
        XCTAssertEqual((payload["prep_bullets_more"] as? NSNumber)?.intValue, 4)
        XCTAssertNotNil(payload["prep_generated_at"] as? String)
    }

    func testALongBulletClipsAtThreeHundred() throws {
        try insertEvent("evt-1")
        let long = String(repeating: "b", count: 400)
        try dbPool.write { try TestDatabase.insertMeetingPrep($0, eventID: "evt-1", resultJSON: #"{"suggested_prep":["\#(long)"]}"#) }
        let bullet = try XCTUnwrap((try payload("evt-1")["prep_bullets"] as? [String])?.first)
        XCTAssertEqual(bullet.count, 300)
        XCTAssertEqual(bullet.last, "…")
    }

    func testUnreadablePrepIsLeftOutAndWarnsOnce() throws {
        let id = "evt-prep-\(UUID().uuidString)"
        try insertEvent(id)
        try dbPool.write { try TestDatabase.insertMeetingPrep($0, eventID: id, resultJSON: "not json") }
        let payload = try payload(id)
        _ = try payloads()
        XCTAssertEqual(payload["prep_bullets"] as? [String], [])
        XCTAssertNil(payload["prep_generated_at"])
        XCTAssertTrue(CalendarEventSlice.hasWarned(.prep, id: id, content: "not json"))
        XCTAssertEqual(CalendarEventSlice.warningCount(event: id), 1)
    }

    // MARK: - Linked targets

    private func chapters(_ targets: [Int64]) -> String {
        let items = targets.map { #"{"text":"item","converted_target_id":\#($0)}"# }.joined(separator: ",")
        return #"{"overall_summary":"o","chapters":[{"title":"Intro","start_sec":0,"end_sec":5,"action_items":[{"text":"plain"},\#(items)]}]}"#
    }

    func testAWorkbenchTargetIsNeverLinked() throws {
        try insertEvent("evt-1")
        let (personal, board) = try dbPool.write { db -> (Int64, Int64) in
            let personal = try TestDatabase.insertTarget(db, text: "Personal follow-up", status: "in_progress")
            let project = try TestDatabase.insertWorkbench(db)
            let board = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "Board work")
            try TestDatabase.insertMeetingTranscript(db, eventID: "evt-1", chaptersJSON: chapters([personal, board, 9_999]))
            return (personal, board)
        }
        let linked = try XCTUnwrap(try payload("evt-1")["linked_targets"] as? [[String: Any]])
        XCTAssertEqual(linked.compactMap { ($0["id"] as? NSNumber)?.int64Value }, [personal], "board target \(board) and a deleted id drop out")
        XCTAssertEqual(linked.first?["status"] as? String, "in_progress")
    }

    func testUnreadableChaptersWarnOnceAndLinkNothing() throws {
        try insertEvent("evt-1")
        let transcript = Int64.random(in: 1_000_000...9_000_000)
        try dbPool.write { try TestDatabase.insertMeetingTranscript($0, id: transcript, eventID: "evt-1", chaptersJSON: "{oops") }
        let before = CalendarEventSlice.warningCount(event: "evt-1")
        XCTAssertEqual((try payload("evt-1")["linked_targets"] as? [Any])?.count, 0)
        _ = try payloads()
        XCTAssertTrue(CalendarEventSlice.hasWarned(.chapters, id: String(transcript), content: "{oops"))
        XCTAssertEqual(CalendarEventSlice.warningCount(event: "evt-1"), before + 1)
    }

    func testLinkedTargetsCapAtTwentyAndClipTheirText() throws {
        try insertEvent("evt-1")
        try dbPool.write { db in
            let targets = try (0..<21).map { _ in try TestDatabase.insertTarget(db, text: String(repeating: "x", count: 201)) }
            try TestDatabase.insertMeetingTranscript(db, eventID: "evt-1", chaptersJSON: chapters(targets))
        }
        let payload = try payload("evt-1")
        let linked = try XCTUnwrap(payload["linked_targets"] as? [[String: Any]])
        XCTAssertEqual(linked.count, 20)
        XCTAssertEqual((payload["linked_targets_more"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((linked.first?["text"] as? String)?.count, 200)
    }

    // MARK: - Description

    func testHTMLDescriptionBecomesPlainTextClippedAtTwoThousand() throws {
        let body = String(repeating: "word ", count: 500)
        try insertEvent("evt-1", description: "<p>Agenda &amp; notes</p><br><b>\(body)</b>")
        let payload = try payload("evt-1")
        let description = try XCTUnwrap(payload["description"] as? String)
        XCTAssertTrue(description.hasPrefix("Agenda & notes\n\n"), description)
        XCTAssertFalse(description.contains("<"))
        XCTAssertEqual(description.count, 2000)
        XCTAssertEqual(description.last, "…")
        XCTAssertEqual(payload["description_clipped"] as? Bool, true)
    }

    // MARK: - Review focus 2: time zones and DST

    private func noon(of date: Date, in calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date))
    }

    /// Local noon of the day after Europe/Kyiv's next DST change: a naive
    /// "now − 86 400 s at midnight" lands an hour off; the window must
    /// start at local 00:00 of the change day.
    func testTheWindowStartsAtLocalMidnightAcrossADSTChange() throws {
        let kyiv = try calendar(TimeZone(identifier: "Europe/Kyiv"))
        let transition = try XCTUnwrap(kyiv.timeZone.nextDaylightSavingTimeTransition(after: now))
        let changeDay = kyiv.startOfDay(for: transition)
        XCTAssertNotEqual(
            try XCTUnwrap(kyiv.date(byAdding: .day, value: 1, to: changeDay)).timeIntervalSince(changeDay), day,
            "the change day is not 24 h long"
        )
        for dayOffset in [0, 1] {
            let localNoon = try noon(of: try XCTUnwrap(kyiv.date(byAdding: .day, value: dayOffset, to: changeDay)), in: kyiv)
            let start = CalendarEventSlice.window(now: localNoon, calendar: kyiv).start
            let parts = kyiv.dateComponents([.hour, .minute, .second], from: start)
            XCTAssertEqual([parts.hour, parts.minute, parts.second], [0, 0, 0], "day +\(dayOffset)")
            XCTAssertEqual(kyiv.dateComponents([.day], from: start, to: kyiv.startOfDay(for: localNoon)).day, 1)
        }
        // Records: now on the day after the change; the first day of the
        // window is the change day itself.
        let nextNoon = try noon(of: try XCTUnwrap(kyiv.date(byAdding: .day, value: 1, to: changeDay)), in: kyiv)
        try insertEvent("evt-midnight", start: changeDay, end: changeDay.addingTimeInterval(900))
        try insertEvent("evt-eve", start: changeDay.addingTimeInterval(-1800), end: changeDay.addingTimeInterval(-1))
        XCTAssertEqual(try ids(now: nextNoon, calendar: kyiv), ["evt-midnight"])
    }

    /// An all-day day is stored as UTC midnight; on a UTC−7 Mac that instant
    /// is the evening before. The event keeps its day: it is published with
    /// the stored date when its day is the window's last, and left out when
    /// its day is just past it, though the raw instant falls inside.
    func testAnAllDayEventKeepsItsDayWestOfUTC() throws {
        let west = try calendar(TimeZone(secondsFromGMT: -7 * 3600))
        // Local 20:00, so the window ends at 20:00 on its last day — after
        // 17:00, where the next day's UTC midnight sits.
        let localEvening = try XCTUnwrap(west.date(bySettingHour: 20, minute: 0, second: 0, of: now))
        let end = CalendarEventSlice.window(now: localEvening, calendar: west).end
        let lastDay = storedDay(end, in: west)
        let nextDay = storedDay(try XCTUnwrap(west.date(byAdding: .day, value: 1, to: end)), in: west)
        let afterNext = storedDay(try XCTUnwrap(west.date(byAdding: .day, value: 2, to: end)), in: west)
        try insertEvent("evt-last-day", allDay: (lastDay, nextDay))
        try insertEvent("evt-next-day", allDay: (nextDay, afterNext))
        XCTAssertLessThan(try XCTUnwrap(SliceDate.parse(nextDay)), end, "the trap: the raw instant is inside the window")

        let published = try payloads(now: localEvening, calendar: west)
        XCTAssertEqual(published.map(\.id), ["evt-last-day"])
        let payload = try XCTUnwrap(published.first?.payload)
        XCTAssertEqual(payload["start_time"] as? String, lastDay, "the stored day travels unchanged")
        XCTAssertEqual(payload["is_all_day"] as? Bool, true)
    }

    /// East of UTC the trap is at the window start: yesterday's all-day day
    /// ends at UTC midnight, already inside the local window.
    func testAnAllDayEventBeforeTheWindowStaysOutEastOfUTC() throws {
        let east = try calendar(TimeZone(secondsFromGMT: 9 * 3600))
        let localNoon = try XCTUnwrap(east.date(bySettingHour: 12, minute: 0, second: 0, of: now))
        let start = CalendarEventSlice.window(now: localNoon, calendar: east).start
        let dayBefore = storedDay(try XCTUnwrap(east.date(byAdding: .day, value: -1, to: start)), in: east)
        let firstDay = storedDay(start, in: east)
        let secondDay = storedDay(try XCTUnwrap(east.date(byAdding: .day, value: 1, to: start)), in: east)
        try insertEvent("evt-before", allDay: (dayBefore, firstDay))
        try insertEvent("evt-first", allDay: (firstDay, secondDay))
        XCTAssertGreaterThan(try XCTUnwrap(SliceDate.parse(firstDay)), start, "the trap: the raw end is inside the window")
        XCTAssertEqual(try ids(now: localNoon, calendar: east), ["evt-first"])
    }

    /// 23:30 → 00:30: the event belongs to both days. One that starts the
    /// evening before the window and runs into its first day is published,
    /// as is one over a midnight inside the window, each once, with its
    /// stored times (the phone places it on both days).
    func testAnEventOverMidnightIsPublishedForBothDays() throws {
        let kyiv = try calendar(TimeZone(identifier: "Europe/Kyiv"))
        let localNoon = try XCTUnwrap(kyiv.date(bySettingHour: 12, minute: 0, second: 0, of: now))
        let start = CalendarEventSlice.window(now: localNoon, calendar: kyiv).start
        let tonight = try XCTUnwrap(kyiv.date(byAdding: .day, value: 1, to: kyiv.startOfDay(for: localNoon)))
        try insertEvent("evt-into-window", start: start.addingTimeInterval(-1800), end: start.addingTimeInterval(1800))
        try insertEvent("evt-tonight", start: tonight.addingTimeInterval(-1800), end: tonight.addingTimeInterval(1800))
        let published = try payloads(now: localNoon, calendar: kyiv)
        XCTAssertEqual(published.map(\.id), ["evt-into-window", "evt-tonight"])
        XCTAssertEqual(published.last?.payload["start_time"] as? String, dbStamp(tonight.addingTimeInterval(-1800)))
        XCTAssertEqual(published.last?.payload["end_time"] as? String, dbStamp(tonight.addingTimeInterval(1800)))
    }
}
