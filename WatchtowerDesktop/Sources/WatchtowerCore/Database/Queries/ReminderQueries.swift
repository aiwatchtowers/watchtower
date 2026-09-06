import GRDB

package enum ReminderQueries {
    /// Pending reminders whose `remind_at` has passed, earliest first.
    package static func fetchDue(_ db: Database, nowUTC: String) throws -> [Reminder] {
        try Reminder.fetchAll(db, sql: """
            SELECT * FROM reminders
            WHERE status = 'pending' AND remind_at <= ?
            ORDER BY remind_at ASC
            """, arguments: [nowUTC])
    }
}
