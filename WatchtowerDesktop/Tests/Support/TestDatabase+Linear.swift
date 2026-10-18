import Foundation
import GRDB

/// One `linear_issues` row. Fields not set keep a neutral default; the
/// connector writes `status_category` and `state_changed_at` itself
/// (Linear connector, migration 00119), so a fixture sets them directly.
package struct LinearIssueFixture {
    package var account: Int64
    package var id: String
    package var key: String
    package var teamKey = "ENG"
    package var title = ""
    package var state = "Todo"
    package var category = "todo"
    package var stateChanged: Date?
    package var assigneeSlackID = ""
    package var assigneeName = ""
    package var creatorSlackID = ""
    package var creatorName = ""
    package var priority = 0
    package var cycleID = ""
    package var projectID = ""
    package var url = ""
    package var created = Date().addingTimeInterval(-30 * 86400)
    package var updated = Date()
    package var completed: Date?
    package var deleted = false

    package init(account: Int64, id: String, key: String) {
        self.account = account
        self.id = id
        self.key = key
    }

    fileprivate func insert(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO linear_issues (account_id, id, key, team_key, title, state_name, status_category,
                    state_changed_at, assignee_slack_id, assignee_display_name, creator_slack_id,
                    creator_display_name, priority, cycle_id, project_id, url, created_at, updated_at,
                    completed_at, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                account, id, key, teamKey, title.isEmpty ? key : title, state, category,
                stateChanged.map(TestDatabase.jiraTime) ?? "", assigneeSlackID, assigneeName,
                creatorSlackID, creatorName, priority, cycleID, projectID, url,
                TestDatabase.jiraTime(created), TestDatabase.jiraTime(updated),
                completed.map(TestDatabase.jiraTime) ?? "", deleted
            ]
        )
    }
}

extension TestDatabase {
    /// Inserts one `linear_accounts` row and returns its id.
    @discardableResult
    package static func insertLinearAccount(
        _ db: Database,
        orgID: String = "org-1",
        urlKey: String = "acme",
        orgName: String = "Acme",
        status: String = "ok",
        enabled: Bool = true
    ) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO linear_accounts (org_id, url_key, org_name, status, enabled) VALUES (?, ?, ?, ?, ?)",
            arguments: [orgID, urlKey, orgName, status, enabled]
        )
        return db.lastInsertedRowID
    }

    /// Inserts one issue built by `configure` on a fixture for `key`.
    package static func insertLinearIssue(
        _ db: Database,
        account: Int64,
        id: String,
        key: String,
        _ configure: (inout LinearIssueFixture) -> Void = { _ in }
    ) throws {
        var fixture = LinearIssueFixture(account: account, id: id, key: key)
        configure(&fixture)
        try fixture.insert(db)
    }

    /// `blocker` blocks `blocked` (Linear's `blocks` relation: `issue_id`
    /// blocks `related_issue_id`).
    package static func insertLinearBlocks(_ db: Database, account: Int64, id: String, blocker: String, blocked: String) throws {
        try db.execute(
            sql: "INSERT INTO linear_relations (account_id, id, issue_id, related_issue_id, type) VALUES (?, ?, ?, ?, 'blocks')",
            arguments: [account, id, blocker, blocked]
        )
    }
}
