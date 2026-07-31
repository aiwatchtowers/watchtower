import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop

/// Minimal scriptable `AudioRecording` that only needs to get the recorder
/// Center into `.recording`; never touches real audio (JoinFakeRecorder shape).
private final class ReminderFakeRecorder: AudioRecording, @unchecked Sendable {
    let liveSamples: AsyncStream<[Float]>
    private var liveContinuation: AsyncStream<[Float]>.Continuation!

    init() {
        var c: AsyncStream<[Float]>.Continuation!
        liveSamples = AsyncStream { c = $0 }
        liveContinuation = c
    }

    func start(to url: URL) async throws {}

    func stop() async throws -> RecordingResult {
        liveContinuation.finish()
        throw AudioRecordingError.deviceSetupFailed("ReminderFakeRecorder never stops")
    }
}

private final class ReminderFakeNotifier: MeetingReminderNotifying, @unchecked Sendable {
    private(set) var reminders: [(eventID: String, title: String, body: String, conferenceURL: String, dedupKey: String)] = []
    private(set) var stops: [(eventID: String, title: String, dedupKey: String)] = []

    func sendMeetingReminderNotification(eventID: String, title: String, body: String, conferenceURL: String, dedupKey: String) {
        reminders.append((eventID, title, body, conferenceURL, dedupKey))
    }

    func sendStopRecordingNotification(eventID: String, title: String, dedupKey: String) {
        stops.append((eventID, title, dedupKey))
    }
}

private final class ReminderFakeTranscriptNotifier: MeetingTranscriptNotifying, @unchecked Sendable {
    func sendTranscriptReadyNotification(title: String) {}
    func sendTranscriptFailedNotification(reason: String) {}
}

private struct ReminderTestError: Error {}

@MainActor
final class MeetingReminderCenterTests: XCTestCase {

    // MARK: - Fixtures

    private static let iso: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    /// `CalendarEvent` has only `init(row:)` — build the fixture from a
    /// dictionary Row (the JoinMeetingActionTests convention), with times
    /// derived from `start` so tests carry no hardcoded dates.
    private func makeEvent(
        id: String = "ev1",
        title: String = "Sync",
        start: Date,
        end: Date? = nil,
        isAllDay: Bool = false,
        conferenceURL: String = ""
    ) -> CalendarEvent {
        let row: Row = [
            "id": id,
            "calendar_id": "cal1",
            "title": title,
            "description": "",
            "location": "",
            "start_time": Self.iso.string(from: start),
            "end_time": Self.iso.string(from: end ?? start.addingTimeInterval(1800)),
            "organizer_email": "",
            "attendees": "[]",
            "is_recurring": 0,
            "is_all_day": isAllDay ? 1 : 0,
            "event_status": "confirmed",
            "event_type": "",
            "html_link": "",
            "conference_url": conferenceURL,
            "raw_json": "{}",
            "synced_at": "",
            "updated_at": ""
        ]
        return CalendarEvent(row: row)
    }

    // MARK: - Pure logic: pre-meeting threshold

    func testPreMeetingFiresWithinThreshold() {
        let now = Date()
        let soon = makeEvent(id: "soon", start: now.addingTimeInterval(4 * 60))
        let later = makeEvent(id: "later", start: now.addingTimeInterval(6 * 60))

        let due = MeetingReminderLogic.preMeetingEvents(
            events: [soon, later], now: now, reminderMinutes: 5, delivered: []
        )
        XCTAssertEqual(due.map(\.id), ["soon"])
    }

    func testPreMeetingFiresExactlyAtThreshold() {
        let now = Date()
        let event = makeEvent(start: now.addingTimeInterval(5 * 60))
        let due = MeetingReminderLogic.preMeetingEvents(
            events: [event], now: now, reminderMinutes: 5, delivered: []
        )
        XCTAssertEqual(due.count, 1)
    }

    func testPreMeetingSkipsAlreadyStartedEvent() {
        // First observed only after its start (start == now and start < now):
        // never notify about a meeting that already began.
        let now = Date()
        let started = makeEvent(id: "started", start: now.addingTimeInterval(-60))
        let startingNow = makeEvent(id: "zero", start: now)
        let due = MeetingReminderLogic.preMeetingEvents(
            events: [started, startingNow], now: now, reminderMinutes: 5, delivered: []
        )
        XCTAssertTrue(due.isEmpty)
    }

    func testPreMeetingSkipsAllDayEvents() {
        let now = Date()
        let allDay = makeEvent(id: "allday", start: now.addingTimeInterval(120), isAllDay: true)
        let due = MeetingReminderLogic.preMeetingEvents(
            events: [allDay], now: now, reminderMinutes: 5, delivered: []
        )
        XCTAssertTrue(due.isEmpty)
    }

    func testPreMeetingZeroMinutesDisables() {
        // Degenerate valid setting: 0 turns the surface off entirely.
        let now = Date()
        let event = makeEvent(start: now.addingTimeInterval(120))
        XCTAssertTrue(MeetingReminderLogic.preMeetingEvents(
            events: [event], now: now, reminderMinutes: 0, delivered: []
        ).isEmpty)
        XCTAssertNil(MeetingReminderLogic.bannerEvent(
            events: [event], now: now, reminderMinutes: 0, dismissed: []
        ))
    }

    func testPreMeetingNoEventsIsClean() {
        // Degenerate valid input: an empty schedule produces nothing.
        let now = Date()
        XCTAssertTrue(MeetingReminderLogic.preMeetingEvents(
            events: [], now: now, reminderMinutes: 5, delivered: []
        ).isEmpty)
        XCTAssertNil(MeetingReminderLogic.bannerEvent(
            events: [], now: now, reminderMinutes: 5, dismissed: []
        ))
    }

    // MARK: - Pure logic: dedup + reschedule

    func testPreMeetingDedupSuppressesSecondFire() {
        let now = Date()
        let event = makeEvent(start: now.addingTimeInterval(3 * 60))
        let key = MeetingReminderLogic.preMeetingDedupKey(event)
        let due = MeetingReminderLogic.preMeetingEvents(
            events: [event], now: now, reminderMinutes: 5, delivered: [key]
        )
        XCTAssertTrue(due.isEmpty)
    }

    func testPreMeetingRescheduleRefires() {
        // The dedup key embeds the start time: after a reschedule the old key
        // no longer matches, so the moved event notifies again.
        let now = Date()
        let original = makeEvent(id: "evt", start: now.addingTimeInterval(3 * 60))
        let deliveredKey = MeetingReminderLogic.preMeetingDedupKey(original)
        let rescheduled = makeEvent(id: "evt", start: now.addingTimeInterval(4 * 60))

        let due = MeetingReminderLogic.preMeetingEvents(
            events: [rescheduled], now: now, reminderMinutes: 5, delivered: [deliveredKey]
        )
        XCTAssertEqual(due.map(\.id), ["evt"])
    }

    // MARK: - Pure logic: stop-recording grace + repeat

    func testStopReminderRespectsGrace() {
        let end = Date()
        XCTAssertNil(MeetingReminderLogic.stopRecordingDedupKey(
            eventID: "e", eventEnd: end, now: end.addingTimeInterval(60)
        ), "inside the 2-minute grace no push fires")
        XCTAssertNil(MeetingReminderLogic.stopRecordingDedupKey(
            eventID: "e", eventEnd: end, now: end
        ), "at the very end no push fires")
        XCTAssertNotNil(MeetingReminderLogic.stopRecordingDedupKey(
            eventID: "e", eventEnd: end, now: end.addingTimeInterval(2 * 60 + 1)
        ))
    }

    func testStopReminderRepeatsEveryTenMinutes() {
        let end = Date()
        let first = MeetingReminderLogic.stopRecordingDedupKey(
            eventID: "e", eventEnd: end, now: end.addingTimeInterval(3 * 60)
        )
        let sameWindow = MeetingReminderLogic.stopRecordingDedupKey(
            eventID: "e", eventEnd: end, now: end.addingTimeInterval(11 * 60)
        )
        let nextWindow = MeetingReminderLogic.stopRecordingDedupKey(
            eventID: "e", eventEnd: end, now: end.addingTimeInterval(13 * 60)
        )
        XCTAssertNotNil(first)
        XCTAssertEqual(first, sameWindow, "within one 10-minute window the key is stable")
        XCTAssertNotEqual(first, nextWindow, "the next 10-minute window mints a fresh key")
    }

    // MARK: - Pure logic: banner visibility window

    func testBannerVisibleWithinWindow() {
        let now = Date()
        let event = makeEvent(id: "evt", start: now.addingTimeInterval(4 * 60))
        XCTAssertEqual(MeetingReminderLogic.bannerEvent(
            events: [event], now: now, reminderMinutes: 5, dismissed: []
        )?.id, "evt")
    }

    func testBannerHiddenBeforeWindowAndAfterFiveMinutesPastStart() {
        let now = Date()
        let farFuture = makeEvent(id: "far", start: now.addingTimeInterval(6 * 60))
        XCTAssertNil(MeetingReminderLogic.bannerEvent(
            events: [farFuture], now: now, reminderMinutes: 5, dismissed: []
        ), "not yet inside the reminder window")

        let justStarted = makeEvent(id: "started", start: now.addingTimeInterval(-4 * 60))
        XCTAssertEqual(MeetingReminderLogic.bannerEvent(
            events: [justStarted], now: now, reminderMinutes: 5, dismissed: []
        )?.id, "started", "the banner lingers up to 5 minutes past start")

        let longStarted = makeEvent(id: "old", start: now.addingTimeInterval(-5 * 60))
        XCTAssertNil(MeetingReminderLogic.bannerEvent(
            events: [longStarted], now: now, reminderMinutes: 5, dismissed: []
        ), "gone once the event is 5 minutes past its start")
    }

    func testBannerPicksEarliestAndSkipsDismissedAndAllDay() {
        let now = Date()
        let allDay = makeEvent(id: "allday", start: now.addingTimeInterval(60), isAllDay: true)
        let first = makeEvent(id: "first", start: now.addingTimeInterval(2 * 60))
        let second = makeEvent(id: "second", start: now.addingTimeInterval(3 * 60))

        XCTAssertEqual(MeetingReminderLogic.bannerEvent(
            events: [allDay, second, first], now: now, reminderMinutes: 5, dismissed: []
        )?.id, "first")

        // Dismissing the earliest reveals the next one.
        let dismissed: Set<String> = [MeetingReminderLogic.preMeetingDedupKey(first)]
        XCTAssertEqual(MeetingReminderLogic.bannerEvent(
            events: [allDay, second, first], now: now, reminderMinutes: 5, dismissed: dismissed
        )?.id, "second")
    }

    // MARK: - Banner countdown text

    func testCountdownTextFormats() {
        let now = Date()
        XCTAssertEqual(UpcomingMeetingBannerView.countdownText(start: now.addingTimeInterval(90), now: now), "in 1:30")
        XCTAssertEqual(UpcomingMeetingBannerView.countdownText(start: now.addingTimeInterval(605), now: now), "in 10:05")
        XCTAssertEqual(UpcomingMeetingBannerView.countdownText(start: now, now: now), "started")
        XCTAssertEqual(UpcomingMeetingBannerView.countdownText(start: now.addingTimeInterval(-30), now: now), "started")
    }

    // MARK: - Center integration (poll loop side effects)

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "MeetingReminderCenterTests-\(UUID().uuidString)"))
    }

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    private func insertEvent(_ pool: DatabasePool, event: CalendarEvent) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO calendar_calendars (id, name, is_primary, is_selected) VALUES ('cal1', 'Main', 1, 1)"
            )
            try db.execute(sql: """
                INSERT INTO calendar_events (id, calendar_id, title, description, location, start_time, end_time,
                    organizer_email, attendees, is_recurring, is_all_day, event_status, event_type, html_link,
                    conference_url, raw_json, synced_at, updated_at)
                VALUES (?, 'cal1', ?, '', '', ?, ?, '', '[]', 0, ?, 'confirmed', '', '', ?, '{}', '', '')
                """, arguments: [
                    event.id, event.title, event.startTime, event.endTime,
                    event.isAllDay ? 1 : 0, event.conferenceURL,
                ])
        }
    }

    private func makeRecorderCenter(recorder: ReminderFakeRecorder, defaults: UserDefaults) -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in throw ReminderTestError() },
            decode: { _ in [] },
            runnerResolver: { nil },
            notifier: ReminderFakeTranscriptNotifier(),
            defaults: defaults
        )
    }

    func testPollFiresPushOnceAndSetsBanner() throws {
        let pool = try makePool()
        let base = Date()
        let event = makeEvent(id: "evt", title: "Standup", start: base.addingTimeInterval(3 * 60))
        try insertEvent(pool, event: event)

        let notifier = ReminderFakeNotifier()
        let center = MeetingReminderCenter(
            dbPool: pool,
            recorderCenter: makeRecorderCenter(recorder: ReminderFakeRecorder(), defaults: try isolatedDefaults()),
            notifier: notifier,
            defaults: try isolatedDefaults(),
            now: { base }
        )

        center.poll()
        center.poll()

        XCTAssertEqual(notifier.reminders.count, 1, "dedup: a re-poll never double-posts")
        XCTAssertEqual(notifier.reminders.first?.eventID, "evt")
        XCTAssertTrue(notifier.reminders.first?.body.hasPrefix("Starts in 3 min") ?? false,
                      "body: \(notifier.reminders.first?.body ?? "nil")")
        XCTAssertEqual(center.bannerEvent?.id, "evt")
    }

    func testDismissBannerHidesAndSurvivesRepoll() throws {
        let pool = try makePool()
        let base = Date()
        let event = makeEvent(id: "evt", start: base.addingTimeInterval(3 * 60))
        try insertEvent(pool, event: event)

        let center = MeetingReminderCenter(
            dbPool: pool,
            recorderCenter: makeRecorderCenter(recorder: ReminderFakeRecorder(), defaults: try isolatedDefaults()),
            notifier: ReminderFakeNotifier(),
            defaults: try isolatedDefaults(),
            now: { base }
        )

        center.poll()
        let banner = try XCTUnwrap(center.bannerEvent)
        center.dismissBanner(banner)
        XCTAssertNil(center.bannerEvent)

        center.poll()
        XCTAssertNil(center.bannerEvent, "a dismissed banner stays dismissed for this event")
    }

    func testPollTogglesOffSuppressPushButKeepBanner() throws {
        let pool = try makePool()
        let base = Date()
        try insertEvent(pool, event: makeEvent(id: "evt", start: base.addingTimeInterval(3 * 60)))

        let notifier = ReminderFakeNotifier()
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: MeetingReminderCenter.remindersEnabledKey)
        let center = MeetingReminderCenter(
            dbPool: pool,
            recorderCenter: makeRecorderCenter(recorder: ReminderFakeRecorder(), defaults: try isolatedDefaults()),
            notifier: notifier,
            defaults: defaults,
            now: { base }
        )

        center.poll()
        XCTAssertTrue(notifier.reminders.isEmpty, "the toggle gates the push")
        XCTAssertEqual(center.bannerEvent?.id, "evt", "the in-app banner needs no toggle")
    }

    func testStopPushFiresForOverdueEventLinkedRecordingAndRepeats() async throws {
        let pool = try makePool()
        var now = Date()
        // Event ended 5 minutes ago (past the 2-minute grace) while the
        // recording still runs.
        let event = makeEvent(id: "evt-stop", title: "Retro",
                              start: now.addingTimeInterval(-3600),
                              end: now.addingTimeInterval(-5 * 60))
        try insertEvent(pool, event: event)

        let recorderDefaults = try isolatedDefaults()
        let recorderCenter = makeRecorderCenter(recorder: ReminderFakeRecorder(), defaults: recorderDefaults)
        await recorderCenter.startRecording(eventID: "evt-stop", title: "Retro")
        guard case .recording = recorderCenter.phase else {
            return XCTFail("expected .recording, got \(recorderCenter.phase)")
        }

        let notifier = ReminderFakeNotifier()
        let center = MeetingReminderCenter(
            dbPool: pool,
            recorderCenter: recorderCenter,
            notifier: notifier,
            defaults: try isolatedDefaults(),
            now: { now }
        )

        center.poll()
        center.poll()
        XCTAssertEqual(notifier.stops.count, 1, "one push per 10-minute window")
        XCTAssertEqual(notifier.stops.first?.eventID, "evt-stop")

        now = now.addingTimeInterval(10 * 60)
        center.poll()
        XCTAssertEqual(notifier.stops.count, 2, "re-fires in the next 10-minute window")
    }

    func testStopPushExemptsAdHocRecording() async throws {
        let pool = try makePool()
        let base = Date()

        let recorderCenter = makeRecorderCenter(recorder: ReminderFakeRecorder(), defaults: try isolatedDefaults())
        await recorderCenter.startRecording(eventID: nil, title: nil)
        guard case .recording = recorderCenter.phase else {
            return XCTFail("expected .recording, got \(recorderCenter.phase)")
        }

        let notifier = ReminderFakeNotifier()
        let center = MeetingReminderCenter(
            dbPool: pool,
            recorderCenter: recorderCenter,
            notifier: notifier,
            defaults: try isolatedDefaults(),
            now: { base }
        )

        center.poll()
        XCTAssertTrue(notifier.stops.isEmpty, "ad-hoc recordings never trigger the stop push")
    }
}
