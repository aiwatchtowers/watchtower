import XCTest
import GRDB
@testable import WatchtowerDesktop

final class MeetingListBuilderTests: XCTestCase {
    // Fixed reference point (never Date()) so every fixture date is derived
    // relative to it — no date-bombs, deterministic regardless of when the
    // suite runs.
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        return cal
    }()

    private lazy var now: Date = calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 31, hour: 15)) ?? Date(timeIntervalSince1970: 0)

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    // MARK: - Fixture helpers

    private func makeEvent(id: String, start: Date, end: Date? = nil) -> CalendarEvent {
        CalendarEvent(row: Row([
            "id": id,
            "calendar_id": "cal1",
            "title": "Event \(id)",
            "start_time": Self.iso8601Formatter.string(from: start),
            "end_time": Self.iso8601Formatter.string(from: end ?? start.addingTimeInterval(1800))
        ]))
    }

    private func makeRecording(
        id: Int64,
        eventID: String? = nil,
        createdAt: String,
        duration: Int = 300
    ) -> RecordingListItem {
        RecordingListItem(
            id: id, eventID: eventID, eventTitle: nil, title: "Rec \(id)", durationSec: duration,
            langStats: #"{"ru":3}"#, createdAt: createdAt,
            hasRecap: false, hasNotes: false, snippet: "…")
    }

    private func iso(_ date: Date) -> String {
        Self.iso8601Formatter.string(from: date)
    }

    private func dayEvents(id: Date, label: String, events: [CalendarEvent]) -> DayEvents {
        DayEvents(id: id, label: label, events: events)
    }

    private func day(_ offset: Int, from reference: Date) throws -> Date {
        try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: reference))
    }

    // MARK: - Tests

    func testFoldsRecordingsIntoMatchingEvent() {
        let todayStart = calendar.startOfDay(for: now)
        let event = makeEvent(id: "e1", start: now)
        let days = [dayEvents(id: todayStart, label: "Today", events: [event])]
        let earlier = makeRecording(id: 1, eventID: "e1", createdAt: iso(now.addingTimeInterval(-7200)))
        let later = makeRecording(id: 2, eventID: "e1", createdAt: iso(now.addingTimeInterval(-3600)))

        let sections = MeetingListBuilder.build(
            days: days, recordings: [later, earlier], now: now, calendar: calendar)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].entries.count, 1)
        guard case .event(_, let recordings) = sections[0].entries[0].kind else {
            return XCTFail("expected .event entry")
        }
        XCTAssertEqual(recordings.map(\.id), [1, 2]) // folded ascending by createdDate
        XCTAssertEqual(sections[0].entries[0].recordingCount, 2)
    }

    func testAdHocRecordingBecomesStandaloneEntry() {
        let todayStart = calendar.startOfDay(for: now)
        let recording = makeRecording(id: 1, eventID: nil, createdAt: iso(now.addingTimeInterval(-3600)))

        let sections = MeetingListBuilder.build(
            days: [], recordings: [recording], now: now, calendar: calendar)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, todayStart)
        XCTAssertEqual(sections[0].entries.count, 1)
        guard case .recording(let item) = sections[0].entries[0].kind else {
            return XCTFail("expected .recording entry")
        }
        XCTAssertEqual(item.id, 1)
        XCTAssertEqual(sections[0].entries[0].id, .recording(1))
    }

    func testPrunedEventRecordingDegradesToStandalone() {
        let todayStart = calendar.startOfDay(for: now)
        let event = makeEvent(id: "e1", start: now)
        let days = [dayEvents(id: todayStart, label: "Today", events: [event])]
        let orphan = makeRecording(id: 9, eventID: "does-not-exist", createdAt: iso(now.addingTimeInterval(-3600)))

        let sections = MeetingListBuilder.build(
            days: days, recordings: [orphan], now: now, calendar: calendar)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].entries.count, 2)
        let kinds = sections[0].entries.map(\.id)
        XCTAssertTrue(kinds.contains(.event("e1")))
        XCTAssertTrue(kinds.contains(.recording(9)))
        // The event itself keeps zero folded recordings — the orphan never matches it.
        let eventEntry = sections[0].entries.first { $0.id == .event("e1") }
        guard case .event(_, let recordings) = eventEntry?.kind else {
            return XCTFail("expected .event entry")
        }
        XCTAssertEqual(recordings.count, 0)
    }

    /// Owner decision 2026-08-07 (reverting the unified-view spec's Decision
    /// 2): the list is one chronology — past days on top ascending into
    /// today/upcoming, so scrolling up from Today goes back in time (the
    /// pre-unification behavior; the view auto-scrolls to Today on appear).
    func testOrderingChronologicalPastFirst() throws {
        let todayStart = calendar.startOfDay(for: now)
        let dayMinus2 = try day(-2, from: todayStart)
        let dayMinus1 = try day(-1, from: todayStart)
        let dayPlus1 = try day(1, from: todayStart)

        // Two events per day so intra-section ordering is also verified.
        let todayEarly = makeEvent(id: "today-early", start: now.addingTimeInterval(-3600))
        let todayLate = makeEvent(id: "today-late", start: now.addingTimeInterval(3600))
        let pastEarly = makeEvent(id: "past-early", start: dayMinus1.addingTimeInterval(3600))
        let pastLate = makeEvent(id: "past-late", start: dayMinus1.addingTimeInterval(7200))

        let days = [
            dayEvents(id: dayMinus2, label: "-2d", events: [makeEvent(id: "d-2", start: dayMinus2.addingTimeInterval(3600))]),
            dayEvents(id: dayMinus1, label: "-1d", events: [pastEarly, pastLate]),
            dayEvents(id: todayStart, label: "Today", events: [todayEarly, todayLate]),
            dayEvents(id: dayPlus1, label: "+1d", events: [makeEvent(id: "d+1", start: dayPlus1.addingTimeInterval(3600))])
        ]

        let sections = MeetingListBuilder.build(days: days, recordings: [], now: now, calendar: calendar)

        XCTAssertEqual(sections.map(\.id), [dayMinus2, dayMinus1, todayStart, dayPlus1])

        // Ascending sortDate everywhere — past sections included.
        XCTAssertEqual(sections[1].entries.map(\.id), [.event("past-early"), .event("past-late")])
        XCTAssertEqual(sections[2].entries.map(\.id), [.event("today-early"), .event("today-late")])
    }

    func testRecordingOnlyDayBeyondCalendarWindow() {
        let todayStart = calendar.startOfDay(for: now)
        let days = [dayEvents(id: todayStart, label: "Today", events: [makeEvent(id: "e1", start: now)])]
        let oldCreatedAt = now.addingTimeInterval(-30 * 86400)
        let old = makeRecording(id: 5, eventID: nil, createdAt: iso(oldCreatedAt))
        // Pinned explicitly (not .current) so the assertion is deterministic
        // regardless of the machine's system locale — see
        // testLabelMirrorsCalendarViewModelFormat for the format-parity guard.
        let locale = Locale(identifier: "en_US")

        let sections = MeetingListBuilder.build(
            days: days, recordings: [old], now: now, calendar: calendar, locale: locale)

        let expectedDay = calendar.startOfDay(for: oldCreatedAt)
        XCTAssertEqual(sections.map(\.id), [expectedDay, todayStart])
        XCTAssertEqual(sections[0].entries.count, 1)
        XCTAssertEqual(sections[0].entries[0].id, .recording(5))
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "EEEE, d MMM"
        XCTAssertEqual(sections[0].label, fmt.string(from: expectedDay))
    }

    /// Decision: the builder's fallback label (used only for a recording-only
    /// day outside the calendar window) must format identically to
    /// `CalendarViewModel.label(for:calendar:)` — same "EEEE, d MMM" pattern —
    /// so a recording-only day section reads no differently from an event day
    /// section in the same list. Mirrors `CalendarViewModel.swift`'s private
    /// `label` verbatim rather than re-deriving it, to catch drift.
    func testLabelMirrorsCalendarViewModelFormat() {
        let todayStart = calendar.startOfDay(for: now)
        let dayMinus5 = calendar.date(byAdding: .day, value: -5, to: todayStart) ?? todayStart
        let days = [dayEvents(id: todayStart, label: "Today", events: [makeEvent(id: "e1", start: now)])]
        let locale = Locale(identifier: "en_US")
        let old = makeRecording(id: 6, eventID: nil, createdAt: iso(dayMinus5.addingTimeInterval(3600)))

        let sections = MeetingListBuilder.build(
            days: days, recordings: [old], now: now, calendar: calendar, locale: locale)

        let expectedFmt = DateFormatter()
        expectedFmt.locale = locale
        expectedFmt.timeZone = calendar.timeZone
        expectedFmt.dateFormat = "EEEE, d MMM"
        let section = sections.first { $0.id == dayMinus5 }
        XCTAssertEqual(section?.label, expectedFmt.string(from: dayMinus5))
    }

    func testEventWithoutRecordingsKeptWithZeroCount() {
        let todayStart = calendar.startOfDay(for: now)
        let event = makeEvent(id: "e1", start: now)
        let days = [dayEvents(id: todayStart, label: "Today", events: [event])]

        let sections = MeetingListBuilder.build(days: days, recordings: [], now: now, calendar: calendar)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].entries.count, 1)
        XCTAssertEqual(sections[0].entries[0].recordingCount, 0)
        guard case .event(_, let recordings) = sections[0].entries[0].kind else {
            return XCTFail("expected .event entry")
        }
        XCTAssertEqual(recordings, [])
    }

    func testDefaultRecordingIDPicksLongest() {
        let short = makeRecording(id: 1, createdAt: iso(now.addingTimeInterval(-3600)), duration: 1)
        let long = makeRecording(id: 2, createdAt: iso(now.addingTimeInterval(-7200)), duration: 984)
        XCTAssertEqual(MeetingListBuilder.defaultRecordingID([short, long]), 2)

        // Tie on duration -> newest createdAt wins.
        let tieOlder = makeRecording(id: 3, createdAt: iso(now.addingTimeInterval(-7200)), duration: 500)
        let tieNewer = makeRecording(id: 4, createdAt: iso(now.addingTimeInterval(-1800)), duration: 500)
        XCTAssertEqual(MeetingListBuilder.defaultRecordingID([tieOlder, tieNewer]), 4)

        XCTAssertNil(MeetingListBuilder.defaultRecordingID([]))
    }

    func testUnparseableCreatedAtLandsInOldestPastSection() throws {
        let todayStart = calendar.startOfDay(for: now)
        let dayMinus2 = try day(-2, from: todayStart)
        let dayMinus1 = try day(-1, from: todayStart)

        let days = [
            dayEvents(id: dayMinus2, label: "-2d", events: [makeEvent(id: "d-2", start: dayMinus2.addingTimeInterval(3600))]),
            dayEvents(id: dayMinus1, label: "-1d", events: [makeEvent(id: "d-1", start: dayMinus1.addingTimeInterval(3600))]),
            dayEvents(id: todayStart, label: "Today", events: [makeEvent(id: "e1", start: now)])
        ]
        let broken = makeRecording(id: 7, eventID: nil, createdAt: "not-a-date")

        let sections = MeetingListBuilder.build(days: days, recordings: [broken], now: now, calendar: calendar)

        // "Oldest" == furthest in the past == dayMinus2.
        let target = try XCTUnwrap(sections.first { $0.id == dayMinus2 })
        let other = try XCTUnwrap(sections.first { $0.id == dayMinus1 })
        let targetIDs: [MeetingSelection] = target.entries.map(\.id)
        let otherIDs: [MeetingSelection] = other.entries.map(\.id)
        XCTAssertTrue(targetIDs.contains(.recording(7)))
        XCTAssertFalse(otherIDs.contains(.recording(7)))
    }
}
