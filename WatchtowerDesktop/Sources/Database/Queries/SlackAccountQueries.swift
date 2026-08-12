import GRDB
import WatchtowerCore

enum SlackAccountQueries {
    static func fetchAll(_ db: Database) throws -> [SlackAccount] {
        try SlackAccount.fetchAll(
            db,
            sql: "SELECT * FROM slack_accounts ORDER BY id ASC"
        )
    }
}
