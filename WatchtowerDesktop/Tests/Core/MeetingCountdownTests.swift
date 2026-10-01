import XCTest
@testable import WatchtowerCore

final class MeetingCountdownTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")

    /// 08:00 today (UTC), seeded from the real clock.
    private var morning: Date { calendar.startOfDay(for: Date()).addingTimeInterval(8 * 3600) }

    private func text(_ offset: TimeInterval, from now: Date) -> String {
        MeetingCountdown.text(start: now.addingTimeInterval(offset), now: now, calendar: calendar, locale: locale)
    }

    func testCountsDownInHoursAndMinutesWithinTheHorizon() {
        let now = morning
        XCTAssertEqual(text(59 * 60 + 59, from: now), "in 59 min")
        XCTAssertEqual(text(3600, from: now), "in 1 h")
        XCTAssertEqual(text(2 * 3600 + 5 * 60 + 30, from: now), "in 2 h 5 min")
        XCTAssertEqual(text(MeetingCountdown.countdownHorizon - 60, from: now), "in 5 h 59 min")
    }

    func testFarMeetingsShowTheirStartTimeInsteadOfAMinuteCount() {
        let now = morning
        // The board's case: 17 h 45 min away reads as a start time, never "in 1065 min".
        XCTAssertEqual(text(7 * 3600, from: now), "today 15:00")
        XCTAssertEqual(text(17 * 3600 + 45 * 60, from: now), "tomorrow 01:45")
        XCTAssertEqual(text(26 * 3600, from: now), "tomorrow 10:00")
        let weekday = text(3 * 86400, from: now)
        XCTAssertTrue(weekday.hasSuffix(" 08:00") && !weekday.hasPrefix("in"), weekday)
        let far = text(20 * 86400 + 3600, from: now)
        XCTAssertTrue(far.hasSuffix(" 09:00") && far != weekday, far)
    }

    func testEveryResultIsShort() {
        let now = morning
        for offset in stride(from: 0.0, through: 40 * 86400, by: 1789) {
            XCTAssertLessThanOrEqual(text(offset, from: now).count, 16, "offset \(offset)")
        }
    }
}
