import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class CalendarEventRowViewTests: XCTestCase {

    // MARK: - Helpers

    /// CalendarEvent имеет только init(row:) — собираем фикстуру из словаря-Row.
    /// startTime/endTime в будущем → isHappeningNow=false, isUpcoming=false (default-стиль).
    private func makeEvent(
        title: String = "Sync",
        location: String = "",
        attendeesJSON: String = "[]",
        organizerEmail: String = "",
        startTime: String = "2099-01-01T10:00:00Z",
        endTime: String = "2099-01-01T11:00:00Z"
    ) -> CalendarEvent {
        let row: Row = [
            "id": "ev1",
            "calendar_id": "cal1",
            "title": title,
            "description": "",
            "location": location,
            "start_time": startTime,
            "end_time": endTime,
            "organizer_email": organizerEmail,
            "attendees": attendeesJSON,
            "is_recurring": 0,
            "is_all_day": 0,
            "event_status": "confirmed",
            "event_type": "",
            "html_link": "",
            "raw_json": "{}",
            "synced_at": "",
            "updated_at": ""
        ]
        return CalendarEvent(row: row)
    }

    // MARK: - attendeesIncludingOrganizer

    /// The organizer lives in its own column, never in the attendees JSON —
    /// the identity union must add them (with an empty display name).
    func testAttendeesIncludingOrganizerAddsNonGuestOrganizer() {
        let event = makeEvent(
            attendeesJSON: #"[{"email":"alice@corp.com","display_name":"Alice","response_status":"accepted","slack_user_id":""}]"#,
            organizerEmail: "boss@corp.com")
        XCTAssertEqual(event.attendeesIncludingOrganizer.map(\.email),
                       ["alice@corp.com", "boss@corp.com"])
    }

    /// An organizer already on the guest list must not be duplicated
    /// (case-insensitive), and an empty organizer adds nothing.
    func testAttendeesIncludingOrganizerSkipsDuplicateAndEmpty() {
        let event = makeEvent(
            attendeesJSON: #"[{"email":"boss@corp.com","display_name":"Boss","response_status":"accepted","slack_user_id":""}]"#,
            organizerEmail: "Boss@Corp.com")
        XCTAssertEqual(event.attendeesIncludingOrganizer.map(\.email), ["boss@corp.com"])
        XCTAssertEqual(makeEvent(attendeesJSON: "[]").attendeesIncludingOrganizer, [])
    }

    /// A zero-guest event (focus block; also an undecodable attendees JSON)
    /// must stay [] even with an organizer — [] is the "treat as ad-hoc →
    /// global voice-print pool" sentinel, and an organizer-only set would
    /// narrow the pool to the owner and strip every colleague's name.
    func testAttendeesIncludingOrganizerStaysEmptyWithoutGuests() {
        XCTAssertEqual(
            makeEvent(attendeesJSON: "[]", organizerEmail: "boss@corp.com").attendeesIncludingOrganizer, [])
        XCTAssertEqual(
            makeEvent(attendeesJSON: "{broken", organizerEmail: "boss@corp.com").attendeesIncludingOrganizer, [])
    }

    /// A room resource is an ordinary attendee row in Google's payload —
    /// it is filtered out entirely (never offered as a speaker, never in
    /// the print pool), so a room-only booking keeps the [] sentinel and a
    /// mixed list yields humans + organizer only.
    func testAttendeesIncludingOrganizerFiltersRoomResources() {
        let room = #"{"email":"office-6@resource.calendar.google.com","display_name":"Room 6","response_status":"accepted","slack_user_id":""}"#
        let human = #"{"email":"alice@corp.com","display_name":"Alice","response_status":"accepted","slack_user_id":""}"#
        XCTAssertEqual(
            makeEvent(attendeesJSON: "[\(room)]", organizerEmail: "boss@corp.com").attendeesIncludingOrganizer, [],
            "a room-only booking must degrade to the global pool, not to owner-only")
        XCTAssertEqual(
            makeEvent(attendeesJSON: "[\(room),\(human)]", organizerEmail: "boss@corp.com")
                .attendeesIncludingOrganizer.map(\.email),
            ["alice@corp.com", "boss@corp.com"],
            "the room row must not reach the picker or the print pool")
    }

    // MARK: - Tests

    /// Title всегда виден.
    func testTitleRendered() throws {
        let view = CalendarEventRow(event: makeEvent(title: "Standup"))
        XCTAssertNoThrow(try view.inspect().find(text: "Standup"))
    }

    /// Если location непустой — рендерится Label с этим текстом.
    func testLocationLabelShownWhenSet() throws {
        let view = CalendarEventRow(event: makeEvent(location: "Room 42"))
        XCTAssertNoThrow(try view.inspect().find(text: "Room 42"))
    }

    /// Если location пустой — Label вовсе не строится.
    func testLocationLabelHiddenWhenEmpty() throws {
        let view = CalendarEventRow(event: makeEvent(location: ""))
        // Lookup-через-image для Label с systemImage "mappin"
        XCTAssertThrowsError(try view.inspect().find(ViewType.Label.self))
    }

    /// Attendees count label показывается, когда parsedAttendees > 0.
    func testAttendeesCountShown() throws {
        // Минимально валидный JSON для EventAttendee. Если внутренняя структура другая,
        // парсер вернёт [] и Label не появится — этим страхуемся падением теста.
        // EventAttendee CodingKeys: snake_case (display_name, response_status, slack_user_id).
        let attendees = """
        [{"email":"a@x.com","display_name":"","response_status":"accepted","slack_user_id":""},
         {"email":"b@x.com","display_name":"","response_status":"needsAction","slack_user_id":""}]
        """
        let view = CalendarEventRow(event: makeEvent(attendeesJSON: attendees))

        // Если парсинг сработал — увидим "2".
        XCTAssertNoThrow(try view.inspect().find(text: "2"))
    }

    /// Без attendees — count-label не рендерится (parsedAttendees == 0).
    func testAttendeesCountHiddenWhenEmpty() throws {
        let view = CalendarEventRow(event: makeEvent(attendeesJSON: "[]"))

        // "person.2" Label существовать не должен — но проще проверить через Text "0":
        // его не должно быть в дереве, т.к. блок `if count > 0` не сработал.
        XCTAssertThrowsError(try view.inspect().find(text: "0"))
    }

    /// Upcoming-событие (старт < 1 ч) показывает relative-countdown suffix
    /// ("in" + relative Text). Даты — относительные от Date(), не хардкод.
    func testCountdownShownForUpcomingEvent() throws {
        let fmt = ISO8601DateFormatter()
        let start = Date().addingTimeInterval(25 * 60)
        let view = CalendarEventRow(event: makeEvent(
            startTime: fmt.string(from: start),
            endTime: fmt.string(from: start.addingTimeInterval(1800))
        ))
        XCTAssertNoThrow(try view.inspect().find(text: "in"))
    }

    /// Не-upcoming (далёкое будущее из дефолтной фикстуры) и прошедшее
    /// событие countdown не показывают.
    func testCountdownHiddenWhenNotUpcoming() throws {
        let farFuture = CalendarEventRow(event: makeEvent())
        XCTAssertThrowsError(try farFuture.inspect().find(text: "in"))

        let fmt = ISO8601DateFormatter()
        let pastStart = Date().addingTimeInterval(-7200)
        let past = CalendarEventRow(event: makeEvent(
            startTime: fmt.string(from: pastStart),
            endTime: fmt.string(from: pastStart.addingTimeInterval(1800))
        ))
        XCTAssertThrowsError(try past.inspect().find(text: "in"))
    }

    /// Recording-count badge (Meetings-screen rewiring, decision 2): "N rec"
    /// renders only when the event has folded recordings.
    func testRecordingBadgeShownWhenCountPositive() throws {
        let view = CalendarEventRow(event: makeEvent(), recordingCount: 2)
        XCTAssertNoThrow(try view.inspect().find(text: "2 rec"))
    }

    /// Default recordingCount is 0 — an event with no recordings renders no
    /// badge at all, not a "0 rec" badge.
    func testRecordingBadgeHiddenWhenCountZero() throws {
        let view = CalendarEventRow(event: makeEvent())
        XCTAssertThrowsError(try view.inspect().find(text: "0 rec"))
    }

    /// The row itself carries no Record affordance — Record moved to the
    /// detail pane (`MeetingDetailView`/`MeetingRecordButton`) as part of the
    /// unified Meetings screen; the row is tap-to-select only.
    func testRowHasNoRecordAffordance() throws {
        let view = CalendarEventRow(event: makeEvent(), recordingCount: 1)
        XCTAssertThrowsError(try view.inspect().find(text: "Record"))
        XCTAssertThrowsError(try view.inspect().find(ViewType.Button.self))
    }
}
