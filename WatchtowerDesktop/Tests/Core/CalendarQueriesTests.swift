import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Covers the `account_email` LEFT JOIN that lets `CalendarEvent.joinURL`
/// hint the right Google account on a Meet link.
final class CalendarQueriesAccountEmailTests: XCTestCase {

    func testFetchEventResolvesOwningAccountEmail() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            let accountID = try TestDatabase.insertGoogleAccount(
                db, email: "vadym@work.com", calendarEnabled: true)
            try TestDatabase.ensureCalendar(db, id: "work-cal", accountID: accountID)
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-work", calendarID: "work-cal",
                conferenceURL: "https://meet.google.com/abc-defg-hij")
        }

        let event = try db.read { try CalendarQueries.fetchEvent($0, id: "evt-work") }
        XCTAssertEqual(event?.accountEmail, "vadym@work.com")
        XCTAssertEqual(
            event?.joinURL,
            URL(string: "https://meet.google.com/abc-defg-hij?authuser=vadym@work.com"))
    }

    /// A CalDAV/ICS calendar has no owning account (`account_id IS NULL`): the
    /// LEFT JOIN still returns the event, with a nil `account_email` and an
    /// un-hinted join link.
    func testFetchEventNilEmailForAccountlessCalendar() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.ensureCalendar(db, id: "caldav:personal", accountID: nil)
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-personal", calendarID: "caldav:personal",
                conferenceURL: "https://meet.google.com/xyz-uvwq-rst")
        }

        let event = try db.read { try CalendarQueries.fetchEvent($0, id: "evt-personal") }
        XCTAssertNil(event?.accountEmail)
        XCTAssertEqual(event?.joinURL, URL(string: "https://meet.google.com/xyz-uvwq-rst"))
    }

    /// The main calendar-tab query carries the email through too.
    func testFetchEventsCarriesAccountEmail() throws {
        let iso = ISO8601DateFormatter()
        let db = try TestDatabase.create()
        try db.write { db in
            let accountID = try TestDatabase.insertGoogleAccount(
                db, email: "vadym@work.com", calendarEnabled: true)
            try TestDatabase.ensureCalendar(db, id: "work-cal", accountID: accountID)
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-work", calendarID: "work-cal",
                startTime: "2024-06-01T10:00:00Z", endTime: "2024-06-01T11:00:00Z",
                conferenceURL: "https://meet.google.com/abc-defg-hij")
        }

        let from = try XCTUnwrap(iso.date(from: "2024-06-01T00:00:00Z"))
        let to = try XCTUnwrap(iso.date(from: "2024-06-02T00:00:00Z"))
        let events = try db.read { try CalendarQueries.fetchEvents($0, from: from, to: to) }
        XCTAssertEqual(events.map(\.accountEmail), ["vadym@work.com"])
    }
}
