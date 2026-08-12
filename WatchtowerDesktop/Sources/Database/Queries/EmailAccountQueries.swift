import GRDB
import WatchtowerCore

enum EmailAccountQueries {
    static func fetchAll(_ db: Database) throws -> [EmailAccount] {
        try EmailAccount.fetchAll(
            db,
            sql: "SELECT * FROM email_accounts ORDER BY created_at ASC"
        )
    }
}
