import Foundation
import GRDB

/// Reads of the daemon-written purge ledger `account_purges` (board #601).
package enum AccountPurgeQueries {
    /// Every ledger column plus the account's label, status and last access.
    /// The label mirrors Go's `listPurgeAccountsSQL` (internal/db/account_purges.go).
    private static let selectSQL = """
        WITH accounts(source, id, label, status, access_ok_at) AS (
            SELECT 'slack', id, COALESCE(NULLIF(label, ''), NULLIF(team_name, ''), team_domain), status, access_ok_at
            FROM slack_accounts
            UNION ALL
            SELECT 'google', id, COALESCE(NULLIF(label, ''), email), status, access_ok_at FROM google_accounts
            UNION ALL
            SELECT 'jira', id, COALESCE(NULLIF(label, ''), NULLIF(site_name, ''), site_url), status, access_ok_at
            FROM jira_accounts
            UNION ALL
            SELECT 'linear', id, COALESCE(NULLIF(label, ''), NULLIF(org_name, ''), url_key), status, access_ok_at
            FROM linear_accounts
        )
        SELECT p.id, p.source, p.account_id, p.reason, p.state, p.due_at, p.finished_at, p.rows_deleted, p.error,
               COALESCE(a.label, '') AS account_label, COALESCE(a.status, '') AS account_status,
               COALESCE(a.access_ok_at, '') AS account_access_ok_at
        FROM account_purges p
        LEFT JOIN accounts a ON a.source = p.source AND a.id = p.account_id
        """

    /// Scheduled and running purges, newest first.
    package static func open(_ db: Database) throws -> [AccountPurge] {
        try AccountPurge.fetchAll(db, sql: selectSQL + """

            WHERE p.state IN ('scheduled', 'running') ORDER BY p.id DESC
            """)
    }

    /// Purges finished (done or failed) at or after `since`, newest first.
    /// `finished_at` is fixed-width UTC (`%Y-%m-%dT%H:%M:%SZ`), so text order
    /// is time order.
    package static func recent(_ db: Database, since: Date) throws -> [AccountPurge] {
        try AccountPurge.fetchAll(db, sql: selectSQL + """

            WHERE p.state IN ('done', 'failed') AND p.finished_at >= ? ORDER BY p.id DESC
            """, arguments: [PlanUsageDates.format(since)])
    }
}
