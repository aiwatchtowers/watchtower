import Foundation

/// The Morning brief's days (spec "One brief row"): its History of the
/// last 30 days and the stepper's ‹ › moves. Pure.
///
/// Both read the feed's day cards, whose first page
/// (`ActionStripViewModel.dayPage`, 30 dates, newest first) always holds
/// every card of the window, so History is complete, never "loaded so far".
package enum InboxBriefDays {
    package enum Step: Sendable {
        case older, newer
    }

    /// How many dates History covers, today included.
    package static let window = 30

    /// The days within the last `window` dates that have a briefing or a
    /// plan, today included, newest first. `today` is the "yyyy-MM-dd" of
    /// `now`.
    package static func history(
        _ days: [InboxDayCard],
        today: String,
        now: Date,
        calendar: Calendar
    ) -> [InboxDayCard] {
        let first = firstDate(now: now, calendar: calendar)
        return days
            .filter { $0.date <= today && $0.date >= first && !$0.isEmpty }
            .sorted { $0.date > $1.date }
    }

    /// The oldest date of the window ending today: today minus
    /// `window - 1` days, as "yyyy-MM-dd".
    package static func firstDate(now: Date, calendar: Calendar) -> String {
        let start = InboxToday.startOfToday(now: now, calendar: calendar)
        let first = calendar.date(byAdding: .day, value: -(window - 1), to: start) ?? start
        return HomeFeedBuilder.dayString(first, calendar: calendar)
    }

    /// The next date from `date` with a briefing or a plan in `days`
    /// (today always counts: its placeholder stands in for it); nil past
    /// the ends. Newer never passes today.
    package static func step(from date: String, _ step: Step, in days: [InboxDayCard], today: String) -> String? {
        let listed = Set(days.filter { !$0.isEmpty && $0.date <= today }.map(\.date)).union([today])
        switch step {
        case .older: return listed.filter { $0 < date }.max()
        case .newer: return listed.filter { $0 > date }.min()
        }
    }
}
