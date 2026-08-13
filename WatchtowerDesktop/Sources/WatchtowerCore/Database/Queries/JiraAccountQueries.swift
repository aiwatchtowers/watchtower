import GRDB

package enum JiraAccountQueries {
    /// Every account still connected, oldest first. `jira remove` is
    /// non-destructive — it keeps the row (status 'removed') so historical
    /// issues stay attributable to their site — so a removed row must not
    /// surface as a manageable account.
    package static func fetchAll(_ db: Database) throws -> [JiraAccount] {
        try JiraAccount.fetchAll(
            db,
            sql: """
                SELECT * FROM jira_accounts
                WHERE status != 'removed'
                ORDER BY id ASC
                """
        )
    }

    /// The site URL browse links resolve against when no per-issue account is
    /// at hand: the first enabled, non-removed account with a resolved site.
    /// With one connected site (the common case) this is exact; with several,
    /// text-extracted issue keys are site-ambiguous by nature (documented v1
    /// limitation).
    package static func primarySiteURL(_ db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                SELECT site_url FROM jira_accounts
                WHERE enabled = 1 AND status != 'removed' AND site_url != ''
                ORDER BY id ASC LIMIT 1
                """
        )
    }
}
