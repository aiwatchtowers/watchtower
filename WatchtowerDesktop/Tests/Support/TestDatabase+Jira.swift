import Foundation
import GRDB

/// One `jira_issues` row. Fields not set keep a neutral default; timestamps
/// are stored the way the Go sync writes them (`TestDatabase.jiraTime`).
package struct JiraIssueFixture {
    package var account: Int64
    package var key: String
    package var status = "Open"
    package var category = "todo"
    package var assignee = ""
    package var assigneeName = ""
    package var reporter = ""
    package var reporterName = ""
    package var created = Date().addingTimeInterval(-30 * 86400)
    package var resolved: Date?
    package var categoryChanged: Date?
    package var dueDate = ""
    package var storyPoints: Double?
    package var sprintID: Int?
    package var epicKey = ""
    package var typeCategory = ""
    package var summary = ""
    package var fixVersions = "[]"
    package var labels = "[]"
    package var components = "[]"
    package var deleted = false

    package init(account: Int64, key: String) {
        self.account = account
        self.key = key
    }

    package func insert(_ db: Database) throws {
        let now = TestDatabase.jiraTime(Date())
        try db.execute(
            sql: """
                INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
                    status_category_changed_at, assignee_slack_id, assignee_display_name,
                    reporter_slack_id, reporter_display_name, story_points, due_date, sprint_id,
                    epic_key, issue_type_category, fix_versions, labels, components,
                    created_at, updated_at, resolved_at, synced_at, is_deleted)
                VALUES (?, ?, 'PROJ', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                account, key, summary.isEmpty ? key : summary, status, category,
                categoryChanged.map(TestDatabase.jiraTime) ?? "", assignee, assigneeName,
                reporter, reporterName, storyPoints, dueDate, sprintID,
                epicKey, typeCategory, fixVersions, labels, components,
                TestDatabase.jiraTime(created), now, resolved.map(TestDatabase.jiraTime) ?? "", now, deleted
            ]
        )
    }
}

extension TestDatabase {
    private static let jiraTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    /// `date` in the stored Jira timestamp form: fixed-width UTC with
    /// milliseconds (Go `db.FormatJiraTime`, migration 00092), so string
    /// order is instant order.
    package static func jiraTime(_ date: Date) -> String {
        jiraTimeFormatter.string(from: date)
    }

    /// Inserts one issue built by `configure` on a fixture for `key`.
    package static func insertJiraIssue(
        _ db: Database,
        account: Int64,
        key: String,
        _ configure: (inout JiraIssueFixture) -> Void = { _ in }
    ) throws {
        var fixture = JiraIssueFixture(account: account, key: key)
        configure(&fixture)
        try fixture.insert(db)
    }
}
