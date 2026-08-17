import GRDB

package struct JiraSlackLink: Codable, FetchableRecord, TableRecord, Identifiable {
    package static let databaseTableName = "jira_slack_links"

    package let id: Int
    package var issueKey: String
    package var channelId: String
    package var messageTs: String
    package var trackId: Int?
    package var digestId: Int?
    package var linkType: String
    package var detectedAt: String

    package enum CodingKeys: String, CodingKey {
        case id
        case issueKey = "issue_key"
        case channelId = "channel_id"
        case messageTs = "message_ts"
        case trackId = "track_id"
        case digestId = "digest_id"
        case linkType = "link_type"
        case detectedAt = "detected_at"
    }
}
