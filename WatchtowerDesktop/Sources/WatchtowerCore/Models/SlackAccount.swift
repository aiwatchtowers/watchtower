import GRDB

/// One connected Slack workspace from the `slack_accounts` table
/// (internal/db/migrations/00048_slack_accounts.sql). Multiple workspaces can
/// be connected side by side; each carries its own namespaced `current_user_id`
/// (`"<accountID>:<rawSlackID>"`) and its own OAuth token file. The single
/// pre-multi-account install migrates in place as account #1.
package struct SlackAccount: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let teamName: String
    package let teamDomain: String
    package let label: String
    package let status: String
    package let error: String
    package let enabled: Bool

    package init(row: Row) {
        id = row["id"]
        teamName = row["team_name"] ?? ""
        teamDomain = row["team_domain"] ?? ""
        label = row["label"] ?? ""
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
        enabled = row["enabled"] ?? true
    }

    // MARK: - Status predicates

    package var isOK: Bool { status == "ok" }
    package var isRevoked: Bool { status == "revoked" }

    /// Display text for a row: the user-facing label if set, else the Slack
    /// workspace's team name, else a positional fallback for a not-yet-consented
    /// row (team name is only populated once the OAuth flow completes).
    package var displayName: String {
        label.isEmpty ? (teamName.isEmpty ? "Slack account #\(id)" : teamName) : label
    }
}
