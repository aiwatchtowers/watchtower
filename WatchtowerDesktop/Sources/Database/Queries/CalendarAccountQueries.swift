import GRDB
import WatchtowerCore

enum CalendarAccountQueries {
    static func fetchAll(_ db: Database) throws -> [CalendarAccount] {
        try CalendarAccount.fetchAll(
            db,
            sql: "SELECT * FROM calendar_accounts ORDER BY created_at ASC"
        )
    }
}
