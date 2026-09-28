import GRDB

package struct JiraRelease: Codable, FetchableRecord, TableRecord, Identifiable {
    package static let databaseTableName = "jira_releases"

    /// The owning Jira site (`jira_releases` PK is `(account_id, id)`).
    package let accountID: Int
    /// Jira's release id — unique only within one site.
    package let releaseID: Int
    package let projectKey: String
    package let name: String
    package let description: String
    package let releaseDate: String
    package let released: Bool
    package let archived: Bool
    package let syncedAt: String

    /// Site-qualified identity: two connected sites can hand out the same
    /// release id, which a bare-id `ForEach` would collapse.
    package var id: String { "\(accountID):\(releaseID)" }

    package enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case releaseID = "id"
        case projectKey = "project_key"
        case name
        case description
        case releaseDate = "release_date"
        case released
        case archived
        case syncedAt = "synced_at"
    }
}
