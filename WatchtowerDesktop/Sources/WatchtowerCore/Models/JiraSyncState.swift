import GRDB

package struct JiraSyncState: Codable, FetchableRecord, TableRecord {
    package static let databaseTableName = "jira_sync_state"
    package let projectKey: String
    package var lastSyncedAt: String
    package var issuesSynced: Int
    package var lastError: String
    package var lastErrorAt: String

    package enum CodingKeys: String, CodingKey {
        case projectKey = "project_key"
        case lastSyncedAt = "last_synced_at"
        case issuesSynced = "issues_synced"
        case lastError = "last_error"
        case lastErrorAt = "last_error_at"
    }
}
