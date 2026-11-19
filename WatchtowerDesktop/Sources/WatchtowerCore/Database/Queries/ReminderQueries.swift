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

    /// Pending reminders still to fire in `(fromUTC, toUTC]`, earliest first.
    package static func fetchPending(_ db: Database, fromUTC: String, toUTC: String) throws -> [Reminder] {
        try Reminder.fetchAll(db, sql: """
            SELECT * FROM reminders
            WHERE status = 'pending' AND remind_at > ? AND remind_at <= ?
            ORDER BY remind_at ASC
            """, arguments: [fromUTC, toUTC])
    }

}
