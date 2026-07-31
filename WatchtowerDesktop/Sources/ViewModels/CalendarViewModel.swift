import Foundation
import GRDB

struct DayEvents: Identifiable {
    let id: Date
    let label: String
    let events: [CalendarEvent]
}

@MainActor
@Observable
final class CalendarViewModel {
    var dailyEvents: [DayEvents] = []
    var nextEvent: CalendarEvent?
    var isConnected: Bool = false

    /// Calendars grouped for the Settings "Synced Calendars" section —
    /// reloaded together with events on `loadEvents()`.
    private(set) var calendars: [CalendarCalendarItem] = []

    /// Non-nil when the daemon has detected that the Google refresh token is revoked or failing.
    /// The Desktop shows a reconnect popup while this is present.
    var authState: CalendarQueries.AuthState?

    private let dbPool: DatabasePool
    private var observationTask: Task<Void, Never>?

    /// Number of days to display (including today).
    private let daysAhead = 7

    /// Extra day pinned into the rendered window by a deep link whose event
    /// falls outside today..+daysAhead — e.g. yesterday's recording reviewed
    /// the morning after (sync retains ~24h back) or an event past +7d when
    /// calendar.sync_days_ahead is configured larger. Kept across reloads so
    /// the periodic observer can't evict the day while the user looks at it.
    private var pinnedDate: Date?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        loadEvents()
        startObserving()
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Convenience accessors (backward compat)

    var todayEvents: [CalendarEvent] {
        dailyEvents.first?.events ?? []
    }

    var tomorrowEvents: [CalendarEvent] {
        dailyEvents.dropFirst().first?.events ?? []
    }

    // MARK: - Data Loading

    func loadEvents() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayStarts = Self.dayWindow(
            today: today, daysAhead: daysAhead, pinned: pinnedDate, calendar: cal)

        let result = try? dbPool.read { db -> ([DayEvents], CalendarEvent?, CalendarQueries.AuthState?, [CalendarCalendarItem]) in
            var days: [DayEvents] = []
            for dayStart in dayStarts {
                let dayEnd = dayStart.addingTimeInterval(86400)
                let items = try CalendarQueries.fetchEvents(db, from: dayStart, to: dayEnd)
                if !items.isEmpty {
                    let label = Self.label(for: dayStart, calendar: cal)
                    days.append(DayEvents(id: dayStart, label: label, events: items))
                }
            }
            let next = try CalendarQueries.fetchNextEvent(db)
            let auth = try? CalendarQueries.fetchAuthState(db)
            let cals = try CalendarQueries.fetchCalendarsGroupedForSettings(db)
            return (days, next, auth, cals)
        }

        dailyEvents = result?.0 ?? []
        nextEvent = result?.1
        calendars = result?.3 ?? []

        let auth = result?.2
        if let auth, auth.status == "revoked" || auth.status == "error" {
            authState = auth
        } else {
            authState = nil
        }

        let hasEvents = (try? dbPool.read { db in
            try CalendarQueries.eventCount(db) > 0
        }) ?? false
        isConnected = hasEvents
    }

    /// Ensure the day containing `date` is part of the rendered window,
    /// pinning it and reloading synchronously when it isn't (deep-link target
    /// outside today..+daysAhead — the caller may expand/scroll to the event
    /// immediately after this returns).
    func ensureVisible(date: Date) {
        pinnedDate = Calendar.current.startOfDay(for: date)
        loadEvents()
    }

    /// Day-start dates for the rendered window: today..+daysAhead plus the
    /// pinned day when it falls outside that range (deduped by calendar day,
    /// sorted so a past pin renders first). Pure — unit-tested directly.
    static func dayWindow(today: Date, daysAhead: Int, pinned: Date?, calendar cal: Calendar) -> [Date] {
        var days = (0..<daysAhead).map { today.addingTimeInterval(Double($0) * 86400) }
        if let pinned, !days.contains(where: { cal.isDate($0, inSameDayAs: pinned) }) {
            days.append(cal.startOfDay(for: pinned))
            days.sort()
        }
        return days
    }

    /// Flips a single calendar's sync selection (Desktop twin of `watchtower
    /// calendar select <id>`), then reloads so Settings reflects the new
    /// state immediately.
    func setCalendarSelected(_ id: String, selected: Bool) {
        Task {
            try? await dbPool.write { db in
                try CalendarQueries.setCalendarSelected(db, id: id, selected: selected)
            }
            loadEvents()
        }
    }

    // MARK: - Helpers

    private static func label(for date: Date, calendar cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.dateFormat = "EEEE, d MMM"
        return fmt.string(from: date)
    }

    // MARK: - Observation

    private func startObserving() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { break }
                self.loadEvents()
            }
        }
    }
}
