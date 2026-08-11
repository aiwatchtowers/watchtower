import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop

/// The warm-engine decision matrix (`WarmEnginePolicy.decide`) plus the
/// event-folding helper (`window(events:now:)`). Pure logic, so every branch
/// — including the degenerate no-meetings/toggle-off ones — is asserted
/// directly, with all dates derived from one reference `now` (no absolute
/// dates, the MeetingReminderCenterTests convention).
final class WarmEnginePolicyTests: XCTestCase {

    /// Fixed reference instant; every fixture time is an offset from it.
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    /// `decide` with the idle-and-empty defaults, so each test names only the
    /// dimensions it varies.
    private func decide(
        toggleEnabled: Bool = true,
        engineBusy: Bool = false,
        warmPresent: Bool = false,
        prewarmInFlight: Bool = false,
        keyMatches: Bool = true,
        window: WarmMeetingWindow = .noMeetings
    ) -> WarmEnginePolicy.Decision {
        WarmEnginePolicy.decide(
            toggleEnabled: toggleEnabled,
            engineBusy: engineBusy,
            warmPresent: warmPresent,
            prewarmInFlight: prewarmInFlight,
            keyMatches: keyMatches,
            window: window,
            now: now
        )
    }

    private func ongoing() -> WarmMeetingWindow {
        WarmMeetingWindow(hasOngoingMeeting: true, nextStart: nil)
    }

    private func startingIn(_ interval: TimeInterval) -> WarmMeetingWindow {
        WarmMeetingWindow(hasOngoingMeeting: false, nextStart: now.addingTimeInterval(interval))
    }

    // MARK: - Prewarm

    func testPrewarmsForOngoingMeeting() {
        XCTAssertEqual(decide(window: ongoing()), .prewarm)
    }

    func testPrewarmsForMeetingStartingWithinLead() {
        XCTAssertEqual(decide(window: startingIn(60)), .prewarm)
    }

    func testPrewarmsAtExactlyTheLeadBoundary() {
        XCTAssertEqual(decide(window: startingIn(WarmEnginePolicy.prewarmLead)), .prewarm)
    }

    func testNoPrewarmBeyondTheLead() {
        XCTAssertEqual(decide(window: startingIn(WarmEnginePolicy.prewarmLead + 1)), .none)
    }

    func testNoPrewarmWithNoMeetings() {
        // The steady-state degenerate tick: idle engine, empty calendar.
        XCTAssertEqual(decide(), .none)
    }

    func testNoPrewarmWhileToggleOff() {
        XCTAssertEqual(decide(toggleEnabled: false, window: ongoing()), .none)
    }

    func testNoPrewarmWhileEngineBusy() {
        XCTAssertEqual(decide(engineBusy: true, window: ongoing()), .none)
    }

    func testNoPrewarmWhilePrewarmInFlight() {
        XCTAssertEqual(decide(prewarmInFlight: true, window: ongoing()), .none)
    }

    func testNoPrewarmWhileWarmAlreadyPresent() {
        // Meeting soon + warm engine = hold, not a second load.
        XCTAssertEqual(decide(warmPresent: true, window: ongoing()), .none)
    }

    func testStaleNextStartInThePastDoesNotPrewarm() {
        // "Already started" is the ongoing flag's job; a stale provider value
        // must not read as "starts soon".
        XCTAssertEqual(decide(window: startingIn(-60)), .none)
    }

    // MARK: - Unload / hold

    func testUnloadsWarmEngineWithNoMeetings() {
        XCTAssertEqual(decide(warmPresent: true), .unload)
    }

    func testHoldsWarmEngineForOngoingMeeting() {
        XCTAssertEqual(decide(warmPresent: true, window: ongoing()), .none)
    }

    func testHoldsWarmEngineForMeetingWithinLead() {
        XCTAssertEqual(decide(warmPresent: true, window: startingIn(4 * 60)), .none)
    }

    func testUnloadsWarmEngineForMeetingBeyondLead() {
        XCTAssertEqual(decide(warmPresent: true, window: startingIn(6 * 60)), .unload)
    }

    func testUnloadsWarmEngineWhenToggleOff() {
        // Even mid-meeting: the user turned preloading off.
        XCTAssertEqual(decide(toggleEnabled: false, warmPresent: true, window: ongoing()), .unload)
    }

    func testUnloadsWarmEngineOnKeyMismatch() {
        // Settings switched provider/model — what is parked is not what a
        // recording would use, so the meeting cannot hold it.
        XCTAssertEqual(decide(warmPresent: true, keyMatches: false, window: ongoing()), .unload)
    }

    func testNeverUnloadsWhileEngineBusy() {
        // Defensive: the warm slot is empty while busy, but if it ever were
        // not, a busy tick must not touch it.
        XCTAssertEqual(decide(engineBusy: true, warmPresent: true), .none)
    }

    func testToggleOffWithNothingWarmIsANoOp() {
        XCTAssertEqual(decide(toggleEnabled: false), .none)
    }

    // MARK: - Event folding (window(events:now:))

    private static let iso: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    /// `CalendarEvent` has only `init(row:)` — build the fixture from a
    /// dictionary Row (the MeetingReminderCenterTests convention), with times
    /// derived from `start` so tests carry no hardcoded dates.
    private func makeEvent(
        id: String = "ev1",
        start: Date,
        end: Date? = nil,
        isAllDay: Bool = false
    ) -> CalendarEvent {
        let row: Row = [
            "id": id,
            "calendar_id": "cal1",
            "title": "Sync",
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
            "conference_url": "",
            "raw_json": "{}",
            "synced_at": "",
            "updated_at": ""
        ]
        return CalendarEvent(row: row)
    }

    func testWindowDetectsOngoingMeeting() {
        let window = WarmEnginePolicy.window(
            events: [makeEvent(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))],
            now: now
        )
        XCTAssertTrue(window.hasOngoingMeeting)
        XCTAssertNil(window.nextStart)
    }

    func testWindowMeetingStartingExactlyNowIsOngoingNotNext() {
        // startDate ≤ now < endDate.
        let window = WarmEnginePolicy.window(
            events: [makeEvent(start: now, end: now.addingTimeInterval(600))],
            now: now
        )
        XCTAssertTrue(window.hasOngoingMeeting)
        XCTAssertNil(window.nextStart, "a meeting starting exactly now is ongoing, never `next`")
    }

    func testWindowEndedMeetingIsNotOngoing() {
        let window = WarmEnginePolicy.window(
            events: [makeEvent(start: now.addingTimeInterval(-1200), end: now)],
            now: now
        )
        XCTAssertEqual(window, .noMeetings, "now == endDate is past the meeting (start ≤ now < end)")
    }

    func testWindowPicksEarliestUpcomingStart() {
        let sooner = now.addingTimeInterval(2 * 60)
        let window = WarmEnginePolicy.window(
            events: [
                makeEvent(id: "later", start: now.addingTimeInterval(4 * 60)),
                makeEvent(id: "sooner", start: sooner)
            ],
            now: now
        )
        XCTAssertEqual(window.nextStart, sooner)
        XCTAssertFalse(window.hasOngoingMeeting)
    }

    func testWindowIgnoresStartsBeyondTheLead() {
        let window = WarmEnginePolicy.window(
            events: [makeEvent(start: now.addingTimeInterval(WarmEnginePolicy.prewarmLead + 60))],
            now: now
        )
        XCTAssertEqual(window, .noMeetings)
    }

    func testWindowFiltersAllDayEvents() {
        // An ongoing all-day event and one "starting" within the lead: neither
        // may hold or load an engine.
        let window = WarmEnginePolicy.window(
            events: [
                makeEvent(id: "today", start: now.addingTimeInterval(-3600),
                          end: now.addingTimeInterval(3600), isAllDay: true),
                makeEvent(id: "soon", start: now.addingTimeInterval(60), isAllDay: true)
            ],
            now: now
        )
        XCTAssertEqual(window, .noMeetings)
    }

    func testWindowOfNoEventsIsNoMeetings() {
        XCTAssertEqual(WarmEnginePolicy.window(events: [], now: now), .noMeetings)
    }
}
