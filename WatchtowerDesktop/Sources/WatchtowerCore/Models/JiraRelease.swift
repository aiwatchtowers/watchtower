import GRDB

package struct JiraRelease: Codable, FetchableRecord, TableRecord, Identifiable {
    package static let databaseTableName = "jira_releases"

    package let id: Int
    package let projectKey: String
    package let name: String
    package let description: String
    package let releaseDate: String
    package let released: Bool
    package let archived: Bool
    package let syncedAt: String

    package enum CodingKeys: String, CodingKey {
        case id
        case projectKey = "project_key"
        case name
        case description
        case releaseDate = "release_date"
        case released
        case archived
        case syncedAt = "synced_at"
    }
}
