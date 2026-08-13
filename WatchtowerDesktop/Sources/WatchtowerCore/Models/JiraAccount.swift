import GRDB

/// One connected Atlassian site from the `jira_accounts` table
/// (internal/db/migrations/00049_jira_accounts.sql). Multiple sites can be
/// connected side by side; each site-scoped jira_* row carries its
/// account_id, and each account has its own OAuth token file
/// (jira_token_<id>.json). The single pre-multi-account install migrates in
/// place as account #1.
package struct JiraAccount: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let cloudID: String
    package let siteURL: String
    package let siteName: String
    package let label: String
    package let status: String
    package let error: String
    package let enabled: Bool

    package init(row: Row) {
        id = row["id"]
        cloudID = row["cloud_id"] ?? ""
        siteURL = row["site_url"] ?? ""
        siteName = row["site_name"] ?? ""
        label = row["label"] ?? ""
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
        enabled = row["enabled"] ?? true
    }

    // MARK: - Status predicates

    package var isOK: Bool { status == "ok" }
    package var isRevoked: Bool { status == "revoked" }

    /// Display text for a row: the user-facing label if set, else the site
    /// name, else a positional fallback for a not-yet-consented row (site name
    /// is only populated once the OAuth flow completes).
    package var displayName: String {
        label.isEmpty ? (siteName.isEmpty ? "Jira account #\(id)" : siteName) : label
    }
}
