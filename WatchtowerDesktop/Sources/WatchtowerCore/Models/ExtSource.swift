import GRDB

/// One selected external container — today a Confluence space — from the
/// `ext_sources` table (internal/db/migrations/00074). Written by the Go CLI
/// (`confluence select`/`unselect`) and the daemon's external-sync phase;
/// the Desktop only reads it. Only the columns the Settings picker shows are
/// decoded — cursors and page tokens are the engine's business.
package struct ExtSource: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int64
    package let jiraAccountID: Int64
    package let containerKey: String
    package let containerName: String
    /// ok | error | needs_consent | revoked (the table's CHECK).
    package let status: String
    package let error: String
    /// False until the first full enumeration finishes. A budget-cut first
    /// run still stamps `lastSyncedAt`, so this — not the timestamp — says
    /// whether the space is still syncing.
    package let backfillDone: Bool
    /// UTC `%Y-%m-%dT%H:%M:%SZ`, empty before the first sync.
    package let lastSyncedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case jiraAccountID = "jira_account_id"
        case containerKey = "container_key"
        case containerName = "container_name"
        case status, error
        case backfillDone = "backfill_done"
        case lastSyncedAt = "last_synced_at"
    }
}
