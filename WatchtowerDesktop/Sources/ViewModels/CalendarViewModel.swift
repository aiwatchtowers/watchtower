import Foundation
import GRDB
import WatchtowerCore

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

    /// The last failed "Synced Calendars" toggle, shown under the list;
    /// cleared by the next toggle.
    private(set) var calendarSelectionError: String?

    /// Non-nil when the daemon has detected that the Google refresh token is revoked or failing.
    /// The Desktop shows a reconnect popup while this is present.
    var authState: CalendarQueries.AuthState?

    private let dbPool: DatabasePool
    private var observationTask: Task<Void, Never>?
    private var refreshGate = ForegroundRefreshGate()
    /// The load `setOnScreen` started — held so tests can await it.
    private(set) var onScreenRefresh: Task<Void, Never>?
    private var loadsStarted = 0
    private var loadApplied = 0

    /// Number of future days to display (including today).
    private let daysAhead = 7

    /// Days of past events to display — `calendar.history_days` from the
    /// config (the same knob that widens the Go syncers' timeMin), fallback 30.
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

    /// What one load reads, applied in one go.
    private struct Snapshot {
        var days: [DayEvents]
        var next: CalendarEvent?
        var auth: CalendarQueries.AuthState?
        var calendars: [CalendarCalendarItem]
        var hasEvents: Bool
    }

    /// Reloads synchronously — the deep link (`ensureVisible`) expands and
    /// scrolls right after it returns. The periodic refresh reads off the
    /// main actor instead (`reload`).
    func loadEvents() {
        let token = beginLoad()
        let window = currentWindow()
        apply(Result { try dbPool.read { try Self.read($0, dayStarts: window.days, calendar: window.calendar) } }, token: token)
    }

    /// The same load, its read off the main actor (the poll and the return
    /// on screen).
    func reload() async {
        let token = beginLoad()
        let window = currentWindow()
        let result: Result<Snapshot, Error>
        do {
            result = .success(try await dbPool.read { try Self.read($0, dayStarts: window.days, calendar: window.calendar) })
        } catch {
            result = .failure(error)
        }
        apply(result, token: token)
    }

    /// The UI went on or off screen (board #731): off screen the poll skips
    /// its loads; back on screen after a skipped one, it loads at once.
    func setOnScreen(_ onScreen: Bool) {
        guard refreshGate.setOnScreen(onScreen) else { return }
        onScreenRefresh = Task { await reload() }
    }

    /// One tick of the 30 s poll (its loop's body; tests call it directly).
    func pollTick() async {
        if refreshGate.tick() { await reload() }
    }

    private func currentWindow() -> (days: [Date], calendar: Calendar) {
        let cal = Calendar.current
        let days = Self.dayWindow(
            today: cal.startOfDay(for: Date()), historyDays: historyDays, daysAhead: daysAhead,
            pinned: pinnedDate, calendar: cal)
        return (days, cal)
    }

    /// Loads overlap (a poll, a deep link's synchronous one): only one
    /// started after the last applied load lands, so a slow older read never
    /// undoes a newer one.
    private func beginLoad() -> Int {
        loadsStarted += 1
        return loadsStarted
    }

    nonisolated private static func read(_ db: Database, dayStarts: [Date], calendar cal: Calendar) throws -> Snapshot {
        let days = try CalendarQueries.fetchEventsByDay(db, dayStarts: dayStarts).map {
            DayEvents(id: $0.day, label: label(for: $0.day, calendar: cal), events: $0.events)
        }
        return Snapshot(
            days: days,
            next: try CalendarQueries.fetchNextEvent(db),
            auth: try? CalendarQueries.fetchAuthState(db),
            calendars: try CalendarQueries.fetchCalendarsGroupedForSettings(db),
            hasEvents: try CalendarQueries.eventCount(db) > 0
        )
    }

    /// A failed read is logged and keeps what was shown — the reconnect
    /// prompt included — until a read succeeds.
    private func apply(_ result: Result<Snapshot, Error>, token: Int) {
        guard token > loadApplied else { return }
        loadApplied = token
        let snapshot: Snapshot
        switch result {
        case let .success(read):
            snapshot = read
        case let .failure(error):
            print("[Calendar] load failed, keeping the last events: \(error.localizedDescription)")
            return
        }
        dailyEvents = snapshot.days
        nextEvent = snapshot.next
        calendars = snapshot.calendars
        if let auth = snapshot.auth, auth.status == "revoked" || auth.status == "error" {
            authState = auth
        } else {
            authState = nil
        }
        isConnected = snapshot.hasEvents
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
        calendarSelectionError = nil
        Task {
            do {
                try await dbPool.write { db in
                    try CalendarQueries.setCalendarSelected(db, id: id, selected: selected)
                }
            } catch {
                calendarSelectionError = "Failed to update the calendar: \(error.localizedDescription)"
            }
            // Either way: a calendar the sync dropped leaves the list.
            loadEvents()
        }
    }

    // MARK: - Helpers

    nonisolated private static func label(for date: Date, calendar cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.dateFormat = "EEEE, d MMM"
        return fmt.string(from: date)
    }

    // MARK: - Observation

    /// Every 30 s while the UI is on screen (`refreshGate`): the daemon
    /// writes the events from another process, so GRDB observation never
    /// fires. Every consumer is on screen (the Calendar tab, the sidebar's
    /// next meeting, Settings, the reconnect prompt); the meeting reminders
    /// and the warm engine read the calendar themselves.
    private func startObserving() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { break }
                await self.pollTick()
            }
        }
    }
}
