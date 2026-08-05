import Foundation
import GRDB

struct DayEvents: Identifiable, Equatable {
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

    /// Number of future days to display (including today).
    private let daysAhead = 7

    /// Days of past events to display — `calendar.history_days` from the
    /// config (the same knob that widens the Go syncers' timeMin), fallback 14.
    let historyDays: Int

    /// Extra day pinned into the rendered window by a deep link whose event
    /// falls outside the -historyDays..+daysAhead window — e.g. an event past
    /// +7d when calendar.sync_days_ahead is configured larger. Kept across
    /// reloads so the periodic observer can't evict the day while the user
    /// looks at it.
    private var pinnedDate: Date?

    /// `historyDays` is injectable for tests; nil reads the config file.
    init(dbPool: DatabasePool, historyDays: Int? = nil) {
        self.dbPool = dbPool
        self.historyDays = max(1, historyDays ?? ConfigService().calendarHistoryDays)
        loadEvents()
        startObserving()
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Convenience accessors (backward compat)

    /// Keyed by date, not list position — with past days in `dailyEvents`
    /// the first group is no longer necessarily today.
    var todayEvents: [CalendarEvent] {
        events(startingAt: Calendar.current.startOfDay(for: Date()))
    }

    var tomorrowEvents: [CalendarEvent] {
        events(startingAt: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400))
    }

    private func events(startingAt dayStart: Date) -> [CalendarEvent] {
        dailyEvents.first { $0.id == dayStart }?.events ?? []
    }

    // MARK: - Data Loading

    func loadEvents() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayStarts = Self.dayWindow(
            today: today, historyDays: historyDays, daysAhead: daysAhead,
            pinned: pinnedDate, calendar: cal)

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

    /// Day-start dates for the rendered window: -historyDays..+daysAhead plus
    /// the pinned day when it falls outside that range (deduped by calendar
    /// day, sorted so a past pin renders first). Pure — unit-tested directly.
    static func dayWindow(
        today: Date, historyDays: Int = 0, daysAhead: Int, pinned: Date?, calendar cal: Calendar
    ) -> [Date] {
        var days = (-historyDays..<daysAhead).map { today.addingTimeInterval(Double($0) * 86400) }
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
