import GRDB

struct JiraIssueLink: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "jira_issue_links"
    let id: String
    var sourceKey: String
    var targetKey: String
    var linkType: String
    var syncedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sourceKey = "source_key"
        case targetKey = "target_key"
        case linkType = "link_type"
        case syncedAt = "synced_at"
    }
}
