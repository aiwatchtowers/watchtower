import GRDB

package enum ReminderQueries {
    /// Pending reminders whose `remind_at` has passed, earliest first.
    /// The badge twin of `fetchDue`: how many reminders are due right now.
    package static func dueCount(_ db: Database, nowUTC: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reminders WHERE status = 'pending' AND remind_at <= ?", arguments: [nowUTC]) ?? 0
    }

    package static func fetchDue(_ db: Database, nowUTC: String) throws -> [Reminder] {
        try Reminder.fetchAll(db, sql: """
            SELECT * FROM reminders
            WHERE status = 'pending' AND remind_at <= ?
            ORDER BY remind_at ASC
            """, arguments: [nowUTC])
    }

    /// Marks a reminder done — Swift-owned, no daemon contention (the
    /// `inbox_feedback` dual-path precedent). Mirrors Go's `MarkReminderDone`.
    package static func markDone(_ db: Database, id: Int64) throws {
        try db.execute(sql: """
            UPDATE reminders SET status='done', done_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?
            """, arguments: [id])
    }

    /// Bumps a reminder's `remind_at` to a later moment, leaving it pending.
    /// Mirrors Go's `SnoozeReminder`.
    package static func snooze(_ db: Database, id: Int64, until: String) throws {
        try db.execute(sql: "UPDATE reminders SET remind_at=?, status='pending' WHERE id=?", arguments: [until, id])
    }
}
