import Foundation
import GRDB

enum CalendarQueries {

    // MARK: - ISO8601 Helper

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    // MARK: - Fetch Events

    static func fetchTodayEvents(_ db: Database) throws -> [CalendarEvent] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let endOfDay = startOfDay.addingTimeInterval(86400)
        return try fetchEvents(
            db,
            from: startOfDay,
            to: endOfDay
        )
    }

    static func fetchEvents(
        _ db: Database,
        from: Date,
        to: Date
    ) throws -> [CalendarEvent] {
        try CalendarEvent.fetchAll(
            db,
            sql: """
                SELECT * FROM calendar_events
                WHERE start_time <= ? AND end_time >= ?
                ORDER BY start_time ASC
                """,
            arguments: [iso8601(to), iso8601(from)]
        )
    }

    static func fetchNextEvent(_ db: Database) throws -> CalendarEvent? {
        let now = iso8601(Date())
        return try CalendarEvent.fetchOne(
            db,
            sql: """
                SELECT * FROM calendar_events
                WHERE start_time > ? AND is_all_day = 0
                ORDER BY start_time ASC
                LIMIT 1
                """,
            arguments: [now]
        )
    }

    static func fetchEvent(
        _ db: Database,
        id: String
    ) throws -> CalendarEvent? {
        try CalendarEvent.fetchOne(
            db,
            sql: "SELECT * FROM calendar_events WHERE id = ?",
            arguments: [id]
        )
    }

    static func eventCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM calendar_events"
        ) ?? 0
    }

    // MARK: - Calendar List

    static func fetchCalendars(_ db: Database) throws -> [CalendarCalendarItem] {
        try CalendarCalendarItem.fetchAll(
            db,
            sql: "SELECT * FROM calendar_calendars ORDER BY is_primary DESC, name"
        )
    }

    static func fetchSelectedCalendarIDs(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT id FROM calendar_calendars WHERE is_selected = 1"
        )
    }

    static func calendarCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM calendar_calendars"
        ) ?? 0
    }

    /// Calendars for the Settings "Synced Calendars" section, pre-ordered so
    /// Google-linked rows are grouped by their owning account and CalDAV/ICS
    /// rows (`account_id IS NULL`) sort last — the View groups this flat list
    /// by account (see `SettingsView.calendarSelectionSection`).
    static func fetchCalendarsGroupedForSettings(_ db: Database) throws -> [CalendarCalendarItem] {
        try CalendarCalendarItem.fetchAll(
            db,
            sql: """
                SELECT * FROM calendar_calendars
                ORDER BY (account_id IS NULL), account_id, is_primary DESC, name
                """
        )
    }

    /// Flips ONLY `is_selected` — the Desktop twin of `watchtower calendar
    /// select <id>` / `SetCalendarSelected` in internal/db/calendar.go: a
    /// direct single-column write, no side effects.
    static func setCalendarSelected(_ db: Database, id: String, selected: Bool) throws {
        try db.execute(
            sql: "UPDATE calendar_calendars SET is_selected = ? WHERE id = ?",
            arguments: [selected, id]
        )
    }

    // MARK: - Auth State

    struct AuthState: Equatable {
        let status: String   // "ok" | "revoked" | "error"
        let error: String
        let updatedAt: String
    }

    /// Returns the Calendar-enabled Google account whose OAuth grant needs
    /// attention (most-recently-updated row with `status IN ('error',
    /// 'revoked')`), or nil when every Calendar-enabled account is healthy
    /// (or there are none). Was `calendar_auth_state`, a single-row table
    /// DROPPED by migration 00043 in favor of one row per Google account in
    /// `google_accounts` — nil here means "nothing needs reconnecting", not
    /// "older schema" (that framing described the pre-multi-account table,
    /// which no longer exists).
    static func fetchAuthState(_ db: Database) throws -> AuthState? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT status, error, updated_at FROM google_accounts
                WHERE calendar_enabled = 1 AND status IN ('error', 'revoked')
                ORDER BY updated_at DESC
                LIMIT 1
                """
        )
        guard let row else { return nil }
        return AuthState(
            status: row["status"] ?? "ok",
            error: row["error"] ?? "",
            updatedAt: row["updated_at"] ?? ""
        )
    }
}
