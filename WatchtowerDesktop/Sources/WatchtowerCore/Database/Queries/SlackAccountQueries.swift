import GRDB

package enum SlackAccountQueries {
    package static func fetchAll(_ db: Database) throws -> [SlackAccount] {
        try SlackAccount.fetchAll(
            db,
            sql: "SELECT * FROM slack_accounts ORDER BY id ASC"
        )
    }

    /// Whether any Slack account is connected: an enabled, non-removed
    /// `slack_accounts` row. The multi-account replacement for the retired
    /// config.yaml `slack_token` check — `ensureLegacySlackAccount` moves that
    /// token into `slack_token_1.json` and blanks it, and a fresh install never
    /// writes one at all.
    package static func hasConnectedAccount(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM slack_accounts WHERE enabled = 1 AND status != 'removed')"
        ) ?? false
    }

    /// Team id per account id, every row (disabled/removed accounts included —
    /// their already-synced data still renders links). An empty team id is kept
    /// as-is; `SlackLinkResolver` treats it as "fall back".
    package static func fetchTeamIDs(_ db: Database) throws -> [Int: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT id, team_id FROM slack_accounts")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int, ($0["team_id"] as String?) ?? "") })
    }
}
