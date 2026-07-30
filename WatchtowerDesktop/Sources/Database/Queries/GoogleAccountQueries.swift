import GRDB

enum GoogleAccountQueries {
    static func fetchAll(_ db: Database) throws -> [GoogleAccount] {
        try GoogleAccount.fetchAll(
            db,
            sql: "SELECT * FROM google_accounts ORDER BY id ASC"
        )
    }
}
