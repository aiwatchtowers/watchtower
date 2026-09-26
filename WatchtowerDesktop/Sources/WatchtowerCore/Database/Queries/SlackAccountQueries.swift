import GRDB

package enum SlackAccountQueries {
    package static func fetchAll(_ db: Database) throws -> [SlackAccount] {
        try SlackAccount.fetchAll(
            db,
            sql: "SELECT * FROM slack_accounts ORDER BY id ASC"
        )
    }

    /// Team id per account id, every row (disabled/removed accounts included —
    /// their already-synced data still renders links). An empty team id is kept
    /// as-is; `SlackLinkResolver` treats it as "fall back".
    package static func fetchTeamIDs(_ db: Database) throws -> [Int: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT id, team_id FROM slack_accounts")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int, ($0["team_id"] as String?) ?? "") })
    }
}
