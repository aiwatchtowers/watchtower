import GRDB

package struct JiraIssueLink: Codable, FetchableRecord, TableRecord {
    package static let databaseTableName = "jira_issue_links"
    package let id: String
    package var sourceKey: String
    package var targetKey: String
    package var linkType: String
    package var syncedAt: String

    package enum CodingKeys: String, CodingKey {
        case id
        case sourceKey = "source_key"
        case targetKey = "target_key"
        case linkType = "link_type"
        case syncedAt = "synced_at"
    }
}
