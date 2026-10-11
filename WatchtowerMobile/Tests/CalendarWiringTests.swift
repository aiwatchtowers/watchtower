import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone calendar (spec §13 C1): the agenda day with its week strip,
/// event cards, the now line and the current or next meeting; the event
/// detail; the Now tab's next-meeting card. The models take `now`, so the
/// tests pin it at local noon today: an offset of a few hours never crosses
/// midnight, whatever the hour the suite runs at.
@MainActor
final class CalendarWiringTests: XCTestCase {
    private let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    private var calendar: Calendar { .current }

    // MARK: - Fixtures

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func event(
        _ id: String,
        start: Date,
        minutes: Double = 45,
        allDay: Bool = false,
        conference: String = "",
        prep: [String] = [],
        attendees: [EventAttendee] = []
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, startTime: Self.iso.string(from: start),
            endTime: Self.iso.string(from: start.addingTimeInterval(minutes * 60)),
            isAllDay: allDay, isRecurring: false, eventStatus: .confirmed, organizerEmail: "",
            htmlLink: "", conferenceURL: conference, title: "Event \(id)", location: "", description: "",
            attendees: attendees, prepBullets: prep,
            prepGeneratedAt: prep.isEmpty ? nil : Self.iso.string(from: now),
            linkedTargets: []
        )
    }

    /// An all-day event stored the hub's way: UTC midnight of `day`'s
    /// local calendar date.
    private func allDayEvent(_ id: String, on day: Date, in calendar: Calendar) -> CalendarEvent {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let stamp = String(format: "%04d-%02d-%02dT00:00:00Z", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let next = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
        let end = String(format: "%04d-%02d-%02dT00:00:00Z", next.year ?? 0, next.month ?? 0, next.day ?? 0)
        return CalendarEvent(
            id: id, startTime: stamp, endTime: end, isAllDay: true, isRecurring: false, eventStatus: .confirmed,
            organizerEmail: "", htmlLink: "", conferenceURL: "", title: "Release day", location: "",
            description: "", attendees: [], prepBullets: [], linkedTargets: []
        )
    }

    private func snapshot(_ events: [CalendarEvent], transcripts: [MeetingTranscript] = []) -> CalendarReplicaSnapshot {
        CalendarReplicaSnapshot(events: events, transcripts: transcripts)
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
    }

    // MARK: - All-day

    func testAnAllDayEventHasNoRecordButton() throws {
        let allDay = allDayEvent("ad", on: now, in: calendar)
        let agenda = AgendaDayModel(
            day: now, snapshot: snapshot([allDay]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        )
        let card = try XCTUnwrap(agenda.cards.first)
        XCTAssertFalse(card.showsRecord)
        XCTAssertFalse(card.isHighlighted, "an all-day event is never the current or next meeting")
        XCTAssertEqual(card.timeText, "All day")
        let detail = try XCTUnwrap(EventDetailModel(
            eventID: "ad", snapshot: snapshot([allDay]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        ))
        XCTAssertFalse(detail.showsRecord)
        XCTAssertFalse(detail.actionTitles.contains("Record this meeting"))
    }

    /// Review focus 2: west of UTC the stored UTC midnight is the previous
    /// evening; the event must still sit on its own day.
    func testAnAllDayEventStaysOnItsDayWestOfUTC() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let today = losAngeles.startOfDay(for: now)
        let allDay = allDayEvent("ad", on: today, in: losAngeles)
        let yesterday = try XCTUnwrap(losAngeles.date(byAdding: .day, value: -1, to: today))

        let onDay = AgendaDayModel(
            day: today, snapshot: snapshot([allDay]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: losAngeles
        )
        XCTAssertEqual(onDay.cards.map(\.id), ["ad"])
        let dayBefore = AgendaDayModel(
            day: yesterday, snapshot: snapshot([allDay]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: losAngeles
        )
        XCTAssertTrue(dayBefore.cards.isEmpty, "the UTC-midnight instant must not leak into the previous day")
    }

    // MARK: - Prep

    func testNoPrepSaysItIsPreparedOnTheMac() throws {
        let bare = event("e1", start: now.addingTimeInterval(1_800))
        let detail = try XCTUnwrap(EventDetailModel(
            eventID: "e1", snapshot: snapshot([bare]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        ))
        XCTAssertTrue(detail.prepBullets.isEmpty)
        XCTAssertEqual(detail.prepEmptyText, "No prep yet — it is prepared on your Mac")

        let prepped = event("e2", start: now.addingTimeInterval(1_800), prep: ["Ask about the release"])
        let withPrep = try XCTUnwrap(EventDetailModel(
            eventID: "e2", snapshot: snapshot([prepped]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        ))
        XCTAssertEqual(withPrep.prepBullets, ["Ask about the release"])
        XCTAssertNil(withPrep.prepEmptyText)
    }

    // MARK: - Make target (hidden until D)

    func testMakeTargetIsNotShownAnywhere() async throws {
        let now = now
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: now)
        let uploader = RecordingUploader(transport: transport, store: store, deviceID: DemoSeed.device.deviceID)
        try await DemoSeed.loadRecordingDemo(uploader: uploader, store: store, transport: transport, now: now)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        let calendarSnapshot = try await store.reader.read { db in try CalendarReplicaSnapshot.read(from: db, store: store) }
        let recordings = try await store.reader.read { db in try PhoneRecordingsSnapshot.read(from: db, store: store) }
        XCTAssertTrue(calendarSnapshot.transcripts.contains { !$0.actionItems.isEmpty }, "the demo must carry action items")

        var strings: [String] = []
        for offset in -1...1 {
            let agenda = AgendaDayModel(
                day: day(offset), snapshot: calendarSnapshot, recordings: recordings, now: now, calendar: calendar
            )
            strings += agenda.cards.flatMap { [$0.title, $0.timeText, $0.detailLine] + $0.pills.map(\.text) + $0.actionTitles }
        }
        for event in calendarSnapshot.events {
            let detail = try XCTUnwrap(EventDetailModel(
                eventID: event.id, snapshot: calendarSnapshot, recordings: recordings, now: now, calendar: calendar
            ))
            strings += detail.allStrings
        }
        strings += NextMeetingCardModel(events: calendarSnapshot.events, now: now, calendar: calendar).map {
            [$0.header, $0.title, $0.line]
        } ?? []
        XCTAssertFalse(strings.isEmpty)
        XCTAssertFalse(strings.contains { $0.localizedCaseInsensitiveContains("Make target") })
    }

    // MARK: - Transcribing

    func testATranscribingCardShowsThePercentFromRecordingJob() async throws {
        let now = now
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let uploader = RecordingUploader(transport: transport, store: store, deviceID: DemoSeed.device.deviceID)
        try await DemoSeed.loadRecordingDemo(uploader: uploader, store: store, transport: transport, now: now, percent: 37)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        let recordings = try await store.reader.read { db in try PhoneRecordingsSnapshot.read(from: db, store: store) }
        XCTAssertEqual(recordings.recordings.map(\.eventID), [DemoSeed.recordedEventID])

        let recorded = event(DemoSeed.recordedEventID, start: now.addingTimeInterval(-3_600), minutes: 30)
        let agenda = AgendaDayModel(day: now, snapshot: snapshot([recorded]), recordings: recordings, now: now, calendar: calendar)
        let pill = try XCTUnwrap(agenda.cards.first?.pills.first)
        XCTAssertEqual(pill.text, "Transcribing on Mac · 37%")
        XCTAssertEqual(pill.tone, .purple)
        let detail = try XCTUnwrap(EventDetailModel(
            eventID: recorded.id, snapshot: snapshot([recorded]), recordings: recordings, now: now, calendar: calendar
        ))
        XCTAssertEqual(detail.recordingText, "Transcribing on Mac · 37%")
    }

    /// The demo phone recording of `DemoSeed.recordedEventID` (received by
    /// the Mac, its job transcribing at 37%), as the replica reads it.
    private func demoRecordings() async throws -> PhoneRecordingsSnapshot {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let uploader = RecordingUploader(transport: transport, store: store, deviceID: DemoSeed.device.deviceID)
        try await DemoSeed.loadRecordingDemo(uploader: uploader, store: store, transport: transport, now: now, percent: 37)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        return try await store.reader.read { db in try PhoneRecordingsSnapshot.read(from: db, store: store) }
    }

    /// The recorded event's card over `recordings` and an older recap of it.
    private func recordedCardPills(_ recordings: PhoneRecordingsSnapshot) throws -> [String] {
        let recorded = event(DemoSeed.recordedEventID, start: now.addingTimeInterval(-3_600), minutes: 30)
        let olderRecap = MeetingTranscript(
            id: 9, eventID: recorded.id, title: "Earlier take", durationSec: 600,
            createdAt: Self.iso.string(from: now.addingTimeInterval(-86_400)),
            updatedAt: Self.iso.string(from: now.addingTimeInterval(-86_400)), speakers: [], summary: "Old.",
            keyDecisions: [], actionItems: ["One"], openQuestions: []
        )
        let agenda = AgendaDayModel(
            day: now, snapshot: snapshot([recorded], transcripts: [olderRecap]), recordings: recordings, now: now, calendar: calendar
        )
        return try XCTUnwrap(agenda.cards.first).pills.map(\.text)
    }

    /// A new phone recording of an event that already has a recap shows
    /// the Mac's progress on it, not the older recap.
    func testAnInProgressRecordingWinsOverAnOlderRecap() async throws {
        let recordings = try await demoRecordings()
        XCTAssertEqual(try recordedCardPills(recordings), ["Transcribing on Mac · 37%"])
    }

    /// C-T7 N2: once the Mac's job is done, the recap is shown again.
    func testTheRecapWinsOnceTheRecordingsJobIsDone() async throws {
        var recordings = try await demoRecordings()
        let id = try XCTUnwrap(recordings.recordings.first { $0.eventID == DemoSeed.recordedEventID }).id
        recordings.jobs[id] = RecordingJob(id: id, status: .done, transcriptID: 9, updatedAt: now)
        XCTAssertEqual(try recordedCardPills(recordings), ["Recap ready", "1 action item"])
    }

    /// C-T7 N2: a delivered upload the Mac has no job for (yet, or any
    /// more) defers to the recap.
    func testTheRecapWinsOverADeliveredUploadWithoutAJob() async throws {
        var recordings = try await demoRecordings()
        recordings.jobs = [:]
        let recording = try XCTUnwrap(recordings.recordings.first { $0.eventID == DemoSeed.recordedEventID })
        XCTAssertEqual(PhoneUploadStage(recording: recording, heartbeat: recordings.heartbeat, now: now), .delivered)
        XCTAssertEqual(try recordedCardPills(recordings), ["Recap ready", "1 action item"])
    }

    func testARecapReadyCardShowsRecapAndActionItems() throws {
        let past = event("e1", start: now.addingTimeInterval(-7_200))
        let transcript = MeetingTranscript(
            id: 1, eventID: "e1", title: "Event e1", durationSec: 2_700, createdAt: Self.iso.string(from: now),
            updatedAt: Self.iso.string(from: now), speakers: [], summary: "Done.", keyDecisions: [],
            actionItems: ["One", "Two", "Three"], openQuestions: []
        )
        let agenda = AgendaDayModel(
            day: now, snapshot: snapshot([past], transcripts: [transcript]), recordings: PhoneRecordingsSnapshot(),
            now: now, calendar: calendar
        )
        let card = try XCTUnwrap(agenda.cards.first)
        XCTAssertEqual(card.pills.map(\.text), ["Recap ready", "3 action items"])
        XCTAssertEqual(card.pills.first?.tone, .green)
        XCTAssertTrue(card.isPast)
    }

    // MARK: - Empty day and now line

    func testAnEmptyAgendaDaySaysNoEvents() {
        let agenda = AgendaDayModel(
            day: day(3), snapshot: snapshot([event("e1", start: now)]), recordings: PhoneRecordingsSnapshot(),
            now: now, calendar: calendar
        )
        XCTAssertTrue(agenda.cards.isEmpty)
        XCTAssertEqual(agenda.emptyText, "No events")
    }

    func testTheNowLineIsDrawnOnlyOnToday() throws {
        let events = (-1...1).map { event("e\($0)", start: day($0).addingTimeInterval(12 * 3_600)) }
        for offset in -1...1 {
            let agenda = AgendaDayModel(
                day: day(offset), snapshot: snapshot(events), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
            )
            let lines = agenda.rows.filter { if case .nowLine = $0 { true } else { false } }
            XCTAssertEqual(lines.count, offset == 0 ? 1 : 0, "day offset \(offset)")
        }
        // Today with no events still draws the line.
        let empty = AgendaDayModel(day: now, snapshot: snapshot([]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar)
        XCTAssertEqual(empty.nowLineText, CalendarFormat(calendar: calendar).time(now))
    }

    func testTheCurrentOrNextMeetingIsHighlightedWithRecordAndPrep() throws {
        let ended = event("ended", start: now.addingTimeInterval(-7_200), minutes: 30)
        let next = event("next", start: now.addingTimeInterval(1_500))
        let later = event("later", start: now.addingTimeInterval(1_500 + 3_600))
        let agenda = AgendaDayModel(
            day: now, snapshot: snapshot([later, next, ended]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        )
        let highlighted = agenda.cards.filter(\.isHighlighted)
        XCTAssertEqual(highlighted.map(\.id), ["next"])
        XCTAssertEqual(highlighted.first?.actionTitles, ["Record", "Prep"])
        XCTAssertNotNil(highlighted.first?.meetingEvent)
        XCTAssertFalse(agenda.cards.first { $0.id == "ended" }?.showsRecord ?? true)
    }

    /// Bug 2 and review focus 5 (design pass spec §9.2): the agenda scrolls
    /// to today's current or next meeting; with none it stays at the top.
    /// Task 9 review: the scroll runs once per day and highlighted row, so
    /// coming back from an event does not snap the list over the user's
    /// scroll; a later snapshot that highlights a row still scrolls.
    /// Task 9 review and final review M3 (spec §9.2): the agenda scrolls
    /// once per day, the first time the day has a highlighted row: not on a
    /// return from a pushed screen, and not when the next meeting takes over
    /// while the user reads; a snapshot that arrives later still scrolls.
    func testTheAgendaScrollsOncePerDay() {
        let today = day(0)
        let key = AgendaScrollKey(day: today, rowID: "event-next")
        XCTAssertEqual(AgendaScroll.target(for: key, scrolledDay: nil), "event-next")
        XCTAssertNil(AgendaScroll.target(for: key, scrolledDay: today), "a return to the screen keeps the user's scroll")
        XCTAssertNil(
            AgendaScroll.target(for: AgendaScrollKey(day: today, rowID: "event-after"), scrolledDay: today),
            "the next meeting taking over does not jump the list"
        )
        XCTAssertNil(AgendaScroll.target(for: AgendaScrollKey(day: today, rowID: nil), scrolledDay: nil), "nothing highlighted")
        XCTAssertEqual(AgendaScroll.target(for: AgendaScrollKey(day: day(1), rowID: "event-x"), scrolledDay: today), "event-x")
    }

    func testOnlyTodaysCurrentOrNextMeetingIsScrolledTo() throws {
        let ended = event("ended", start: now.addingTimeInterval(-7_200), minutes: 30)
        let next = event("next", start: now.addingTimeInterval(1_500))
        let today = AgendaDayModel(
            day: now, snapshot: snapshot([next, ended]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        )
        XCTAssertEqual(today.highlightedRowID, "event-next")
        let over = AgendaDayModel(day: now, snapshot: snapshot([ended]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar)
        XCTAssertNil(over.highlightedRowID, "every meeting is over")
        let later = event("later", start: day(1).addingTimeInterval(12 * 3_600))
        let tomorrow = AgendaDayModel(
            day: day(1), snapshot: snapshot([later]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        )
        XCTAssertNil(tomorrow.highlightedRowID, "only today highlights a meeting")
    }

    // MARK: - Join

    func testJoinOpensTheConferenceURLAndNoURLMeansNoJoin() throws {
        let url = "https://meet.example.com/abc"
        let withLink = event("e1", start: now, conference: url)
        let detail = try XCTUnwrap(EventDetailModel(
            eventID: "e1", snapshot: snapshot([withLink]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        ))
        XCTAssertEqual(detail.joinURL, URL(string: url))
        XCTAssertTrue(detail.actionTitles.contains("Join"))

        let without = event("e2", start: now)
        let bare = try XCTUnwrap(EventDetailModel(
            eventID: "e2", snapshot: snapshot([without]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        ))
        XCTAssertNil(bare.joinURL)
        XCTAssertFalse(bare.actionTitles.contains("Join"))
        XCTAssertEqual(bare.actionTitles, ["Record this meeting"])
    }

    // MARK: - Now tab

    func testTheNextMeetingCardPicksTheNextNonAllDayEventThatHasNotEnded() throws {
        let ended = event("ended", start: now.addingTimeInterval(-7_200), minutes: 30)
        let allDay = allDayEvent("ad", on: now, in: calendar)
        let later = event("later", start: now.addingTimeInterval(7_200))
        let soon = event(
            "soon", start: now.addingTimeInterval(25 * 60 + 30), prep: ["Bring the numbers"],
            attendees: (1...5).map { EventAttendee(email: "p\($0)@example.com", displayName: "P\($0)", responseStatus: "accepted") }
        )
        let card = try XCTUnwrap(NextMeetingCardModel(events: [later, allDay, ended, soon], now: now, calendar: calendar))
        XCTAssertEqual(card.id, "soon")
        XCTAssertEqual(card.header, "Next · in 26 min")
        XCTAssertTrue(card.line.hasSuffix("· 5 people · prep ready"), card.line)

        let ongoing = event("ongoing", start: now.addingTimeInterval(-600), minutes: 30)
        XCTAssertEqual(NextMeetingCardModel(events: [later, ongoing], now: now, calendar: calendar)?.id, "ongoing")
        XCTAssertNil(NextMeetingCardModel(events: [ended, allDay], now: now, calendar: calendar))
        XCTAssertTrue(
            try XCTUnwrap(NextMeetingCardModel(events: [later], now: now, calendar: calendar)).line.hasSuffix("· no prep yet")
        )
    }

    // MARK: - Week strip

    func testTheWeekStripStartsOnTodayWithEachDaysLetter() throws {
        let strip = WeekStripModel(selected: now, today: now, eventDays: [], calendar: calendar)
        XCTAssertEqual(strip.days.count, 7)
        XCTAssertTrue(try XCTUnwrap(strip.days.first).isToday, "today first, whatever the weekday")
        XCTAssertEqual(strip.days.filter(\.isToday).count, 1)
        let letters = ["S", "M", "T", "W", "T", "F", "S"]
        for (offset, day) in strip.days.enumerated() {
            XCTAssertEqual(day.date, calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)))
            XCTAssertEqual(day.letter, letters[calendar.component(.weekday, from: day.date) - 1])
        }

        let today = try XCTUnwrap(strip.days.first(where: \.isToday))
        XCTAssertEqual(today.spokenLabel, CalendarFormat(calendar: calendar).spokenDay(now) + ", today")
        let marked = WeekStripModel(selected: now, today: now, eventDays: [calendar.startOfDay(for: now)], calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(marked.days.first(where: \.isToday)).spokenLabel.hasSuffix(", today, has events"))
        XCTAssertFalse(CalendarFormat(calendar: calendar).spokenDay(now).isEmpty)
    }

    /// Pages are today + 7k: a day inside the page keeps it, a day past
    /// either end moves a whole page (the arrows shift the selection by 7).
    func testTheWeekStripPagesBySevenDaysFromToday() throws {
        let today = calendar.startOfDay(for: now)
        func first(_ days: Int) throws -> Date {
            let selected = try XCTUnwrap(calendar.date(byAdding: .day, value: days, to: now))
            return try XCTUnwrap(WeekStripModel(selected: selected, today: now, eventDays: [], calendar: calendar).days.first).date
        }
        func page(_ weeks: Int) throws -> Date {
            try XCTUnwrap(calendar.date(byAdding: .day, value: 7 * weeks, to: today))
        }
        XCTAssertEqual(try first(6), try page(0))
        XCTAssertEqual(try first(7), try page(1))
        XCTAssertEqual(try first(13), try page(1))
        XCTAssertEqual(try first(-1), try page(-1))
        XCTAssertEqual(try first(-7), try page(-1))
        XCTAssertEqual(try first(-8), try page(-2))
        let selected = try XCTUnwrap(calendar.date(byAdding: .day, value: 9, to: now))
        let strip = WeekStripModel(selected: selected, today: now, eventDays: [], calendar: calendar)
        XCTAssertEqual(strip.days.filter(\.isSelected).map(\.date), [calendar.startOfDay(for: selected)])
        XCTAssertTrue(strip.days.allSatisfy { !$0.isToday }, "today is on page 0 only")
    }

    // MARK: - Replica read

    func testUndecodableCalendarRecordsAreCountedNotHidden() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let bad = SliceRecord(kind: .calendarEvent, id: "bad", modifiedAt: now, payload: Data("{}".utf8))
        let good = try RelayCoder.makeEncoder().encode(event("good", start: now))
        try await transport.save([
            CloudRecordFactory.record(for: bad),
            CloudRecordFactory.record(for: SliceRecord(kind: .calendarEvent, id: "good", modifiedAt: now, payload: good))
        ])
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        let read = try await store.reader.read { db in try CalendarReplicaSnapshot.read(from: db, store: store) }
        XCTAssertEqual(read.events.map(\.id), ["good"])
        XCTAssertEqual(read.skippedRecords, [.calendarEvent: 1])
    }
}
