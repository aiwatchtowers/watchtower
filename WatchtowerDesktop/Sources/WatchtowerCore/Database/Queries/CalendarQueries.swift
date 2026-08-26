import Foundation
import GRDB

package enum CalendarQueries {

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

    /// Every CalendarEvent-building query selects through this: all
    /// `calendar_events` columns plus `account_email`, resolved from the
    /// owning Google account via `calendar_id` → `calendar_calendars` →
    /// `google_accounts`. LEFT JOINs so events on CalDAV/ICS calendars
    /// (`account_id IS NULL`) still return, just with a NULL `account_email`.
    /// Feeds `CalendarEvent.joinURL`'s Google Meet `authuser` hint.
    private static let selectWithAccountEmail = """
        SELECT calendar_events.*, google_accounts.email AS account_email
        FROM calendar_events
        LEFT JOIN calendar_calendars ON calendar_calendars.id = calendar_events.calendar_id
        LEFT JOIN google_accounts ON google_accounts.id = calendar_calendars.account_id
        """

    package static func fetchTodayEvents(_ db: Database) throws -> [CalendarEvent] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let endOfDay = startOfDay.addingTimeInterval(86400)
        return try fetchEvents(
            db,
            from: startOfDay,
            to: endOfDay
        )
    }

    package static func fetchEvents(
        _ db: Database,
        from: Date,
        to: Date
    ) throws -> [CalendarEvent] {
        try CalendarEvent.fetchAll(
            db,
            sql: """
                \(selectWithAccountEmail)
                WHERE calendar_events.start_time <= ? AND calendar_events.end_time >= ?
                ORDER BY calendar_events.start_time ASC
                """,
            arguments: [iso8601(to), iso8601(from)]
        )
    }

    package static func fetchNextEvent(_ db: Database) throws -> CalendarEvent? {
        let now = iso8601(Date())
        return try CalendarEvent.fetchOne(
            db,
            sql: """
                \(selectWithAccountEmail)
                WHERE calendar_events.start_time > ? AND calendar_events.is_all_day = 0
                ORDER BY calendar_events.start_time ASC
                LIMIT 1
                """,
            arguments: [now]
        )
    }

    package static func fetchEvent(
        _ db: Database,
        id: String
    ) throws -> CalendarEvent? {
        try CalendarEvent.fetchOne(
            db,
            sql: "\(selectWithAccountEmail) WHERE calendar_events.id = ?",
            arguments: [id]
        )
    }

    package static func eventCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM calendar_events"
        ) ?? 0
    }

    // MARK: - Linked-Event Stub

    /// Minimal projection for "linked to event X" affordances (recording
    /// header, list subtitles): deliberately id/title/start_time only so
    /// resolving a link never deserializes attendees/raw_json blobs.
    package struct EventLink: FetchableRecord, Equatable {
        package let id: String
        package let title: String
        package let startTime: String   // ISO8601

        package init(row: Row) {
            id = row["id"]
            title = row["title"] ?? ""
            startTime = row["start_time"] ?? ""
        }

        /// Parsed start time; nil for a malformed/empty `start_time` (such an
        /// event can't be placed on any day list, so deep-link callers just
        /// skip the window pin).
        package var startDate: Date? {
            CalendarQueries.iso8601Formatter.date(from: startTime)
        }
    }

    /// Lightweight title/date resolution for a recording's linked event.
    /// Returns nil when the event row no longer exists (pruned by sync
    /// retention) — callers must degrade gracefully, never error.
    package static func fetchEventLink(_ db: Database, id: String) throws -> EventLink? {
        try EventLink.fetchOne(
            db,
            sql: "SELECT id, title, start_time FROM calendar_events WHERE id = ?",
            arguments: [id]
        )
    }

    // MARK: - Calendar List

    package static func fetchCalendars(_ db: Database) throws -> [CalendarCalendarItem] {
        try CalendarCalendarItem.fetchAll(
            db,
            sql: "SELECT * FROM calendar_calendars ORDER BY is_primary DESC, name"
        )
    }

    package static func fetchSelectedCalendarIDs(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT id FROM calendar_calendars WHERE is_selected = 1"
        )
    }

    package static func calendarCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM calendar_calendars"
        ) ?? 0
    }

    /// Calendars for the Settings "Synced Calendars" section, pre-ordered so
    /// Google-linked rows are grouped by their owning account and CalDAV/ICS
    /// rows (`account_id IS NULL`) sort last — the View groups this flat list
    /// by account (see `SettingsView.calendarSelectionSection`).
    package static func fetchCalendarsGroupedForSettings(_ db: Database) throws -> [CalendarCalendarItem] {
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
    package static func setCalendarSelected(_ db: Database, id: String, selected: Bool) throws {
        try db.execute(
            sql: "UPDATE calendar_calendars SET is_selected = ? WHERE id = ?",
            arguments: [selected, id]
        )
    }

    // MARK: - Auth State

    package struct AuthState: Equatable {
        /// The specific google_accounts row this state describes — required
        /// so the reconnect flow can target THIS account (`google login
        /// --account <id>`) rather than falling back to the CLI's generic
        /// "account #1" alias, which may be a different, healthy account in
        /// a multi-account workspace (N2).
        package let accountID: Int
        package let status: String   // "ok" | "revoked" | "error"
        package let error: String
        package let updatedAt: String
    }

    /// Returns the Calendar-enabled Google account whose OAuth grant needs
    /// attention (most-recently-updated row with `status IN ('error',
    /// 'revoked')`), or nil when every Calendar-enabled account is healthy
    /// (or there are none). Was `calendar_auth_state`, a single-row table
    /// DROPPED by migration 00043 in favor of one row per Google account in
    /// `google_accounts` — nil here means "nothing needs reconnecting", not
    /// "older schema" (that framing described the pre-multi-account table,
    /// which no longer exists).
    package static func fetchAuthState(_ db: Database) throws -> AuthState? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, status, error, updated_at FROM google_accounts
                WHERE calendar_enabled = 1 AND status IN ('error', 'revoked')
                ORDER BY updated_at DESC
                LIMIT 1
                """
        )
        guard let row else { return nil }
        return AuthState(
            accountID: row["id"] ?? 0,
            status: row["status"] ?? "ok",
            error: row["error"] ?? "",
            updatedAt: row["updated_at"] ?? ""
        )
    }
}
