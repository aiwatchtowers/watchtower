import Foundation

/// Snooze duration options for a card action row. Shared by the legacy Inbox
/// feed (`InboxCardView`) and the Dashboard situation review pane
/// (`SituationReviewPane`) so both pick from the same three options with
/// identical date math.
enum SnoozeOption {
    case oneHour
    case tillTomorrow
    case tillMonday
}

/// Computes the ISO8601 "snooze until" timestamp for a `SnoozeOption`.
///
/// Lifted out of `InboxFeedView.snoozeItem` so `DashboardView`'s situation
/// feed doesn't duplicate the calendar math — both call sites just need a
/// string to pass into their respective `snooze(..., until:)` query.
enum SnoozeDates {
    static func until(_ option: SnoozeOption, from now: Date = Date(), calendar: Calendar = .current) -> String {
        let target: Date
        switch option {
        case .oneHour:
            target = calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        case .tillTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            target = calendar.startOfDay(for: tomorrow)
        case .tillMonday:
            var comps = DateComponents()
            comps.weekday = 2 // Monday
            let monday = calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now
            target = calendar.startOfDay(for: monday)
        }
        return iso8601String(target)
    }

    private static func iso8601String(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }
}
