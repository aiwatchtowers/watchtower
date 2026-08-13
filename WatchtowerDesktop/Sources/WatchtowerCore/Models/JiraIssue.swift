import Foundation
import GRDB

package struct JiraIssue: Codable, FetchableRecord, TableRecord {
    package static let databaseTableName = "jira_issues"
    package let key: String              // PK "PROJ-123"
    package var id: String
    package var projectKey: String
    package var boardId: Int?
    package var summary: String
    package var descriptionText: String
    package var issueType: String
    package var issueTypeCategory: String // "epic" | "standard" | "subtask"
    package var isBug: Bool
    package var status: String
    package var statusCategory: String    // "todo" | "in_progress" | "done"
    package var statusCategoryChangedAt: String
    package var assigneeAccountId: String
    package var assigneeEmail: String
    package var assigneeDisplayName: String
    package var assigneeSlackId: String
    package var reporterAccountId: String
    package var reporterEmail: String
    package var reporterDisplayName: String
    package var reporterSlackId: String
    package var priority: String
    package var storyPoints: Double?
    package var dueDate: String
    package var sprintId: Int?
    package var sprintName: String
    package var epicKey: String
    package var labels: String            // JSON array
    package var components: String        // JSON array
    package var createdAt: String
    package var updatedAt: String
    package var resolvedAt: String
    package var fixVersions: String
    package var rawJson: String
    package var syncedAt: String
    package var isDeleted: Bool

    package enum CodingKeys: String, CodingKey {
        case key, id, summary, status, priority, labels, components
        case projectKey = "project_key"
        case boardId = "board_id"
        case descriptionText = "description_text"
        case issueType = "issue_type"
        case issueTypeCategory = "issue_type_category"
        case isBug = "is_bug"
        case statusCategory = "status_category"
        case statusCategoryChangedAt = "status_category_changed_at"
        case assigneeAccountId = "assignee_account_id"
        case assigneeEmail = "assignee_email"
        case assigneeDisplayName = "assignee_display_name"
        case assigneeSlackId = "assignee_slack_id"
        case reporterAccountId = "reporter_account_id"
        case reporterEmail = "reporter_email"
        case reporterDisplayName = "reporter_display_name"
        case reporterSlackId = "reporter_slack_id"
        case storyPoints = "story_points"
        case dueDate = "due_date"
        case sprintId = "sprint_id"
        case sprintName = "sprint_name"
        case epicKey = "epic_key"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case resolvedAt = "resolved_at"
        case fixVersions = "fix_versions"
        case rawJson = "raw_json"
        case syncedAt = "synced_at"
        case isDeleted = "is_deleted"
    }

    package var decodedFixVersions: [String] {
        guard let data = fixVersions.data(using: .utf8),
              let versions = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return versions
    }
}
