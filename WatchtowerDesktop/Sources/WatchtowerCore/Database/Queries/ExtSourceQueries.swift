import GRDB

/// Read-only queries over the external-source tables (`ext_sources`,
/// `ext_documents`, migration 00074). Every write goes through the Go CLI,
/// which also validates keys against the live site.
package enum ExtSourceQueries {
    /// The Jira account's selected spaces, ordered by display name (key as
    /// the tie-break so the order is stable).
    package static func fetchForJiraAccount(_ db: Database, accountID: Int64) throws -> [ExtSource] {
        try ExtSource.fetchAll(
            db,
            sql: """
                SELECT id, jira_account_id, container_key, container_name,
                       status, error, backfill_done, last_synced_at
                FROM ext_sources
                WHERE jira_account_id = ?
                ORDER BY container_name COLLATE NOCASE, container_key
                """,
            arguments: [accountID]
        )
    }

    /// Synced documents of one source — pages, blog posts and attachments
    /// (every `ext_documents.kind`; comments live in `ext_comments` and are
    /// not documents).
    package static func documentCount(_ db: Database, sourceID: Int64) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM ext_documents WHERE source_id = ?",
            arguments: [sourceID]
        ) ?? 0
    }
}
