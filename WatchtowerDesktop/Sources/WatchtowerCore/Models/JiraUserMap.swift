import GRDB

package struct JiraUserMap: Codable, FetchableRecord, TableRecord {
    package static let databaseTableName = "jira_user_map"
    package let jiraAccountId: String
    package var email: String
    package var slackUserId: String
    package var displayName: String
    package var matchMethod: String      // "email" | "display_name" | "manual" | "unresolved"
    package var matchConfidence: Double
    package var resolvedAt: String

    package enum CodingKeys: String, CodingKey {
        case jiraAccountId = "jira_account_id"
        case email
        case slackUserId = "slack_user_id"
        case displayName = "display_name"
        case matchMethod = "match_method"
        case matchConfidence = "match_confidence"
        case resolvedAt = "resolved_at"
    }
}
